# TCG-compatible CPU model: a KVM snapshot must restore under TCG, so the model
# cannot be -cpu host. Same string the memcached v2 campaign used (proven across
# the KVM->TCG boundary); paravirt clocks/features off so TCG restore is clean.
export CPUSTR="Haswell,pmu=on,kvmclock=off,kvmclock-stable-bit=off,kvm-asyncpf=off,kvm-steal-time=off,kvm-pv-eoi=off,kvm-pv-unhalt=off,kvm-poll-control=off,kvm-pv-ipi=off,kvm-pv-sched-yield=off,kvm-pv-tlb-flush=off,kvm-asyncpf-int=off,hle=off,rtm=off,pcid=off,invpcid=off,tsc-deadline=off"
export QEMU_FIXED=$HOME/work/new-tracing/qemu-avxfix/build/qemu-system-x86_64
export IMAGES=$HOME/work/new-tracing/images
export MON=$HOME/work/new-tracing/run/monitor.sock
