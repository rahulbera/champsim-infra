#!/usr/bin/env python3
"""Compute sample_gap for a periodic-sampling capture.

    sgap.py --total <T> --user <U> [--windows K] [--len N] [--clock user|all]

DO NOT use the `sample_gap = (user - K*N)/(K-1)` hint the plugin prints at exit.
It mixes units and always under-covers the run.

Why: the window length N is counted in ALL instructions -- champsim_tracer.c
increments chunk_insn_count for every captured instruction regardless of
privilege ("Window length always counts EVERY instruction"). The gap, under
sample_clock=user, advances ONLY on user-mode instructions. The hint subtracts an
all-instruction K*N from a user-only counter, so the K windows span

    T - K*N*(1-f)/f      instead of      T           (f = user/total)

Measured against two finished campaigns, which bracket a 20-point range of f and
both land on the model, so this is not a coincidence:

    redis    T=20,659,920,896  U=7,691,636,216  (f=0.372)
             hint gave SGAP=672,909,054 -> span 12.17e9 = 58.9% of the run
    rocksdb  T=27,757,267,052  U=15,782,260,124 (f=0.569)
             hint gave SGAP=2,695,565,031 -> span 23.97e9 = 86.4% of the run

Neither trace set is corrupt -- every window is internally valid, exactly 1e9
instructions, decode_fail 0 -- but they sample the LEADING part of the
trajectory rather than spanning it.

Derivation (sample_clock=user). Span in all-instruction units must equal T:
    K*N + (K-1)*G_all = T,  and  G_user = f * G_all
 => G_user = (U/(K-1)) * (1 - K*N/T)
Under sample_clock=all the gap and the window share a clock:
    G_all  = (T - K*N)/(K-1)
"""
import argparse, sys

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--total', type=float, required=True, help='PROFILE total instructions')
    p.add_argument('--user',  type=float, required=True, help='PROFILE user instructions')
    p.add_argument('--windows', type=int, default=5, help='K (default 5)')
    p.add_argument('--len', type=float, default=1e9, dest='n', help='N, window length (default 1e9)')
    p.add_argument('--clock', choices=['user', 'all'], default='user')
    a = p.parse_args()

    T, U, K, N = a.total, a.user, a.windows, a.n
    if K < 2:
        sys.exit('need at least 2 windows for a gap to exist')
    f = U / T
    if K * N >= T:
        sys.exit(f'K*N ({K*N:,.0f}) >= total ({T:,.0f}): the windows alone exceed '
                 f'the profiled run; profile for longer or use fewer/shorter windows')

    if a.clock == 'user':
        gap = (U / (K - 1)) * (1 - K * N / T)
    else:
        gap = (T - K * N) / (K - 1)
    hint = (U - K * N) / (K - 1)          # what the plugin prints; wrong for clock=user

    print(f'total           {T:>20,.0f}')
    print(f'user            {U:>20,.0f}   ({100*f:.2f}%)')
    print(f'windows K       {K:>20d}')
    print(f'window len N    {N:>20,.0f}')
    print(f'clock           {a.clock:>20}')
    print()
    print(f'SGAP (correct)  {gap:>20,.0f}')
    if a.clock == 'user':
        span = K * N + (K - 1) * gap / f
        print(f'  -> spans      {span:>20,.0f}   = {100*span/T:.2f}% of the profiled run')
        hspan = K * N + (K - 1) * hint / f
        print(f'plugin hint     {hint:>20,.0f}   (DO NOT USE)')
        print(f'  -> would span {hspan:>20,.0f}   = {100*hspan/T:.2f}%')

if __name__ == '__main__':
    main()
