/*
 * mongo_driver.c — Zipfian read/write workload against MongoDB, for ChampSim
 * trace capture. Deliberately mirrors rocksdb_driver_v2.cpp phase-for-phase so
 * the three campaigns stay methodologically comparable: same CLI shape, same
 * zipfian generator, same warmup/ROI split, same CPU pinning, same ROI markers.
 *
 * Carries forward both fixes made to the RocksDB driver:
 *   * values are DERIVED PER RECORD from a (seed, id) PRNG. v1's RocksDB driver
 *     wrote identical bytes to every record, which made DB size unpredictable
 *     from n*v and left the captured value channel degenerate under values=on.
 *   * --attach reuses an existing dataset instead of always reloading, which is
 *     what the snapshot workflow needs (load once under KVM, snapshot, restore
 *     under TCG).
 *
 * --roi-secs is a WALL-CLOCK budget. Under TCG's 50-150x slowdown, set it far
 * larger than the intended capture and let the plugin's instruction-bounded
 * sampling define the windows.
 */
#define _GNU_SOURCE
#include <mongoc/mongoc.h>
#include <bson/bson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <time.h>
#include <pthread.h>
#include <stdint.h>
#include "zipfian.h"
#include "champsim_markers.h"

typedef struct {
  const char *uri, *db, *coll, *cpus;
  long   num_records, roi_ops_cap;
  int    value_size, read_pct, num_threads, warmup_secs, roi_secs;
  double alpha;
  unsigned seed;
  int    attach, overwrite;
} Args;

static double now_secs(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
  return t.tv_sec + t.tv_nsec/1e9; }

static void usage(const char *p){
  fprintf(stderr,
   "Usage: %s [options]\n"
   "  -u URI            mongodb uri            [mongodb://127.0.0.1:27017]\n"
   "  -n N              num records to load    [8000000]\n"
   "  -v N              value size in bytes    [1024]\n"
   "  -o N              soft cap on per-thread ops (timer trips first)\n"
   "  -r N              read pct 0..100        [95]\n"
   "  -a F              zipfian skew (0=uniform) [0.99]\n"
   "  -t N              worker threads         [1]\n"
   "  --cpus=L          comma list of CPUs to pin  [required]\n"
   "  -s N              RNG seed               [42]\n"
   "  --warmup-secs=N   untraced steady-state warmup [180]\n"
   "  --roi-secs=N      WALL-CLOCK budget for traced window [240]\n"
   "  --attach          reuse an existing collection: skip the load\n"
   "  --overwrite       drop the collection if it exists\n", p);
}

/* per-record value: distinct, deterministic from (seed,id) — see header note */
static void fill_value(char *buf,int len,unsigned seed,long id,const unsigned char *lut){
  uint64_t x = ((uint64_t)seed * 0x9E3779B97F4A7C15ull) ^ ((uint64_t)id + 0x1010101ull);
  if(!x) x = 0x9E3779B97F4A7C15ull;
  int j=0;
  while(j<len){ x^=x<<13; x^=x>>7; x^=x<<17; uint64_t w=x;
    for(int b=0;b<8 && j<len;b++,j++,w>>=8) buf[j]=(char)lut[w&0xFF]; }
}
static void fmt_key(char *b,size_t n,long id){ snprintf(b,n,"user%07ld",id); }

typedef struct {
  const Args *a; mongoc_client_pool_t *pool; int tid; int cpu;
  double zeta_n, zeta_2, deadline;
  long ops, reads, writes, found;
} Ctx;

