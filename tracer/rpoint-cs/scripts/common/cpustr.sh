# Sourced by common/lib.sh; $W is already set there.
# TCG-compatible CPU model: a KVM snapshot must restore under TCG, so the model
# cannot be -cpu host. Same string the memcached v2 campaign used (proven across
# the KVM->TCG boundary); paravirt clocks/features off so TCG restore is clean.
export CPUSTR="Haswell,pmu=on,kvmclock=off,kvmclock-stable-bit=off,kvm-asyncpf=off,kvm-steal-time=off,kvm-pv-eoi=off,kvm-pv-unhalt=off,kvm-poll-control=off,kvm-pv-ipi=off,kvm-pv-sched-yield=off,kvm-pv-tlb-flush=off,kvm-asyncpf-int=off,hle=off,rtm=off,pcid=off,invpcid=off,tsc-deadline=off"
export QEMU_FIXED="${QEMU_FIXED:-$W/qemu-avxfix/build/qemu-system-x86_64}"
export IMAGES="${IMAGES:-$W/images}"
export MON="${MON:-$W/run/monitor.sock}"
