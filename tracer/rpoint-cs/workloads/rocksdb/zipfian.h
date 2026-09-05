/*
 * zipfian.h
 *
 * Scrambled Zipfian generator (YCSB algorithm with FNV-1a scrambling).
 * Ported from scylla_bench.c so the rocksdb_driver and the ScyllaDB
 * benchmark client emit the same key distribution given the same seed.
 *
 * Each thread should own its own zipfian_t and seed it independently.
 * zipfian_next() returns a 1-based key id in [1, n].
 */

#ifndef ROCKSDB_DRIVER_ZIPFIAN_H
#define ROCKSDB_DRIVER_ZIPFIAN_H

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
  long n;
  double s;
  double zeta_n;
  double zeta_2;
  double alpha;
  double eta;
  unsigned int rng;
  int uniform;  /* 1 if s == 0: degenerate to uniform [1, n] */
} zipfian_t;

static inline double zipfian_zeta(long n, double s)
{
  double sum = 0.0;
  for (long i = 1; i <= n; i++)
    sum += 1.0 / pow((double)i, s);
  return sum;
}

/*
 * Initialise a Zipfian generator over [1, n] with skew parameter s.
 * s == 0 produces a uniform distribution.
 *
 * The zeta(n, s) precomputation is O(n) and can be slow for large n.
 * Callers needing the same (n, s) across threads should compute zeta
 * once and broadcast via zipfian_init_precomputed().
 */
static inline void zipfian_init(zipfian_t *z, long n, double s, unsigned int seed)
{
  z->n = n;
  z->s = s;
  z->rng = seed;

  if (s <= 0.0) {
    z->uniform = 1;
    z->zeta_2 = 0.0;
    z->zeta_n = 0.0;
    z->alpha = 0.0;
    z->eta = 0.0;
    return;
  }

  z->uniform = 0;
  z->zeta_2 = zipfian_zeta(2, s);
  z->zeta_n = zipfian_zeta(n, s);
  z->alpha = 1.0 / (1.0 - s);
  z->eta = (1.0 - pow(2.0 / (double)n, 1.0 - s))
         / (1.0 - z->zeta_2 / z->zeta_n);
}

/* Reuse a precomputed (zeta_n, zeta_2) so multi-thread init is cheap. */
static inline void zipfian_init_precomputed(zipfian_t *z,
                                            long n,
                                            double s,
                                            double zeta_n,
                                            double zeta_2,
                                            unsigned int seed)
{
  z->n = n;
  z->s = s;
  z->rng = seed;

  if (s <= 0.0) {
    z->uniform = 1;
    z->zeta_2 = 0.0;
    z->zeta_n = 0.0;
    z->alpha = 0.0;
    z->eta = 0.0;
    return;
  }

  z->uniform = 0;
  z->zeta_2 = zeta_2;
  z->zeta_n = zeta_n;
  z->alpha = 1.0 / (1.0 - s);
  z->eta = (1.0 - pow(2.0 / (double)n, 1.0 - s))
         / (1.0 - z->zeta_2 / z->zeta_n);
}

static inline long zipfian_next_raw(zipfian_t *z)
{
  double u = (double)rand_r(&z->rng) / (double)RAND_MAX;
  if (z->uniform)
    return (long)(u * (double)z->n);
  double uz = u * z->zeta_n;
  if (uz < 1.0)
    return 0;
  if (uz < 1.0 + pow(0.5, z->s))
    return 1;
  return (long)((double)z->n * pow(z->eta * u - z->eta + 1.0, z->alpha));
}

static inline uint64_t zipfian_fnv1a_64(uint64_t val)
{
  uint64_t h = 0xcbf29ce484222325ULL;
  for (int i = 0; i < 8; i++) {
    h ^= (val & 0xff);
    h *= 0x100000001b3ULL;
    val >>= 8;
  }
  return h;
}

/*
 * Returns a 1-based key id in [1, n], scrambled with FNV-1a so the
 * popular keys are not clustered at the low end of the keyspace.
 */
static inline long zipfian_next(zipfian_t *z)
{
  long raw = zipfian_next_raw(z);
  return 1 + (long)(zipfian_fnv1a_64((uint64_t)raw) % (uint64_t)z->n);
}

#endif /* ROCKSDB_DRIVER_ZIPFIAN_H */
