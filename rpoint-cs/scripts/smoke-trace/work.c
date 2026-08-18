/* Branchy, deterministic workload: a mix of data-dependent conditionals,
   indirect calls through a function-pointer table, and a recursive call chain,
   so the trace exercises every branch class the converter emits. */
#include <stdio.h>

/* Iteration count is set at build time. It must be large enough that the
   workload is STILL RUNNING when the driver arms the trigger -- see
   smoke_trace.sh. 600M iterations is ~60s of wall time under TCG. */
#ifndef WORK_ITERS
#define WORK_ITERS 600000000L
#endif
static long acc = 0;
static long add(long a){ return acc + a; }
static long sub(long a){ return acc - a; }
static long xr (long a){ return acc ^ a; }
static long fib(long n){ return n < 2 ? n : fib(n-1) + fib(n-2); }
int main(void){
  long (*ops[3])(long) = { add, sub, xr };
  for (long i = 0; i < WORK_ITERS; i++) {
    acc = ops[i % 3](i);                 /* indirect call */
    if ((i & 7) == 0)      acc += 3;     /* conditional, 1-in-8 */
    else if ((i & 1) == 0) acc -= 1;     /* conditional, data-dependent */
    if (acc < 0) acc = -acc;
  }
  acc += fib(20);                        /* direct calls + returns */
  printf("acc=%ld\n", acc);
  return 0;
}