static void *worker(void *arg){
  Ctx *c = (Ctx*)arg;
  const Args *a = c->a;
  cpu_set_t set; CPU_ZERO(&set); CPU_SET(c->cpu,&set);
  if(pthread_setaffinity_np(pthread_self(),sizeof(set),&set)!=0)
    fprintf(stderr,"[warn] thread %d: failed to pin to cpu %d\n",c->tid,c->cpu);

  mongoc_client_t *cl = mongoc_client_pool_pop(c->pool);
  mongoc_collection_t *col = mongoc_client_get_collection(cl,a->db,a->coll);

  zipfian_t z; zipfian_init_precomputed(&z,a->num_records,a->alpha,c->zeta_n,c->zeta_2,a->seed+c->tid);
  unsigned char lut[256]; for(int i=0;i<256;i++) lut[i]=(unsigned char)('a'+(i%26));
  char *val = malloc(a->value_size+1); char key[32];
  unsigned rs = a->seed ^ (unsigned)(c->tid*2654435761u);

  while(now_secs() < c->deadline && c->ops < a->roi_ops_cap){
    long id = (a->alpha>0.0) ? zipfian_next(&z) : (rand_r(&rs)%a->num_records);
    if(id < 1) id = 1;
    if(id > a->num_records) id = a->num_records;
    fmt_key(key,sizeof key,id);
    int is_read = (int)(rand_r(&rs)%100) < a->read_pct;
    bson_error_t err;
    if(is_read){
      bson_t *q = BCON_NEW("_id", BCON_UTF8(key));
      mongoc_cursor_t *cur = mongoc_collection_find_with_opts(col,q,NULL,NULL);
      const bson_t *doc; 
      if(mongoc_cursor_next(cur,&doc)){
        bson_iter_t it;                      /* touch the value to force it in */
        if(bson_iter_init_find(&it,doc,"v") && BSON_ITER_HOLDS_UTF8(&it)){
          uint32_t l; const char *s = bson_iter_utf8(&it,&l); if(l && s[0]) c->found++;
        }
      }
      mongoc_cursor_destroy(cur); bson_destroy(q); c->reads++;
    } else {
      fill_value(val,a->value_size,a->seed,id,lut); val[a->value_size]='\0';
      bson_t *sel = BCON_NEW("_id", BCON_UTF8(key));
      bson_t *upd = BCON_NEW("$set","{","v",BCON_UTF8(val),"}");
      mongoc_collection_update_one(col,sel,upd,NULL,NULL,&err);
      bson_destroy(sel); bson_destroy(upd); c->writes++;
    }
    c->ops++;
  }
  mongoc_collection_destroy(col); mongoc_client_pool_push(c->pool,cl);
  return NULL;
}

int main(int argc,char **argv){
  Args a = { .uri="mongodb://127.0.0.1:27017", .db="ycsb", .coll="usertable",
             .cpus=NULL, .num_records=8000000, .roi_ops_cap=1000000000,
             .value_size=1024, .read_pct=95, .num_threads=1,
             .warmup_secs=180, .roi_secs=240, .alpha=0.99, .seed=42,
             .attach=0, .overwrite=0 };
  for(int i=1;i<argc;i++){
    const char *s=argv[i];
    if(!strcmp(s,"-u")&&i+1<argc) a.uri=argv[++i];
    else if(!strcmp(s,"-n")&&i+1<argc) a.num_records=atol(argv[++i]);
    else if(!strcmp(s,"-v")&&i+1<argc) a.value_size=atoi(argv[++i]);
    else if(!strcmp(s,"-o")&&i+1<argc) a.roi_ops_cap=atol(argv[++i]);
    else if(!strcmp(s,"-r")&&i+1<argc) a.read_pct=atoi(argv[++i]);
    else if(!strcmp(s,"-a")&&i+1<argc) a.alpha=atof(argv[++i]);
    else if(!strcmp(s,"-t")&&i+1<argc) a.num_threads=atoi(argv[++i]);
    else if(!strcmp(s,"-s")&&i+1<argc) a.seed=(unsigned)atol(argv[++i]);
    else if(!strncmp(s,"--cpus=",7)) a.cpus=s+7;
    else if(!strncmp(s,"--warmup-secs=",14)) a.warmup_secs=atoi(s+14);
    else if(!strncmp(s,"--roi-secs=",11)) a.roi_secs=atoi(s+11);
    else if(!strcmp(s,"--attach")) a.attach=1;
    else if(!strcmp(s,"--overwrite")) a.overwrite=1;
    else { usage(argv[0]); return !strcmp(s,"-h")||!strcmp(s,"--help") ? 0 : 1; }
  }
  if(!a.cpus){ fprintf(stderr,"[fatal] --cpus=L is required\n"); return 1; }

  int cpul[64],ncpu=0; { char b[256]; snprintf(b,sizeof b,"%s",a.cpus);
    for(char *t=strtok(b,",");t&&ncpu<64;t=strtok(NULL,",")) cpul[ncpu++]=atoi(t); }
  if(ncpu<a.num_threads){ fprintf(stderr,"[fatal] --cpus lists %d cpus for %d threads\n",ncpu,a.num_threads); return 1; }

  mongoc_init();
  mongoc_uri_t *uri = mongoc_uri_new(a.uri);
  mongoc_client_pool_t *pool = mongoc_client_pool_new(uri);
  mongoc_client_pool_set_error_api(pool, 2);
  mongoc_client_t *cl = mongoc_client_pool_pop(pool);
  bson_error_t err;
  bson_t *ping = BCON_NEW("ping", BCON_INT32(1));
  if(!mongoc_client_command_simple(cl,"admin",ping,NULL,NULL,&err)){
    fprintf(stderr,"[fatal] cannot reach mongod: %s\n",err.message); return 2; }
  bson_destroy(ping);
  mongoc_collection_t *col = mongoc_client_get_collection(cl,a.db,a.coll);
  int64_t existing = mongoc_collection_count_documents(col,
                       bson_new(),NULL,NULL,NULL,&err);
  fprintf(stderr,"[init] collection %s.%s holds %lld documents\n",a.db,a.coll,(long long)existing);

  if(existing>0 && a.overwrite){
    fprintf(stderr,"[init] --overwrite: dropping %s.%s\n",a.db,a.coll);
    mongoc_collection_drop(col,&err); existing=0;
  } else if(existing>0 && !a.attach){
    fprintf(stderr,"[fatal] %s.%s is non-empty. Use --overwrite to wipe, or --attach to reuse it.\n",a.db,a.coll);
    return 2;
  }

  /* ---- load ---- */
  if(a.attach && existing>0){
    fprintf(stderr,"[load] skipped (--attach), %lld documents present\n",(long long)existing);
  } else {
    fprintf(stderr,"[load] inserting %ld documents of %d bytes...\n",a.num_records,a.value_size);
    unsigned char lut[256]; for(int i=0;i<256;i++) lut[i]=(unsigned char)('a'+(i%26));
    char *val=malloc(a.value_size+1); char key[32];
    mongoc_bulk_operation_t *bulk=mongoc_collection_create_bulk_operation_with_opts(col,NULL);
    double t0=now_secs(); long batch=0;
    for(long i=1;i<=a.num_records;i++){
      fmt_key(key,sizeof key,i);
      fill_value(val,a.value_size,a.seed,i,lut); val[a.value_size]='\0';
      bson_t *d=BCON_NEW("_id",BCON_UTF8(key),"v",BCON_UTF8(val));
      mongoc_bulk_operation_insert(bulk,d); bson_destroy(d);
      if(++batch==1000){
        if(!mongoc_bulk_operation_execute(bulk,NULL,&err))
          { fprintf(stderr,"[fatal] bulk insert: %s\n",err.message); return 3; }
        mongoc_bulk_operation_destroy(bulk);
        bulk=mongoc_collection_create_bulk_operation_with_opts(col,NULL); batch=0;
        if(i%1000000==0) fprintf(stderr,"[load] %ld / %ld (%.1f%%) %.0f docs/s\n",
            i,a.num_records,100.0*i/a.num_records,i/(now_secs()-t0));
      }
    }
    if(batch) mongoc_bulk_operation_execute(bulk,NULL,&err);
    mongoc_bulk_operation_destroy(bulk);
    fprintf(stderr,"[load] done in %.1fs\n",now_secs()-t0);
  }
  mongoc_collection_destroy(col); mongoc_client_pool_push(pool,cl);

  /* ---- zeta once ---- */
  double zn=0,z2=0;
  if(a.alpha>0.0){ fprintf(stderr,"[roi] precomputing zeta(%ld, %.2f)...\n",a.num_records,a.alpha);
    double tz=now_secs(); zn=zipfian_zeta(a.num_records,a.alpha); z2=zipfian_zeta(2,a.alpha);
    fprintf(stderr,"[roi] zeta done in %.1fs\n",now_secs()-tz); }

  /* ---- warmup (untraced) then ROI (traced) ---- */
  pthread_t th[64]; Ctx ctx[64];
  double deadline = now_secs() + a.warmup_secs + a.roi_secs;
  for(int i=0;i<a.num_threads;i++){
    ctx[i]=(Ctx){ .a=&a,.pool=pool,.tid=i,.cpu=cpul[i%ncpu],.zeta_n=zn,.zeta_2=z2,
                  .deadline=deadline,.ops=0,.reads=0,.writes=0,.found=0 };
    pthread_create(&th[i],NULL,worker,&ctx[i]);
  }
  fprintf(stderr,"[warmup-roi] %d thread(s) running Zipfian loop UNTRACED for %d s (read_pct=%d, alpha=%.2f) ...\n",
          a.num_threads,a.warmup_secs,a.read_pct,a.alpha);
  double w0=now_secs(); while(now_secs()-w0 < a.warmup_secs) usleep(200000);
  fprintf(stderr,"[roi] tracing ON. roi_secs=%d (workers exit at deadline)\n",a.roi_secs);
  champsim_roi_begin();
  for(int i=0;i<a.num_threads;i++) pthread_join(th[i],NULL);
  champsim_roi_end();

  long ops=0,rd=0,wr=0,fd=0;
  for(int i=0;i<a.num_threads;i++){ ops+=ctx[i].ops; rd+=ctx[i].reads; wr+=ctx[i].writes; fd+=ctx[i].found; }
  fprintf(stderr,"[roi] complete. ops=%ld reads=%ld writes=%ld found=%ld (%.1f%%)\n",
          ops,rd,wr,fd, rd? 100.0*fd/rd : 0.0);

  /* WiredTiger cache counters — the RocksDB block-cache analogue */
  cl = mongoc_client_pool_pop(pool);
  bson_t reply; bson_t *cmd = BCON_NEW("serverStatus",BCON_INT32(1));
  if(mongoc_client_command_simple(cl,"admin",cmd,NULL,&reply,&err)){
    bson_iter_t it,sub;
    if(bson_iter_init(&it,&reply) &&
       bson_iter_find_descendant(&it,"wiredTiger.cache.pages read into cache",&sub))
      fprintf(stderr,"[stats] WT pages read into cache = %lld\n",(long long)bson_iter_as_int64(&sub));
    if(bson_iter_init(&it,&reply) &&
       bson_iter_find_descendant(&it,"wiredTiger.cache.pages requested from the cache",&sub))
      fprintf(stderr,"[stats] WT pages requested from cache = %lld\n",(long long)bson_iter_as_int64(&sub));
    if(bson_iter_init(&it,&reply) &&
       bson_iter_find_descendant(&it,"wiredTiger.cache.bytes currently in the cache",&sub))
      fprintf(stderr,"[stats] WT bytes in cache = %lld\n",(long long)bson_iter_as_int64(&sub));
    bson_destroy(&reply);
  }
  bson_destroy(cmd); mongoc_client_pool_push(pool,cl);
  mongoc_client_pool_destroy(pool); mongoc_uri_destroy(uri); mongoc_cleanup();
  fprintf(stderr,"[done] driver exit.\n");
  return 0;
}
