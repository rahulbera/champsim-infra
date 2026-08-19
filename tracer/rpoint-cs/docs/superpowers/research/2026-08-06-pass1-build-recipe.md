# Pass 1 build recipe — research synthesis

Produced by a 5-agent research workflow on 2026-08-06 (444k subagent tokens, ~36 min wall clock).

> **This document is evidence, not authority.** Agent claims that were
> independently verified are marked in the Verification section at the end.
> The two agents disagreed on `base_commit`, which is the single fact whose
> error would not surface until the test patch failed to apply hours into a
> build — so it was checked against the dataset directly.

---

# PASS 1 BUILD RECIPE — merged from the four research reports

**Instance:** `prometheus__prometheus-15142` · **base_commit:** `16bba78f1549cfd7909b61ebd7c55c822c86630b` · **Go:** `go1.23.8`

---

## 0. Conflict resolutions applied (details + evidence in §4)

| Question | Decision | Why |
|---|---|---|
| base_commit | `16bba78f…` (R1), **not** `032ca9ef…` (R3) | R1 reproduced FAIL→PASS end-to-end at 16bba78 |
| Repo path | **`/prometheus`** (not `/testbed`, not `/opt/prometheus`) | SWE-agent LOCAL deployment hardcodes `/<repo_name>` |
| Agent user | **root** (not `ubuntu`) | `/root/tools`, `/root/state.json` are real paths under LOCAL deployment |
| Go install | **official tarball 1.23.8** (not `apt golang-go`) | apt noble Go is 1.22 → TooNewError, unfixable with `GOTOOLCHAIN=local` |
| Module cache | plain `go mod download` **+** `go mod download all` **+ `git checkout -- go.mod go.sum`** | gets R3's superset, keeps R1's pristine tree |
| `GOPRIVATE`/`GONOPROXY` | **dropped** | `GONOPROXY=*` makes modules bypass `GOPROXY=off` → network hang instead of instant error |
| Offline gate | `sudo unshare -n` (no `-r`) **plus** a full `-nic none` rehearsal boot | Ubuntu 24.04 restricts unprivileged userns |
| Disk | 40 G | measured need ≈ 3.5 GB Go + ~1.5 GB agent/OS |

---

## 1. ORDERED COMMANDS

Legend: **[HOST]** = your Ubuntu 24.04 workstation · **[GUEST]** = inside the VM over ssh (`ssh -p 2222 ubuntu@127.0.0.1`), run with `sudo` where shown.

### Phase H — host: fetch image, instance data, build seed

```bash
# H1 [HOST] workspace
mkdir -p ~/vm/trace && cd ~/vm/trace

# H2 [HOST] pinned dated cloud image (NOT /current/ — it moves)
curl -fSL -O https://cloud-images.ubuntu.com/noble/20260801/noble-server-cloudimg-amd64.img
curl -fSL -O https://cloud-images.ubuntu.com/noble/20260801/SHA256SUMS
grep ' \*noble-server-cloudimg-amd64.img$' SHA256SUMS | sha256sum -c -

# H3 [HOST] working disk
cp noble-server-cloudimg-amd64.img disk.qcow2
~/qemu-custom/bin/qemu-img resize disk.qcow2 40G
~/qemu-custom/bin/qemu-img info disk.qcow2

# H4 [HOST] ssh key
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519

# H5 [HOST] pull the EXACT benchmark row (problem statement, test patch, F2P list)
curl -sG 'https://datasets-server.huggingface.co/filter' \
  --data-urlencode 'dataset=swe-bench/SWE-Bench_Multilingual' \
  --data-urlencode 'config=default' \
  --data-urlencode 'split=test' \
  --data-urlencode 'where="instance_id"=<SQ>prometheus__prometheus-15142<SQ>' \
  --data-urlencode 'limit=1' -o row.json
# NOTE: replace <SQ> with a literal single quote; written this way so the shell
# does not eat it inside the outer single-quoted --data-urlencode argument.
# Equivalent, safer form:
python3 - <<'PY'
import json,urllib.parse,urllib.request
q=urllib.parse.urlencode({"dataset":"swe-bench/SWE-Bench_Multilingual","config":"default",
 "split":"test","where":"\"instance_id\"='prometheus__prometheus-15142'","limit":1})
d=json.load(urllib.request.urlopen("https://datasets-server.huggingface.co/filter?"+q))
assert d["num_rows_total"]==1, d.get("num_rows_total")
r=d["rows"][0]["row"]
open("problem_statement.md","w").write(r["problem_statement"])
open("test_patch.diff","w").write(r["test_patch"])
open("gold_patch.diff","w").write(r["patch"])
json.dump({"FAIL_TO_PASS":json.loads(r["FAIL_TO_PASS"]) if isinstance(r["FAIL_TO_PASS"],str) else r["FAIL_TO_PASS"],
           "PASS_TO_PASS":json.loads(r["PASS_TO_PASS"]) if isinstance(r["PASS_TO_PASS"],str) else r["PASS_TO_PASS"],
           "base_commit":r["base_commit"]},open("grading.json","w"),indent=2)
print("base_commit:",r["base_commit"])
PY
# EXPECT: base_commit: 16bba78f1549cfd7909b61ebd7c55c822c86630b

# H6 [HOST] cloud-init meta-data
cat > meta-data <<'EOF'
instance-id: iid-tracevm-0001
local-hostname: tracevm
EOF
```

```bash
# H7 [HOST] cloud-init user-data  (BUILD PASS only — network stays UP, no poweroff,
#     no network masking. Sealing happens later in Phase S.)
cat > user-data.tmpl <<'YAML'
#cloud-config
hostname: tracevm
manage_etc_hosts: true

users:
  - name: ubuntu
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    ssh_authorized_keys:
      - SSH_KEY_PLACEHOLDER

ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: ubuntu
      password: tracevm
      type: text

growpart: {mode: auto, devices: ['/'], ignore_growroot_disabled: false}
resize_rootfs: true

package_update: true
packages:
  - build-essential
  - git
  - curl
  - wget
  - jq
  - unzip
  - python3-venv
  - python3-pip

write_files:
  # ---- GRUB: 50-cloudimg-settings.cfg re-assigns GRUB_CMDLINE_LINUX_DEFAULT,
  # ---- so /etc/default/grub edits are silently discarded. 99- sorts after 50-.
  - path: /etc/default/grub.d/99-tracing.cfg
    permissions: '0644'
    content: |
      GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0 isolcpus=managed_irq,domain,1 nohz_full=1 rcu_nocbs=1 irqaffinity=0,2,3 norandmaps transparent_hugepage=never nowatchdog audit=0 mitigations=off"
      GRUB_TIMEOUT=0
      GRUB_RECORDFAIL_TIMEOUT=0
      GRUB_TERMINAL=console

  - path: /etc/sysctl.d/99-tracing.conf
    permissions: '0644'
    content: |
      kernel.randomize_va_space = 0
      kernel.nmi_watchdog = 0
      kernel.watchdog = 0
      kernel.timer_migration = 0
      kernel.numa_balancing = 0
      vm.stat_interval = 300
      vm.swappiness = 0

  # ---- go's OWN env file. Format is KEY=VALUE, rest-of-line, NO QUOTES.
  # ---- GOPROXY is deliberately absent here (build pass needs the default);
  # ---- Phase S appends GOPROXY=off.
  - path: /etc/go/env
    permissions: '0644'
    content: |
      GOTOOLCHAIN=local
      GOFLAGS=-mod=readonly -buildvcs=false
      GOPATH=/opt/go
      GOMODCACHE=/opt/go/pkg/mod
      GOCACHE=/opt/gocache
      GOSUMDB=off
      CGO_ENABLED=1

  # ---- systemd EnvironmentFile AND shell-sourceable. Values MUST be quoted
  # ---- (systemd strips quotes; `. file` would otherwise split on spaces).
  - path: /etc/trace-env
    permissions: '0644'
    content: |
      PATH="/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      GOROOT="/usr/local/go"
      GOENV="/etc/go/env"
      GOPATH="/opt/go"
      GOMODCACHE="/opt/go/pkg/mod"
      GOCACHE="/opt/gocache"
      GOTOOLCHAIN="local"
      GOSUMDB="off"
      GOFLAGS="-mod=readonly -buildvcs=false"
      CGO_ENABLED="1"
      LITELLM_LOCAL_MODEL_COST_MAP="True"
      HF_HUB_OFFLINE="1"
      HF_DATASETS_OFFLINE="1"
      TRANSFORMERS_OFFLINE="1"
      GIT_TERMINAL_PROMPT="0"

  - path: /etc/profile.d/00-trace-env.sh
    permissions: '0644'
    content: |
      set -a; . /etc/trace-env; set +a

  - path: /usr/local/sbin/trace-quiesce.sh
    permissions: '0755'
    content: |
      #!/bin/sh
      set -u
      HKMASK=d       # CPUs 0,2,3
      HKLIST=0,2,3
      echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
      echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
      echo 0     > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
      swapoff -a 2>/dev/null || true
      echo $HKMASK > /proc/irq/default_smp_affinity 2>/dev/null || true
      # kernel-managed virtio MSI-X vectors return EIO -> must swallow errors
      for d in /proc/irq/[0-9]*; do echo $HKLIST > "$d/smp_affinity_list" 2>/dev/null || true; done
      echo $HKMASK > /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true
      for w in /sys/bus/workqueue/devices/*/cpumask; do echo $HKMASK > "$w" 2>/dev/null || true; done
      mount -o remount,commit=600 / 2>/dev/null || true
      exit 0

  - path: /etc/systemd/system/trace-quiesce.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Quiesce isolated vCPU for tracing
      DefaultDependencies=no
      After=sysinit.target
      Before=multi-user.target
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/sbin/trace-quiesce.sh
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/trace.slice
    permissions: '0644'
    content: |
      [Unit]
      Description=Isolated-vCPU slice for the traced agent
      [Slice]
      AllowedCPUs=1
      AllowedMemoryNodes=0

  - path: /etc/systemd/system/housekeep.slice
    permissions: '0644'
    content: |
      [Unit]
      Description=Housekeeping slice (never CPU 1)
      [Slice]
      AllowedCPUs=0,2,3
      AllowedMemoryNodes=0

  - path: /etc/systemd/system/llmproxy.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Local OpenAI-compatible record/replay proxy
      Before=trace-prewarm.service traced-agent.service
      [Service]
      Type=simple
      Slice=housekeep.slice
      Environment=LLMPROXY_MODE=replay
      Environment=LLMPROXY_LOG=/opt/llmproxy/transcript.jsonl
      ExecStart=/usr/bin/python3 /opt/llmproxy/llmproxy.py
      Restart=no

  - path: /etc/systemd/system/trace-prewarm.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Re-warm GOCACHE off the isolated vCPU, then void test-result cache
      Before=traced-agent.service
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      Slice=housekeep.slice
      EnvironmentFile=/etc/trace-env
      Environment=GOMAXPROCS=3
      Environment=GOPROXY=off
      WorkingDirectory=/prometheus
      TimeoutStartSec=infinity
      ExecStart=/usr/local/go/bin/go test -c -o /dev/null ./tsdb
      ExecStart=/usr/local/go/bin/go clean -testcache

  - path: /etc/systemd/system/traced-agent.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SWE-agent traced run pinned to vCPU 1
      After=multi-user.target llmproxy.service trace-prewarm.service
      Requires=llmproxy.service trace-prewarm.service
      [Service]
      Type=oneshot
      Slice=trace.slice
      AllowedCPUs=1
      AllowedMemoryNodes=0
      CPUAffinity=1
      EnvironmentFile=/etc/trace-env
      Environment=GOMAXPROCS=1
      Environment=GOPROXY=off
      WorkingDirectory=/root
      TimeoutStartSec=infinity
      StandardOutput=journal+console
      StandardError=journal+console
      ExecStartPre=/bin/sh -c 'stty -F /dev/ttyS1 raw speed 115200 >/dev/null 2>&1 || true'
      ExecStart=/root/run_agent.sh

runcmd:
  - [ update-grub ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, trace-quiesce.service ]
  - [ systemctl, mask, serial-getty@ttyS1.service ]
  - systemctl disable --now unattended-upgrades.service snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service snapd.autoimport.service snapd.core-fixup.service snapd.recovery-chooser-trigger.service ModemManager.service pollinate.service ubuntu-advantage.service ua-reboot-cmds.service open-vm-tools.service secureboot-db.service sysstat.service ufw.service cron.service rsyslog.service apport.service lxd-installer.socket multipathd.socket iscsid.socket dm-event.socket apport-forward.socket uuidd.socket networkd-dispatcher.service systemd-timesyncd.service || true
  - systemctl disable --now apt-daily.timer apt-daily-upgrade.timer motd-news.timer fwupd-refresh.timer update-notifier-download.timer update-notifier-motd.timer ua-timer.timer man-db.timer logrotate.timer dpkg-db-backup.timer e2scrub_all.timer fstrim.timer snapd.snap-repair.timer apport-autoreport.timer || true
  - systemctl mask snapd.service snapd.socket unattended-upgrades.service || true
  - [ sh, -c, 'sed -i "/\bswap\b/d" /etc/fstab' ]
  - [ sh, -c, 'mkdir -p /opt/go /opt/gocache /opt/llmproxy' ]

power_state: {mode: reboot, timeout: 300, condition: true}
YAML
sed "s|SSH_KEY_PLACEHOLDER|$(cat ~/.ssh/id_ed25519.pub)|" user-data.tmpl > user-data
head -8 user-data
```

```bash
# H8 [HOST] seed ISO without genisoimage/cloud-localds/sudo (PEP-668-safe venv)
python3 -m venv ~/vm/trace/.venv
~/vm/trace/.venv/bin/pip install pycdlib
cat > make_seed.py <<'PY'
#!/usr/bin/env python3
import io, os, sys, pycdlib
out, files = sys.argv[1], sys.argv[2:]
iso = pycdlib.PyCdlib()
iso.new(interchange_level=3, joliet=3, rock_ridge='1.09', vol_ident='CIDATA')
for path in files:
    name = os.path.basename(path); data = open(path,'rb').read()
    iso.add_fp(io.BytesIO(data), len(data),
               '/' + name.upper().replace('-','_').replace('.','_') + '.;1',
               rr_name=name, joliet_path='/'+name)
iso.write(out); iso.close(); print('wrote', out, os.path.getsize(out), 'bytes')
PY
~/vm/trace/.venv/bin/python make_seed.py seed.iso user-data meta-data
file seed.iso        # EXPECT: ... ISO 9660 CD-ROM filesystem data 'CIDATA'

# H9 [HOST] BUILD BOOT — KVM, network UP. cloud-init will reboot once, on its own.
cd ~/vm/trace && rm -f build-console.log
~/qemu-custom/bin/qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4,sockets=1,cores=4,threads=1 -m 16384 \
  -nographic -nodefaults -serial mon:stdio \
  -drive file=disk.qcow2,if=virtio,format=qcow2,cache=writeback \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci
#    (leave this running in a terminal; ctrl-a x to kill)

# H10 [HOST] once it reboots, copy the benchmark inputs in
ssh-keygen -R '[127.0.0.1]:2222' 2>/dev/null || true
scp -P 2222 -o StrictHostKeyChecking=no problem_statement.md test_patch.diff \
    gold_patch.diff grading.json ubuntu@127.0.0.1:/tmp/
```

### Phase G — inside the guest, network UP, everything as root

```bash
# G1 [GUEST] confirm cloud-init finished cleanly BEFORE building on top of it
sudo cloud-init status --wait          # EXPECT: status: done
sudo cloud-init schema --system        # EXPECT: Valid schema user-data
grep -icE 'deprecat|error' /var/log/cloud-init.log   # inspect anything > 0

# G2 [GUEST] Go 1.23.8 — official tarball, sha256-verified
cd /tmp && curl -fsSLO https://go.dev/dl/go1.23.8.linux-amd64.tar.gz
echo '45b87381172a58d62c977f27c4683c8681ef36580abecd14fd124d24ca306d3f  go1.23.8.linux-amd64.tar.gz' | sha256sum -c -
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go1.23.8.linux-amd64.tar.gz
rm -f /tmp/go1.23.8.linux-amd64.tar.gz
# belt: the tarball ships GOTOOLCHAIN=auto in $GOROOT/go.env
sudo sed -i 's/^GOTOOLCHAIN=auto$/GOTOOLCHAIN=local/' /usr/local/go/go.env
grep -n . /usr/local/go/go.env

# G3 [GUEST] make the env reach the AGENT's bash (SWE-ReX sources /root/.bashrc)
sudo install -d -m 0755 /root
sudo cp /root/.bashrc /root/.bashrc.orig 2>/dev/null || sudo touch /root/.bashrc.orig
sudo sh -c 'printf "set -a\n. /etc/trace-env\nset +a\n" | cat - /root/.bashrc.orig > /root/.bashrc'
sudo mkdir -p /root/.config/go && sudo ln -sfn /etc/go/env /root/.config/go/env
sudo -i bash -lc 'go version'   # EXPECT: go version go1.23.8 linux/amd64

# G4 [GUEST] telemetry off (per-user file, so do it for root AND ubuntu)
sudo -i bash -lc 'go telemetry off'
bash -lc 'go telemetry off'

# G5 [GUEST] cache dirs
sudo mkdir -p /opt/go/pkg/mod /opt/gocache && sudo chmod 0755 /opt/go /opt/gocache

# G6 [GUEST] clone prometheus at /prometheus (NOT /testbed — SWE-agent LOCAL needs /<repo_name>)
sudo git clone -o origin https://github.com/prometheus/prometheus /prometheus
sudo git -C /prometheus reset --hard 16bba78f1549cfd7909b61ebd7c55c822c86630b
sudo git -C /prometheus rev-parse HEAD
sudo git -C /prometheus remote remove origin
sudo git -C /prometheus reflog expire --expire=now --all
sudo git -C /prometheus gc --prune=now
sudo git config --global --add safe.directory /prometheus
sudo -i bash -lc 'git config --global --add safe.directory /prometheus'

# G7 [GUEST] populate the module cache (as root, so it lands under root's view of the env)
sudo -i bash -lc 'cd /prometheus && go env GOVERSION GOROOT GOMODCACHE GOCACHE GOTOOLCHAIN GOPROXY GOFLAGS CGO_ENABLED'
sudo -i bash -lc 'cd /prometheus && go mod download'
sudo -i bash -lc 'cd /prometheus && go list -m all >/dev/null || true'   # seeds .info files (golang/go#42723)
sudo -i bash -lc 'cd /prometheus && go mod download all'                 # superset (R3); dirties go.sum
sudo -i bash -lc 'cd /prometheus && git checkout -- go.mod go.sum'       # <-- undo the +144 go.sum lines (R1)
sudo -i bash -lc 'cd /prometheus && go mod verify'                       # EXPECT: all modules verified
sudo git -C /prometheus status --porcelain                               # EXPECT: EMPTY

# G8 [GUEST] warm the build cache. NOTE -o /dev/null: bare `go test -c ./tsdb`
#     drops a 32 MB `tsdb.test` into the repo (SWE-bench's literal install step does this).
sudo -i bash -lc 'cd /prometheus && go build ./...'
sudo -i bash -lc 'cd /prometheus && go test -c -o /dev/null ./tsdb'
sudo -i bash -lc 'cd /prometheus && go test -count=1 -run "^\$" ./...'     # compiles every test binary
sudo -i bash -lc 'cd /prometheus && go vet ./tsdb || true'                 # ALWAYS || true: 3 pre-existing
                                                                           # stdmethods false positives => exit 1
sudo git -C /prometheus status --porcelain                                 # EXPECT: EMPTY
du -sh /opt/go/pkg/mod /opt/gocache /usr/local/go /prometheus

# G9 [GUEST] SWE-agent, pinned commit (PyPI `sweagent` is a dead 0.0.1 stub — never pip-install it)
sudo git clone https://github.com/SWE-agent/SWE-agent.git /opt/SWE-agent
sudo git -C /opt/SWE-agent checkout 3ea751c087f32b16e039a2233dd6eefecef325d5
sudo python3.12 -m venv /opt/swea-venv
sudo /opt/swea-venv/bin/python -m pip install --upgrade pip
sudo /opt/swea-venv/bin/pip install --editable /opt/SWE-agent
sudo /opt/swea-venv/bin/sweagent --help | head -3
# EXPECT a line containing: SWE-agent version 1.1.0 ... SWE-ReX version 1.4.0

# G10 [GUEST] pre-install the tool-bundle deps so edit_anthropic/install.sh short-circuits offline
sudo /opt/swea-venv/bin/pip install 'tree-sitter==0.21.3' 'tree-sitter-languages'
sudo /opt/swea-venv/bin/pip show tree-sitter | head -2   # EXPECT: Version: 0.21.3

# G11 [GUEST] benchmark inputs into place
sudo cp /tmp/problem_statement.md /root/problem_statement.md
sudo mkdir -p /opt/bench && sudo cp /tmp/test_patch.diff /tmp/gold_patch.diff /tmp/grading.json /opt/bench/
sudo chmod 0644 /root/problem_statement.md /opt/bench/*
wc -c /root/problem_statement.md    # EXPECT: non-zero

# G12 [GUEST] the record/replay LLM proxy (see Appendix A for llmproxy.py)
sudo mkdir -p /opt/llmproxy
sudo tee /opt/llmproxy/llmproxy.py >/dev/null <<'PY'
<<< paste Appendix A verbatim >>>
PY
sudo chmod 0755 /opt/llmproxy/llmproxy.py

# G13 [GUEST] the run script
sudo tee /root/run_agent.sh >/dev/null <<'SH'
#!/bin/bash
set -u
MK=/dev/ttyS1
export PIP_NO_INDEX=1 PIP_RETRIES=0 PIP_TIMEOUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true
export NO_PROXY='*' no_proxy='*'
export LITELLM_LOCAL_MODEL_COST_MAP=True
export HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 TRANSFORMERS_OFFLINE=1
export GOPROXY=off

# SWE-ReX LocalRuntime.upload uses shutil.copytree WITHOUT dirs_exist_ok:
# a second run dies with FileExistsError unless these are gone.
rm -rf /root/tools /root/state.json /root/.swe-agent-env /root/model.patch /root/swea-out

git -C /prometheus reset --hard -q
git -C /prometheus clean -fdq
[ -z "$(git -C /prometheus status --porcelain)" ] || { echo "FATAL: /prometheus dirty"; exit 1; }

for i in $(seq 100); do
  curl -sf http://127.0.0.1:8000/v1/models >/dev/null && break
  sleep 0.2
done

printf 'TRACE_BEGIN\n' > "$MK"
/opt/swea-venv/bin/sweagent run \
  --config /opt/SWE-agent/config/benchmarks/anthropic_filemap_multilingual.yaml \
  --agent.model.name=openai/local-model \
  --agent.model.api_base=http://127.0.0.1:8000/v1 \
  --agent.model.api_key=dummy-key \
  --agent.model.temperature=0.0 \
  --agent.model.per_instance_cost_limit=0 \
  --agent.model.total_cost_limit=0 \
  --agent.model.per_instance_call_limit=40 \
  --env.deployment.type=local \
  --env.repo.type=preexisting \
  --env.repo.repo_name=prometheus \
  --env.repo.reset=false \
  --problem_statement.type=text_file \
  --problem_statement.path=/root/problem_statement.md \
  --problem_statement.id=prometheus__prometheus-15142 \
  --output_dir=/root/swea-out
rc=$?
printf 'TRACE_END\n' > "$MK"
exit $rc
SH
sudo chmod 0755 /root/run_agent.sh

# G14 [GUEST] RECORD the LLM transcript against the real model (network still UP).
#     Point LLMPROXY_UPSTREAM at your model. From the guest, the host is 10.0.2.2.
sudo rm -rf /root/tools /root/state.json /root/.swe-agent-env /root/model.patch /root/swea-record
sudo rm -f /opt/llmproxy/transcript.jsonl
sudo -i env LLMPROXY_MODE=record \
     LLMPROXY_UPSTREAM=http://10.0.2.2:8000/v1 \
     LLMPROXY_UPSTREAM_KEY=<your-key> \
     LLMPROXY_LOG=/opt/llmproxy/transcript.jsonl \
     nohup python3 /opt/llmproxy/llmproxy.py >/var/log/llmproxy.log 2>&1 &
sleep 2 && curl -sf http://127.0.0.1:8000/v1/models

sudo -i bash -lc '/root/run_agent.sh; echo "AGENT EXIT=$?"'
wc -l /opt/llmproxy/transcript.jsonl                       # EXPECT: >= 1 line per API call
grep -c '"stream": *true' /opt/llmproxy/transcript.jsonl || true   # EXPECT: 0 (see OQ-1)
sudo pkill -f llmproxy.py

# G15 [GUEST] inspect the recorded episode
sudo /opt/swea-venv/bin/python -c "import json;d=json.load(open('/root/swea-out/prometheus__prometheus-15142/prometheus__prometheus-15142.traj'));print('exit_status:',d['info'].get('exit_status'));print('model_stats:',d['info'].get('model_stats'));print('steps:',len(d['trajectory']))"

# G16 [GUEST] wipe every trace of the recording run
sudo rm -rf /root/tools /root/state.json /root/.swe-agent-env /root/model.patch /root/swea-out /root/swea-record
sudo git -C /prometheus reset --hard -q && sudo git -C /prometheus clean -fdq
sudo git -C /prometheus status --porcelain    # EXPECT: EMPTY

# G17 [GUEST] re-warm caches destroyed/created by the recording, then enable the units
sudo -i bash -lc 'cd /prometheus && go build ./... && go test -c -o /dev/null ./tsdb'
sudo systemctl daemon-reload
sudo systemctl enable llmproxy.service trace-prewarm.service
#   traced-agent.service is left DISABLED — start it manually in Pass 2.
```

### Phase R — offline rehearsal (still KVM, but `-nic none`). This is the real gate.

```bash
# R1 [GUEST] quick in-guest gate first (root netns; do NOT use `unshare -rn`,
#     Ubuntu 24.04 blocks unprivileged user namespaces)
sudo unshare -n -- bash -lc 'ip link set lo up; cd /prometheus;
  export GOPROXY=off;
  go list -deps -test ./... >/dev/null &&
  go build ./... &&
  go test -c -o /dev/null ./tsdb &&
  go test -count=1 -run "^TestHead" ./tsdb'; echo "GATE EXIT=$?"
# EXPECT: ok github.com/prometheus/prometheus/tsdb  <seconds>   /  GATE EXIT=0

# R2 [GUEST] prove the guest really is module-locked
sudo unshare -n -- bash -lc 'ip link set lo up; cd /prometheus; export GOPROXY=off;
  go install golang.org/x/tools/cmd/goimports@latest' 2>&1 | head -3
# EXPECT a line containing: module lookup disabled by GOPROXY=off

# R3 [GUEST] measure the COLD cost (tells you what a cold traced run would cost)
sudo rm -rf /opt/gocache-cold && sudo mkdir -p /opt/gocache-cold
sudo unshare -n -- bash -lc 'ip link set lo up; cd /prometheus;
  export GOPROXY=off GOCACHE=/opt/gocache-cold; time go test -c -o /dev/null ./tsdb'
sudo rm -rf /opt/gocache-cold

# R4 [GUEST] FAIL_TO_PASS determinism, in the EXACT cpuset the traced pass uses
sudo git -C /prometheus apply --verbose /opt/bench/test_patch.diff
sudo systemd-run --scope --slice=trace.slice -p AllowedCPUs=1 -p AllowedMemoryNodes=0 \
  bash -lc 'cd /prometheus; export GOPROXY=off GOMAXPROCS=1;
    for i in $(seq 10); do
      go test -count=1 ./tsdb -run "^TestHeadAppendHistogramAndCommitConcurrency$" >/dev/null 2>&1 \
        && echo "$i UNEXPECTED_PASS" || echo "$i EXPECTED_FAIL"; done'
# EXPECT: 10 lines, ALL "EXPECTED_FAIL"

# R5 [GUEST] gold patch flips it (proves the grading contract in-guest)
sudo git -C /prometheus apply --verbose /opt/bench/gold_patch.diff
sudo -i bash -lc 'cd /prometheus && GOPROXY=off go test -count=1 -v ./tsdb -run "^TestHead" >/tmp/gold.log 2>&1; echo EXIT=$?'
# EXPECT: EXIT=0
grep -c '^--- FAIL' /tmp/gold.log        # EXPECT: 0

# R6 [GUEST] restore pristine state
sudo git -C /prometheus checkout -- .
sudo git -C /prometheus reset --hard -q && sudo git -C /prometheus clean -fdq
sudo git -C /prometheus status --porcelain      # EXPECT: EMPTY
sudo git -C /prometheus rev-parse HEAD          # EXPECT: 16bba78f1549cfd7909b61ebd7c55c822c86630b

# R7 [GUEST] shut down, then re-boot the SAME disk with NO NIC and replay the agent
sudo poweroff
```

```bash
# R8 [HOST] offline rehearsal boot: KVM (fast) but -nic none, identical to the traced pass
rm -f /tmp/mk.sock /tmp/rehearse-console.log
cd ~/vm/trace && ~/qemu-custom/bin/qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4,sockets=1,cores=4,threads=1 -m 16384 \
  -display none -nodefaults -nic none \
  -drive file=disk.qcow2,if=virtio,format=qcow2,cache=writeback \
  -chardev file,id=ser0,path=/tmp/rehearse-console.log -device isa-serial,chardev=ser0,index=0 \
  -chardev socket,id=mk,path=/tmp/mk.sock,server=on,wait=off -device isa-serial,chardev=mk,index=1 \
  -device virtio-rng-pci -monitor unix:/tmp/mon.sock,server=on,wait=off
# in another terminal (start AFTER the socket exists — QEMU unlinks it on exit):
nc -U /tmp/mk.sock | stdbuf -oL tr -d '\r' | while IFS= read -r l; do printf '[%s] %s\n' "$(date +%s.%N)" "$l"; done
tail -F /tmp/rehearse-console.log
# with no NIC you have no ssh — drive it from the console log; traced-agent.service
# is started by hand in Pass 2, so for the rehearsal add to the kernel cmdline
# temporarily, or simply run it via the QEMU monitor's `sendkey`-free path:
# easiest: before R7, `sudo systemctl enable traced-agent.service`, rehearse,
# then `systemctl disable` it again in Phase S.
```

**Rehearsal must show:** `TRACE_BEGIN` on the marker socket, a run that reaches the model (replayed), then `TRACE_END`, and `/root/swea-out/.../*.traj` present with a non-null `info.exit_status`.

### Phase S — seal the image (LAST; nothing re-applies after this)

```bash
# S1 [GUEST] (boot once more WITH network to seal, or do it before R7)
sudo sh -c 'echo GOPROXY=off >> /etc/go/env'
sudo sh -c 'echo "GOPROXY=\"off\"" >> /etc/trace-env'
sudo -i bash -lc 'go env GOPROXY'                     # EXPECT: off

# S2 [GUEST] kill networking + cloud-init for good
sudo systemctl mask systemd-networkd-wait-online.service systemd-networkd.service \
     systemd-networkd.socket ssh.socket ssh.service
sudo sh -c 'echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
sudo touch /etc/cloud/cloud-init.disabled

# S3 [GUEST] volatile journal (no disk writes from logging during the trace)
sudo mkdir -p /etc/systemd/journald.conf.d
sudo sh -c 'printf "[Journal]\nStorage=volatile\nRuntimeMaxUse=32M\n" > /etc/systemd/journald.conf.d/99-tracing.conf'

# S4 [GUEST] final hygiene
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/* /tmp/*.diff /tmp/*.md /tmp/grading.json
sudo -i bash -lc 'cd /prometheus && go clean -testcache'
sudo git -C /prometheus status --porcelain            # EXPECT: EMPTY
sudo systemctl disable traced-agent.service || true   # Pass 2 starts it by hand
sudo poweroff

# S5 [HOST] snapshot: keep disk.qcow2 re-provisionable, trace from a copy
cd ~/vm/trace && cp disk.qcow2 disk-traced.qcow2
~/qemu-custom/bin/qemu-img info disk-traced.qcow2
sha256sum disk.qcow2 > disk.qcow2.sha256
```

---

## 2. ENVIRONMENT VARIABLES — value and where each must persist

There are **four** places env must land, because they are read by four different mechanisms:

| Sink | Format | Read by |
|---|---|---|
| `/etc/go/env` (`GOENV` points here) | `KEY=VALUE`, **no quotes**, rest-of-line | the `go` command itself |
| `/etc/trace-env` | `KEY="VALUE"`, **quoted** | systemd `EnvironmentFile=` **and** `. /etc/trace-env` |
| `/root/.bashrc` (line 1: `set -a; . /etc/trace-env; set +a`) | shell | **the agent's own bash** — SWE-ReX's `startup_source` is `/root/.bashrc` |
| `/etc/profile.d/00-trace-env.sh` | shell | your interactive ssh sessions |

| Variable | Value | `/etc/go/env` | `/etc/trace-env` | unit `Environment=` | `run_agent.sh` |
|---|---|:--:|:--:|:--:|:--:|
| `PATH` | `/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` | | ✅ | | |
| `GOROOT` | `/usr/local/go` | | ✅ | | |
| `GOENV` | `/etc/go/env` | — (chicken/egg) | ✅ | | |
| `GOPATH` | `/opt/go` | ✅ | ✅ | | |
| `GOMODCACHE` | `/opt/go/pkg/mod` | ✅ | ✅ | | |
| `GOCACHE` | `/opt/gocache` (absolute; `GOCACHE=off` is fatal) | ✅ | ✅ | | |
| `GOTOOLCHAIN` | `local` — also `sed` it into `/usr/local/go/go.env` | ✅ | ✅ | | |
| `GOFLAGS` | `-mod=readonly -buildvcs=false` | ✅ | ✅ | ❌ never override | |
| `GOSUMDB` | `off` | ✅ | ✅ | | |
| `CGO_ENABLED` | `1` (explicit; must be identical in both passes) | ✅ | ✅ | | |
| `GOPROXY` | **absent during build**, `off` after Phase S | ✅ (S1) | ✅ (S1) | ✅ | ✅ |
| `GOMAXPROCS` | `1` traced / `3` prewarm — **not** in `/etc/trace-env` (would serialize provisioning) | | | ✅ | |
| `LITELLM_LOCAL_MODEL_COST_MAP` | `True` | | ✅ | | ✅ |
| `HF_HUB_OFFLINE` / `HF_DATASETS_OFFLINE` / `TRANSFORMERS_OFFLINE` | `1` | | ✅ | | ✅ |
| `GIT_TERMINAL_PROMPT` | `0` | | ✅ | | ✅ |
| `GIT_ASKPASS` | `/bin/true` | | | | ✅ |
| `PIP_NO_INDEX` `PIP_RETRIES=0` `PIP_TIMEOUT=1` `PIP_DISABLE_PIP_VERSION_CHECK=1` | as shown — **traced pass only** (would break provisioning pip) | | | | ✅ |
| `NO_PROXY` / `no_proxy` | `*` | | | | ✅ |
| `LLMPROXY_MODE` / `LLMPROXY_LOG` / `LLMPROXY_UPSTREAM` | `replay` / `/opt/llmproxy/transcript.jsonl` / recording only | | | ✅ (llmproxy.service) | |

**Deliberately NOT set:** `GOPRIVATE`, `GONOPROXY`, `GONOSUMDB` (see C7), `GOTELEMETRY` (read-only; use `go telemetry off`), `GOFLAGS=-p=1` (use `GOMAXPROCS=1`; `-p` defaults to it).

**Never use `go env -w`** — it writes `$HOME/.config/go/env`, per-user, and silently misses any process with a different `HOME`.

---

## 3. VERIFICATION CHECKLIST

| # | What it proves | Command | Expected |
|---|---|---|---|
| V1 | image integrity | `[HOST] grep ' \*noble-server-cloudimg-amd64.img$' SHA256SUMS \| sha256sum -c -` | `noble-server-cloudimg-amd64.img: OK` |
| V2 | seed ISO valid | `[HOST] file seed.iso` | `ISO 9660 CD-ROM filesystem data 'CIDATA'` |
| V3 | cloud-init applied | `[G] sudo cloud-init status --wait; sudo cloud-init schema --system` | `status: done` / `Valid schema user-data` |
| V4 | disk grew | `[G] df -h --output=size,avail /` | size ≈ `39G` |
| V5 | **isolcpus took effect** | `[G] cat /proc/cmdline; cat /sys/devices/system/cpu/isolated; cat /sys/devices/system/cpu/nohz_full` | cmdline contains `isolcpus=managed_irq,domain,1`; then `1`; then `1` |
| V6 | RCU offload actually happened | `[G] dmesg \| grep -iE 'isolcpus\|nohz\|rcu_nocbs\|Offload RCU\|housekeeping'` | lines naming CPU 1 for nohz_full / rcu_nocbs |
| V7 | no IRQ lands on CPU 1 | `[G] for d in /proc/irq/[0-9]*; do printf '%s %s\n' "${d##*/}" "$(cat $d/smp_affinity_list 2>/dev/null)"; done \| awk '$2 ~ /(^\|,)1(,\|$)/ \|\| $2 ~ /-/ {print "LEAK "$0}'` | **no output** (any range like `0-3` also counts as a leak) |
| V8 | workqueues off CPU 1 | `[G] cat /sys/devices/virtual/workqueue/cpumask; cat /proc/irq/default_smp_affinity` | `d` / `d` |
| V9 | THP + ASLR + swap | `[G] cat /sys/kernel/mm/transparent_hugepage/enabled; cat /proc/sys/kernel/randomize_va_space; swapon --show` | `always madvise [never]` / `0` / empty |
| V10 | cpuset really binds (the `--user` form silently does nothing) | `[G] sudo systemd-run --scope --slice=trace.slice -p AllowedCPUs=1 -p AllowedMemoryNodes=0 bash -c 'grep Cpus_allowed_list /proc/self/status; nproc'` | `Cpus_allowed_list: 1` and `1` |
| V11 | unit will bind too | `[G] systemctl show -p AllowedCPUs -p EffectiveCPUs -p CPUAffinity traced-agent.service` | `AllowedCPUs=1`, `CPUAffinity=1` |
| V12 | Go version | `[G] sudo -i bash -lc 'go version'` | `go version go1.23.8 linux/amd64` |
| V13 | **env reaches the agent's shell**, not just yours | `[G] sudo -i bash -lc 'go env GOROOT GOMODCACHE GOCACHE GOTOOLCHAIN GOPROXY GOFLAGS CGO_ENABLED'` | `/usr/local/go` `/opt/go/pkg/mod` `/opt/gocache` `local` `off`(post-seal) `-mod=readonly -buildvcs=false` `1` |
| V14 | repo pristine + pinned + remote-less | `[G] sudo git -C /prometheus rev-parse HEAD; sudo git -C /prometheus remote; sudo git -C /prometheus status --porcelain` | `16bba78f1549cfd7909b61ebd7c55c822c86630b` / empty / empty |
| V15 | no `tsdb.test` pollution | `[G] ls /prometheus/tsdb.test` | `No such file or directory` |
| V16 | **module cache complete OFFLINE** | R1 gate above | last line `ok  github.com/prometheus/prometheus/tsdb  <n>s`, `GATE EXIT=0` |
| V17 | guest really is module-locked | R2 gate above | `module lookup disabled by GOPROXY=off` |
| V18 | module cache uncorrupted after image copy | `[G] sudo -i bash -lc 'cd /prometheus && go mod verify'` | `all modules verified` |
| V19 | no vendor-mode surprise | `[G] test ! -d /prometheus/vendor && echo NO_VENDOR` | `NO_VENDOR` |
| V20 | **FAIL_TO_PASS is deterministic on the pinned vCPU** | R4 loop | 10 × `EXPECTED_FAIL` |
| V21 | gold patch flips it | R5 | `EXIT=0`, zero `--- FAIL` |
| V22 | correct SWE-agent, not the PyPI stub | `[G] sudo /opt/swea-venv/bin/sweagent --help \| head -3` | contains `SWE-agent version 1.1.0` and `SWE-ReX version 1.4.0` |
| V23 | tool deps pre-installed | `[G] sudo /opt/swea-venv/bin/pip show tree-sitter \| head -2` | `Version: 0.21.3` |
| V24 | agent startup is not stalling on the network | `[G] grep -n 'Resetting repository\|pip\|Retrying' /root/swea-out/*/*.debug.log` and time from process start to first proxy hit | seconds, not minutes; no 120 s stall |
| V25 | run was bounded | `[G] python -c "…json…"` on the `.traj` | `model_stats.api_calls` ≤ `per_instance_call_limit` |
| V26 | test-result cache will not no-op the traced run | `[G] grep -c '(cached)' /tmp/gold.log` | `0` (and `go clean -testcache` in `trace-prewarm.service`) |
| V27 | build cache still warm at trace time | `[G] time (cd /prometheus && go test -c -o /dev/null ./tsdb)` | ≲ 8 s at 4 vCPU native; > 10 s means the cache trimmed |
| V28 | no NIC in the rehearsal/traced boot | `[G] ip -o link` | only `lo` |
| V29 | mitigation set recorded & identical between passes | `[G] grep . /sys/devices/system/cpu/vulnerabilities/*` under KVM and under TCG, then `diff` | identical (with `mitigations=off`, all `Vulnerable`/`Not affected`) |
| V30 | marker channel works | `[HOST] nc -U /tmp/mk.sock` while `[G] printf 'TRACE_BEGIN\n' > /dev/ttyS1` | `TRACE_BEGIN` on the host |

---

## 4. CONTRADICTIONS BETWEEN THE REPORTS

**C1 — base_commit. R1 `16bba78f1549cfd7909b61ebd7c55c822c86630b` vs R3 `032ca9ef96ce0dd236c75bcdea2a8e9f7a74c6e8`.**
Not the same thing: R3 read the *PR's* base sha off the GitHub API; R1 read the *dataset's* `base_commit` and then **applied both patches and reproduced fail→pass**. **Use R1's.** Verify with V14 + R5. Getting this wrong is discovered only when `git apply` of the test patch fails — hours in.

**C2 — `go mod download` vs `go mod download all`.** R3 calls plain download "THE #1 TRAP" (argued from the Go 1.18 release notes) but **ran no Go commands at all** (no toolchain on their host). R1 **empirically verified** that plain `go mod download` is sufficient for offline `go build ./...`, `go test -c ./tsdb`, `go test -run='^$' ./...` and `go list -deps -test ./...`, **and** that `go mod download all` adds **+144 lines to go.sum**, which would pollute the agent's diff and fail SWE-bench grading. Resolution in G7: do both, then `git checkout -- go.mod go.sum`, then assert `git status --porcelain` empty (V14) and gate offline (V16). Reverting go.sum is safe because nothing in the build graph needs the extra entries.

**C3 — repo path. `/testbed` (R1) vs `/prometheus` (R2) vs `/opt/prometheus` (R3).** R2 read SWE-agent's source: `SWEEnv.reset()` does `cd /` then `cd /<repo_name>`; `LocalRepoConfig.copy()` targets `/{repo_name}`. Since the **agent** is the workload, `/prometheus` wins. `/testbed` is only SWE-bench's *Docker* convention and matters only at grading time; `/opt/prometheus` was arbitrary. Do **not** symlink `/testbed → /prometheus`.

**C4 — who runs the agent. R2: must be root. R4's unit: `User=ubuntu`.** R2 reproduced `PermissionError: [Errno 13] … '/root/tools'` as uid 1000, and there is no config key to relocate those paths. **Root wins; R4's `User=`/`Group=` lines are deleted above.** Consequence: `HOME=/root`, hence the `/root/.bashrc` and `/root/.config/go/env` wiring in G3.

**C5 — Go install method.** R2's command list has `apt-get install golang-go`. R3 verified noble's candidate is `2:1.22~2build1`. With `GOTOOLCHAIN=local` that cannot self-heal and any dep declaring `go 1.23.x` dies with `requires go >= 1.23.0 (running go 1.22.2; GOTOOLCHAIN=local)`. **Tarball only.** (R1 and R3 independently agree on `go1.23.8`; R3's sha256 `45b8738…` and R1's size `73,666,093` are cross-consistent.)

**C6 — `go vet`.** R2's build-pass line and R3's command list both run `go vet ./...` bare. R1 proved `go vet ./tsdb` **exits 1** at base_commit on 3 pre-existing `stdmethods` false positives. Under `set -e` that aborts provisioning. **Always `|| true`; never a gate.**

**C7 — `GOPRIVATE='*'` / `GONOPROXY='*'` (R3) actively undermines `GOPROXY=off` (also R3).** `GONOPROXY` means "fetch these directly, bypassing GOPROXY". On a cache miss you would get a DNS/TCP hang instead of the instant `module lookup disabled by GOPROXY=off`, i.e. exactly the trace-polluting stall you are trying to prevent. Neither report tested this. It buys nothing when the cache is complete. **Dropped.** Confidence: medium-high on the mechanism, high on "dropping it is safe".

**C8 — `export GOTELEMETRY=off` (R3) is a no-op.** R3's own findings say `GOTELEMETRY` is a *read-only reporting* var; the mode lives in `os.UserConfigDir()/go/telemetry`. **Use `go telemetry off`, once per user that will run `go` (G4).**

**C9 — the offline gate's own mechanism.** R3's gate is `unshare -rn` (unprivileged). R2 independently reported that Ubuntu 24.04 restricts unprivileged user namespaces. **Run it as root with plain `unshare -n`** (no `-r`), and treat the `-nic none` rehearsal boot (R8) as the authoritative proof.

**C10 — R4's unit sets `Environment=GOFLAGS=-p=1`,** which is process env and therefore **clobbers** `-mod=readonly -buildvcs=false` from `/etc/go/env`. Silent loss of the readonly guard. **Removed;** `GOMAXPROCS=1` already makes `-p` default to 1 (R3's own finding).

**C11 — `-buildvcs=false` (R3) is a deviation R1 did not use.** It removes a `git` subprocess from every build (good for trace cleanliness, and it dodges the `dubious ownership` → `error obtaining VCS status: exit status 128` failure mode) but it **changes build-cache keys**. Must be identical in both passes → it lives in `/etc/go/env`, set once, before the cache is warmed.

**C12 — `CGO_ENABLED` left implicit by R1 and flagged as ambiguous by R3.** R1 proved the repo has zero `import "C"`, so `CGO_ENABLED=0` builds everything; but the default 1 pulls `runtime/cgo` via stdlib `net`/`os/user` and puts gcc subprocesses in the trace. A mismatch between passes is an invisible full-cache-miss generator. **Set explicitly to `1`** (matches SWE-bench's `wget git build-essential` base image). See OQ-4.

**C13 — R4's user-data does provisioning-hostile things.** It sets `network: {config: disabled}`, masks `systemd-networkd`, and `power_state: poweroff` — all in the *same* user-data that is supposed to install ~4 GB of Go artifacts over the network. Applied as written you get a sealed, empty image. **Split: build-pass user-data (network up, `power_state: reboot`) → provisioning → rehearsal → Phase S seal.**

**C14 — `qemu-guest-agent` in R4's package list** with no `virtio-serial`/`virtserialport` device on any of R4's QEMU command lines → a service that fails and retries, i.e. noise. **Dropped.** The bidirectional `ttyS1` socket already gives you the out-of-band channel. Add `-device virtio-serial -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0` if you want it back.

**C15 — the model endpoint is unresolved across all four reports.** R2 assumes `http://127.0.0.1:8000/v1` *inside the guest*; R4's traced-pass boot is `-nic none`. Nothing in the guest listens on 8000 unless you put it there. This is **OQ-1** and it is the single biggest gap.

**C16 — `--instances.type=swe_bench` (the obvious command) cannot work.** R2 source-read that `SimpleBatchInstance.from_swe_bench()` always fills a Docker image name and `to_full_batch_instance()` then raises `ValueError: Local deployment does not support image_name`; it also needs HF network. R1's SWE-bench "setup/eval procedure" is a *Docker* recipe and is only relevant for **grading after the trace**, not for running the agent. Use `sweagent run` (single) as above.

**C17 — disk size.** R4 says 100 G; measured needs are ≈ 3.5 GB Go + ≈ 1.5 GB agent/OS. 40 G chosen. Harmless either way (qcow2 is sparse) but 40 G keeps the two image copies small.

**Lowest-confidence areas, explicitly:**
- **R3 executed nothing** (no Go on their host). Every Go env-file / precedence / `GOPROXY=off` claim is doc-derived. Covered by V13, V16, V17.
- **R2 could not run the full agent loop** (userns blocked on their host); they validated by redirecting the hardcoded `/root` paths. The `/root`-as-root path and Go-repo-specific agent behavior are **inferred from source**. Covered by G14 + V22–V25 — if G14 fails, everything downstream is wrong.
- **R1 could not test TCG.** The FAIL_TO_PASS determinism claim (10/10) is native-only. Covered by V20 under KVM+cpuset; **it must be re-run once under TCG in Pass 2 before recording.**
- R2 did not confirm `tree-sitter-languages` installs cleanly on Python 3.12; if it doesn't, the `|| true` in `edit_anthropic/install.sh` hides it and `PIP_NO_INDEX=1` keeps the offline retry to milliseconds. Check V23.

---

## 5. OPEN QUESTIONS FOR THE HUMAN

**OQ-1 (blocking) — where does the LLM live during the traced, network-less pass?**
`--agent.model.api_base=http://127.0.0.1:8000/v1` requires a listener *inside* the guest. Three options:
 (a) **record on the build pass, replay in the guest** (what this recipe implements: `llmproxy.py`, Appendix A). Fully offline, fully deterministic, but the agent's trajectory is frozen — if guest state diverges the replayed responses become nonsense. Replay is keyed on **call index**; decide whether you also want a hard abort on request-hash mismatch.
 (b) run a real small model in the guest (adds GB of weights and a large, non-agent CPU workload into the trace on the same or another vCPU).
 (c) keep a restricted slirp NIC (`-netdev user,restrict=on,guestfwd=...`) to reach a host-side model — violates "NO NETWORK" and injects virtio-net IRQs.
 Also confirm your model/proxy **implements OpenAI `tool_calls`** (the multilingual config uses `parse_function: function_calling`) and that litellm is **not** requesting `"stream": true` (grep the recorded transcript; the replay proxy returns non-streamed bodies only).

**OQ-2 — trace window and episode length.** `per_instance_call_limit` defaults to **0 = disabled** once you zero the cost limits (mandatory for a local model); R2's unbounded run hit 57 calls and kept going. `40` is a placeholder in `run_agent.sh`. Budget: R1 measured the agent inner loop at **15.8 s @1 CPU native**, and a full `go test -v ./tsdb -run "^TestHead"` at **12.5 s @1 CPU** (8.1 s of which is the unrelated, serial `TestHeadSeriesChunkRace`). At a 10–50× TCG slowdown that is **2.6–13 min per inner loop** and **2–10 min per full test run**, on top of a 4× penalty from the single-vCPU cpuset. Pick N accordingly, and decide whether the traced test command should be the narrow `-run '^TestHeadAppendHistogramAndCommitConcurrency'` (0.22 s native) instead of the full `^TestHead`.

**OQ-3 — warm or cold Go build cache for the traced pass?** Warm is faithful to the SWE-bench harness (which pre-warms via its `install` step) and is what this recipe builds. Cold (`GOCACHE` = fresh dir) is representative of a real first build and, because Go 1.20 stopped shipping prebuilt stdlib archives, means recompiling the whole touched stdlib + the 196-module closure — R3's measurement command R3 above tells you the exact cost before you commit. Note the cache self-trims (~5 days unused, unconfirmed exact window), which is why `trace-prewarm.service` exists.

**OQ-4 — `CGO_ENABLED=1` or `0`?** `1` (chosen) = benchmark-faithful, gcc subprocesses appear in the trace. `0` = pure-Go, no gcc, but different machine code and a partial cold rebuild if you flip it after warming. Whichever you pick, it must be identical in both passes.

**OQ-5 — CPU model / mitigations across passes.** Build pass is `-cpu host` under KVM, traced pass `-cpu max` under TCG → different CPUID → the guest kernel may select **different spectre/meltdown mitigations** (retpoline vs IBRS vs none), which materially changes the **kernel branch mix** — directly relevant to branch-predictor work. This recipe puts `mitigations=off` on the cmdline so both passes are identical and deterministic. If you *want* mitigations in the trace, remove it and instead pin one explicit `-cpu <model>` for both passes and record V29's output alongside the trace.

**OQ-6 — should the agent be able to see the fix?** `git remote remove origin` (both R1 and R2) removes remote-tracking refs, and this recipe adds `reflog expire` + `gc --prune=now`. But **`git clone` also fetched all tags**, and release tags after 2024-10-14 contain the fix (`tsdb/head_append.go`). SWE-bench's own Docker setup leaves tags in place, so keeping them is *faithful*; deleting them (`git tag -d $(git tag)` then `gc --prune=now`) makes a cleaner scientific claim about agent capability. Neither report raises this. **Your call — it changes the workload.**

**OQ-7 — marker granularity.** Currently one `TRACE_BEGIN` before `sweagent run` and one `TRACE_END` after, so the trace includes SWE-agent startup (`/root/tools` copytree, tool-bundle `install.sh`, litellm import). Under TCG that is a non-trivial, non-agent prefix. Option: have `llmproxy.service` (which runs on CPU 0, off the traced vCPU, so its `outb` cost is free) emit a 12-byte marker per API call to `/dev/ttyS1`, giving per-turn phase boundaries. Keep markers ≤ 16 bytes — ISA serial is one emulated `outb` per byte.

**OQ-8 — `anthropic_filemap_multilingual.yaml` vs `default.yaml`.** The multilingual config is correct for Go, but its `multilingual_setup/install.sh` reads `/proc/1/environ` and imports PID-1's environment into the agent shell. In the guest PID 1 is **systemd**, not a container init. R2 says it merges PATH safely and excludes `PWD/LANG/PYTHONPATH`, but the exact import set is unverified — if the agent shell shows unexpected env, this is why. Confirm with `sudo -i bash -lc 'cat /proc/1/environ | tr "\0" "\n"'` and decide whether to switch configs.

---

## Appendix A — `/opt/llmproxy/llmproxy.py`

**Not covered by any of the four reports. Must be validated in G14 before you trust it.**

```python
#!/usr/bin/env python3
"""Record/replay OpenAI-compatible /v1/chat/completions on 127.0.0.1:8000."""
import http.server, json, os, threading, urllib.request

MODE  = os.environ.get("LLMPROXY_MODE", "replay")            # record | replay
LOG   = os.environ.get("LLMPROXY_LOG", "/opt/llmproxy/transcript.jsonl")
UP    = os.environ.get("LLMPROXY_UPSTREAM", "")
UPKEY = os.environ.get("LLMPROXY_UPSTREAM_KEY", "")
MK    = os.environ.get("LLMPROXY_MARKER", "")                # e.g. /dev/ttyS1

lock, idx, replies = threading.Lock(), 0, []
if MODE == "replay":
    with open(LOG) as f:
        replies = [json.loads(l)["response"] for l in f if l.strip()]

def mark(s):
    if MK:
        try:
            with open(MK, "wb", buffering=0) as f: f.write((s + "\n").encode())
        except OSError: pass

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send({"object": "list",
                        "data": [{"id": "local-model", "object": "model", "owned_by": "local"}]})
        else:
            self._send({"error": "not found"}, 404)
    def do_POST(self):
        global idx
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        if MODE == "record":
            r = urllib.request.Request(
                UP.rstrip("/") + "/chat/completions",
                data=json.dumps(req).encode(),
                headers={"Content-Type": "application/json",
                         "Authorization": "Bearer " + UPKEY})
            with urllib.request.urlopen(r, timeout=900) as resp:
                out = json.loads(resp.read())
            with lock, open(LOG, "a") as f:
                f.write(json.dumps({"request": req, "response": out}) + "\n")
            self._send(out)
        else:
            with lock:
                i = idx; idx += 1
            mark("LLM_%d" % i)
            if i < len(replies):
                self._send(replies[i])
            else:
                self._send({"error": {"message": "transcript exhausted at call %d" % i,
                                      "type": "replay_error"}}, 500)

http.server.ThreadingHTTPServer(("127.0.0.1", 8000), H).serve_forever()
```

Known limitation: **no streaming support.** If `grep -c '"stream": *true' /opt/llmproxy/transcript.jsonl` is non-zero, replay will break — force `stream=false` in SWE-agent's model config before recording.


---

# Raw per-topic reports

## Making Go builds/tests work with NO NETWORK inside the QEMU guest (prometheus__prometheus-15142)

**Confidence:** high

### Findings
- TARGET IS PINNED BY SWE-BENCH, NOT BY YOU. SWE-bench's Go constants file specifies for instance prometheus__prometheus-15142: go_version 1.23.8, install = `go test -c ./tsdb`, test_cmd = `go test -v ./tsdb -run "^TestHead"`. Verified: curl https://raw.githubusercontent.com/SWE-bench/SWE-bench/main/swebench/harness/constants/go.py (SPECS_PROMETHEUS key "15142").
- REPO STATE VERIFIED. PR 15142 base sha = 032ca9ef96ce0dd236c75bcdea2a8e9f7a74c6e8 (merged 2024-10-14). go.mod at that commit: `module github.com/prometheus/prometheus`, `go 1.22.0`, `toolchain go1.23.0`. 196 require lines, go.sum has 1010 lines. NO vendor/ directory exists in the tree. Verified via GitHub API + raw.githubusercontent.com at that sha.
- THE #1 TRAP: bare `go mod download` IS NOT ENOUGH — you must use `go mod download all`. Go 1.18 release notes, verbatim: "If the main module's go.mod file specifies go 1.17 or higher, go mod download without arguments now downloads source code for only the modules explicitly required in the main module's go.mod file. ... To also download source code for transitive dependencies, use go mod download all." prometheus declares `go 1.22.0`, so it is in the affected regime. (Caveat in the same note: for a *tidied* go1.17+ module the explicit require set already covers build+test of the main module — but `all` is a strict superset and costs only disk. Use `all`.) Source: https://go.dev/doc/go1.18
- GOTOOLCHAIN=local IS SAFE HERE AND IS THE RIGHT SETTING. go.dev/doc/toolchain, verbatim: "When GOTOOLCHAIN is set to local, the go command always runs the bundled Go toolchain." The toolchain-selection algorithm only ever UPGRADES: "If the go.work or go.mod file has a toolchain <tname> line and <tname> is newer than the default Go toolchain, then the go command runs <tname> instead." With Go 1.23.8 installed, `toolchain go1.23.0` is older, so even GOTOOLCHAIN=auto would not switch — but auto still consults/downloads in other cases, so pin it to local.
- THE SHIPPED DEFAULT IS GOTOOLCHAIN=auto AND IT WILL TRY TO HIT THE NETWORK. /usr/local/go/go.env in every official tarball contains exactly: `GOPROXY=https://proxy.golang.org,direct`, `GOSUMDB=sum.golang.org`, `GOTOOLCHAIN=auto`. Verified: curl https://raw.githubusercontent.com/golang/go/go1.23.0/go.env . Toolchains are fetched as modules `golang.org/toolchain@v0.0.1-go<VER>.<GOOS>-<GOARCH>` via GOPROXY, so GOPROXY=off alone would make this a confusing failure rather than a clean one — set GOTOOLCHAIN=local too.
- ENV PRECEDENCE (from the go.env header comment, verbatim): "This file contains the initial defaults for go command configuration. Values set by 'go env -w' and written to the user's go/env file override these. The environment overrides everything else." So: process env > $(go env GOENV) > $GOROOT/go.env.
- `go env -w` IS PER-USER AND WILL SILENTLY NOT APPLY IF THE AGENT RUNS UNDER A DIFFERENT HOME. cfg.EnvFile() in src/cmd/go/internal/cfg/cfg.go: honors $GOENV first (`GOENV=off` disables), else returns filepath.Join(os.UserConfigDir(), "go/env") = $HOME/.config/go/env. For a guest where SWE-ReX spawns shells, set a machine-wide GOENV file or export the vars, do not rely on `go env -w`.
- THE EXACT LOUD OFFLINE FAILURE STRING: `module lookup disabled by GOPROXY=off`. Verified in source: src/cmd/go/internal/modfetch/repo.go:267 — `errProxyOff = notExistErrorf("module lookup disabled by GOPROXY=off")`. The other loud one is `missing go.sum entry`. Both are non-zero-exit, not warnings.
- TOOLCHAIN-TOO-OLD ERROR FORMAT (matters if you use Ubuntu's apt Go): src/cmd/go/internal/gover/toolchain.go:94 — `fmt.Sprintf("%v requires go >= %v (running go %v%v)", ...)` with `explain = "; GOTOOLCHAIN=" + Startup.GOTOOLCHAIN`. i.e. `module X@v1.2.3 requires go >= 1.23.0 (running go 1.22.2; GOTOOLCHAIN=local)`.
- UBUNTU 24.04 APT GO IS 1.22, WHICH IS TOO OLD. Verified on this host: `apt-cache policy golang-go` -> Candidate 2:1.22~2build1. prometheus's own `go 1.22.0` line would be satisfied, but any dependency module declaring `go 1.23.x` fails with the TooNewError above, and GOTOOLCHAIN=local means it cannot self-heal. Use the official tarball: go1.23.8.linux-amd64.tar.gz, sha256 45b87381172a58d62c977f27c4683c8681ef36580abecd14fd124d24ca306d3f, size 73666093 (verified via https://go.dev/dl/?mode=json&include=all).
- GOCACHE — WHAT AND WHERE. `go help cache`, verbatim: "The go command caches build outputs for reuse in future builds. The default location for cache data is a subdirectory named go-build in the standard user cache directory for the current operating system." (= $XDG_CACHE_HOME/go-build, else $HOME/.cache/go-build). It caches compiled package objects, cgo-generated files, vet fact files, link outputs, successful *test results*, and fuzz corpora. GOCACHE must be an ABSOLUTE path (src/cmd/go/internal/cache/default.go sets `defaultDirErr = fmt.Errorf("GOCACHE is not an absolute path")` otherwise), and GOCACHE=off is fatal: `base.Fatalf("build cache is disabled by GOCACHE=off, but required as of Go 1.12")`. You cannot simply turn the build cache off to force a cold build.
- COLD vs WARM IS MUCH BIGGER THAN IT LOOKS, BECAUSE THE STDLIB IS NO LONGER PREBUILT. Go 1.20 release notes, verbatim: "The directory $GOROOT/pkg no longer stores pre-compiled package archives for the standard library: go install no longer writes them, the go build no longer checks for them, and the Go distribution no longer ships them. Instead, packages in the standard library are built as needed and cached in the build cache, just like packages outside GOROOT." So a genuinely cold GOCACHE for `go test -c ./tsdb` = compile the entire touched stdlib + ~all of prometheus's 196-module dependency closure + prometheus's own packages. Under TCG that is a very long trace. A warm cache reduces the same command to cache lookups plus a link.
- TEST RESULT CACHING WILL MAKE YOUR TRACED RUN DO NOTHING. From src/cmd/go/internal/test/test.go help text: "The rule for a match in the cache is that the run involves the same test binary and the flags on the command line come entirely from a restricted set of 'cacheable' test flags", listed as "-benchtime, -cpu, -list, -parallel, -run, -short, -timeout, -failfast, -fullpath and -v." The SWE-bench test_cmd `go test -v ./tsdb -run "^TestHead"` uses ONLY cacheable flags, so on a warm cache with unchanged sources it prints "(cached)" instead of the elapsed time and executes zero tests. "The idiomatic way to disable test caching explicitly is to use -count=1."
- TELEMETRY DOES NOT PHONE HOME BY DEFAULT, BUT YOU CAN STILL KILL IT. go.dev/doc/telemetry: default mode is `local` — "telemetry data is collected and stored on the local computer, but never uploaded to remote servers." Uploading is opt-in via `go telemetry on` (Go 1.23+). Data lives in [os.UserConfigDir()]/go/telemetry. "To completely disable telemetry, including local collection, run: go telemetry off". Read-only reporting vars: `go env GOTELEMETRY`, `go env GOTELEMETRYDIR`. Worth turning off purely to remove counter-file writes from the trace.
- THE MODULE CACHE DOWNLOAD DIR *IS* A VALID PROXY, which gives you a second offline mechanism if GOPROXY=off proves too blunt: $GOMODCACHE/cache/download has the same layout as the proxy URL space, so `GOPROXY=file://$GOMODCACHE/cache/download` serves it offline. Confirmed by go.dev/ref/mod guidance on building a static proxy (`export GOPROXY=direct; go mod download ...; serve files from $GOMODCACHE/cache/download`). Note the module cache is created read-only by default; `-modcacherw` (GOFLAGS=-modcacherw) makes it writable, which you only need if you plan to `rm -r` it.
- KNOWN OFFLINE FALSE-ALARM — DO NOT GATE ON `go mod tidy` OR `go list -m all`. golang/go#42723: `go mod tidy` and most commands do not download `.info` files for canonical versions, so offline `go list -m all` fails with "module lookup disabled by GOPROXY=off" even when the build itself is fully satisfiable. Issue is still open (NeedsDecision, opened 2020-11-19). Populate .info files during the build pass by running `go list -m all` while online, and gate on `go build`/`go list -deps -test`, not on tidy.
- VENDORING IS VIABLE HERE AND WON'T DIRTY THE PATCH, BUT IT AUTO-ACTIVATES SILENTLY. prometheus's .gitignore at the base commit contains `/vendor` (verified), so a vendor tree will not appear in `git status`/`git diff` and will not corrupt SWE-bench patch extraction. But go.dev/ref/mod: "If the vendor directory is present in the main module's root directory, it will be used automatically if the go version in the main module's go.mod file is 1.14 or higher." prometheus says go 1.22.0, so merely creating vendor/ flips every subsequent build to -mod=vendor, where "the go command will not use the network or module cache" — the strongest offline guarantee, but a different (and less benchmark-faithful) I/O profile than the module cache the real SWE-bench harness uses. Also `go mod vendor` "constructs a directory ... containing copies of all packages needed to build and test packages in the main module. Packages that are only imported by tests of packages outside the main module are not included" — fine for `go test ./tsdb`, fatal for `go test all`.
- DO NOT SET GOFLAGS=-mod=mod. -mod=mod is documented as "Ignore the vendor directory and automatically update go.mod" — offline that update attempt fails anyway, and when it succeeds it rewrites go.mod/go.sum, which lands in `git diff` and corrupts the SWE-bench patch. The default is -mod=readonly ("report an error if go.mod needs to be updated"), which is exactly the loud-failure behavior you want. Set it explicitly so a stray vendor/ dir cannot silently change the mode.
- `go mod verify` PROVES INTEGRITY, NOT COMPLETENESS. Verbatim: "Verify checks that the dependencies of the current module, which are stored in a local downloaded source cache, have not been modified since being downloaded. If all the modules are unmodified, verify prints 'all modules verified.'" It says nothing about a module that was never downloaded. It is a corruption detector (useful after copying the cache into the VM image), not your completeness gate.
- GOMODCACHE/GOCACHE DEFAULT INTO $HOME, WHICH IS A REAL RISK FOR A LOCAL SWE-ReX DEPLOYMENT. `go help environment`: GOMODCACHE = "The directory where the go command will store downloaded modules" (default $GOPATH/pkg/mod = $HOME/go/pkg/mod); GOCACHE = "The directory where the go command will store cached information for reuse in future builds" (default $HOME/.cache/go-build). If the agent process runs as a different user or with a rewritten HOME, both caches miss and you get either an offline hard failure or a silently ice-cold build. Pin both to absolute, world-readable paths.
- GONOSUMDB/GOPRIVATE/GONOPROXY are one documented group: `go help environment` describes GOPRIVATE, GONOPROXY, GONOSUMDB together as "Comma-separated list of glob patterns (in the syntax of Go's path.Match) of module path prefixes that should always be fetched directly or that should not be compared against the checksum database." GOSUMDB = "The name of checksum database to use". With a complete go.sum the sumdb is never consulted, but set GOSUMDB=off + GOFLAGS as belt-and-braces. Note from go.dev/doc/toolchain: "toolchain downloads fail for lack of verification if GOSUMDB=off" — a bonus second lock on toolchain fetching.

### Commands
```bash
# ============ BUILD PASS (KVM, network UP) ============
# --- 1. Install the exact Go SWE-bench pins for this instance ---
cd /tmp && curl -fsSLO https://go.dev/dl/go1.23.8.linux-amd64.tar.gz
echo '45b87381172a58d62c977f27c4683c8681ef36580abecd14fd124d24ca306d3f  go1.23.8.linux-amd64.tar.gz' | sha256sum -c -
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go1.23.8.linux-amd64.tar.gz
/usr/local/go/bin/go version   # must print: go version go1.23.8 linux/amd64
# --- 2. Machine-wide Go config that survives any user/HOME the agent runs under ---
sudo mkdir -p /etc/go && printf 'GOTOOLCHAIN=local\nGOFLAGS=-mod=readonly -buildvcs=false\nGOPATH=/opt/go\nGOMODCACHE=/opt/go/pkg/mod\nGOCACHE=/opt/gocache\nGOSUMDB=off\nGONOSUMDB=*\nGOPRIVATE=*\n' | sudo tee /etc/go/env
printf 'export GOROOT=/usr/local/go\nexport GOENV=/etc/go/env\nexport PATH=/usr/local/go/bin:$PATH\nexport GOPATH=/opt/go\nexport GOMODCACHE=/opt/go/pkg/mod\nexport GOCACHE=/opt/gocache\nexport GOTOOLCHAIN=local\n' | sudo tee /etc/profile.d/go.sh
sudo sed -i 's/^GOTOOLCHAIN=auto$/GOTOOLCHAIN=local/' /usr/local/go/go.env
grep -n . /usr/local/go/go.env   # confirm GOTOOLCHAIN=local, note GOPROXY/GOSUMDB defaults still present
# --- 3. Checkout at the exact SWE-bench base commit ---
sudo mkdir -p /opt/prometheus /opt/go /opt/gocache && sudo chown -R "$USER:$USER" /opt/prometheus /opt/go /opt/gocache
git clone https://github.com/prometheus/prometheus /opt/prometheus
git -C /opt/prometheus checkout 032ca9ef96ce0dd236c75bcdea2a8e9f7a74c6e8
git config --global --add safe.directory /opt/prometheus
# --- 4. Populate the module cache (network UP; GOPROXY left at its default) ---
export GOROOT=/usr/local/go GOENV=/etc/go/env PATH=/usr/local/go/bin:$PATH
export GOPATH=/opt/go GOMODCACHE=/opt/go/pkg/mod GOCACHE=/opt/gocache
export GOTOOLCHAIN=local GOFLAGS=-mod=readonly
cd /opt/prometheus && go env GOVERSION GOMODCACHE GOCACHE GOTOOLCHAIN GOPROXY GOFLAGS
cd /opt/prometheus && go mod download all
cd /opt/prometheus && go mod download
cd /opt/prometheus && go mod verify
cd /opt/prometheus && go list -m all > /dev/null
cd /opt/prometheus && go list -deps -test ./... > /dev/null
cd /opt/prometheus && go build ./...
cd /opt/prometheus && go vet ./...
cd /opt/prometheus && go test -c -o /dev/null ./tsdb
du -sh /opt/go/pkg/mod /opt/gocache
# ============ PROOF: THE OFFLINE GATE (still in the build VM) ============
# Hard proof - new empty network namespace, unprivileged, loopback only.
# Exits non-zero and names the missing module if the cache is incomplete.
cd /opt/prometheus && unshare -rn -- bash -c 'ip link set lo up; export GOROOT=/usr/local/go GOENV=/etc/go/env PATH=/usr/local/go/bin:$PATH GOPATH=/opt/go GOMODCACHE=/opt/go/pkg/mod GOCACHE=/opt/gocache GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOFLAGS=-mod=readonly; set -x; go list -deps -test ./... >/dev/null && go build ./... && go test -c -o /dev/null ./tsdb && go test -count=1 -run "^TestHead" ./tsdb'
echo "OFFLINE GATE EXIT=$?  # must be 0"
# Second, colder proof: same gate against a COMPLETELY EMPTY build cache.
# This is the one that tells you what a cold traced run will actually cost.
rm -rf /opt/gocache-cold && mkdir -p /opt/gocache-cold
cd /opt/prometheus && unshare -rn -- bash -c 'ip link set lo up; export GOROOT=/usr/local/go GOENV=/etc/go/env PATH=/usr/local/go/bin:$PATH GOPATH=/opt/go GOMODCACHE=/opt/go/pkg/mod GOCACHE=/opt/gocache-cold GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOFLAGS=-mod=readonly; time go test -c -o /dev/null ./tsdb'
# ============ TRACED PASS (TCG, network DOWN) ============
# Export exactly this before launching SWE-agent / SWE-ReX so the spawned shells inherit it.
export GOROOT=/usr/local/go
export GOENV=/etc/go/env
export PATH=/usr/local/go/bin:$PATH
export GOPATH=/opt/go
export GOMODCACHE=/opt/go/pkg/mod
export GOCACHE=/opt/gocache
export GOTOOLCHAIN=local
export GOPROXY=off
export GOSUMDB=off
export GONOSUMDB='*'
export GOPRIVATE='*'
export GOFLAGS='-mod=readonly -buildvcs=false'
export GOMAXPROCS=1
export GOTELEMETRY=off
go telemetry off
# Choose ONE cache policy for the traced run, deliberately:
# (A) WARM  - faithful to the SWE-bench harness, which pre-warms via its `install` step. Keep GOCACHE=/opt/gocache as-is.
# (B) COLD  - representative of a real first build, far longer under TCG. Use a fresh dir:
#     export GOCACHE=/opt/gocache-cold-run && rm -rf /opt/gocache-cold-run && mkdir -p /opt/gocache-cold-run
# (C) COLD WORK, WARM CACHE PRESENT - forces recompilation of everything incl. stdlib:
#     export GOFLAGS='-a -mod=readonly -buildvcs=false'
# ALWAYS kill test-result caching, or the traced test does literally nothing:
go clean -testcache
cd /opt/prometheus && go test -count=1 -v ./tsdb -run '^TestHead'
# Sanity: this MUST print an error, proving the guest is really offline.
cd /opt/prometheus && go install golang.org/x/tools/cmd/goimports@latest 2>&1 | head -3
```

### Risks
- `go mod download` without `all` silently under-populates on this repo (go.mod says `go 1.22.0`, i.e. the >=1.17 regime). You will not notice during the build pass because the build pass has network — the go command just fetches the missing module on demand. Detect: the `unshare -rn` gate. Symptom if missed: mid-trace failure with `module lookup disabled by GOPROXY=off`.
- Test-result caching makes the traced run a no-op. `go test -v ./tsdb -run "^TestHead"` uses only cacheable flags, so with a warm GOCACHE and unmodified sources it prints `(cached)` and runs zero tests — you would capture a trace of `go test` deciding not to work. Detect: grep the traced stdout for the literal string `(cached)`; a real run prints an elapsed time (`ok  ... 3.412s`). Mitigate: `go clean -testcache` plus `-count=1`.
- GOMODCACHE/GOCACHE silently fall back to $HOME. If SWE-ReX's local deployment spawns the agent shell with a different HOME or as a different uid, `go env GOMODCACHE` becomes that user's ~/go/pkg/mod and everything you pre-populated is invisible. This presents as a total offline failure OR, worse, as a fully cold build you did not intend. Detect: run `go env GOMODCACHE GOCACHE GOTOOLCHAIN GOPROXY` *from inside the agent's own shell*, not from your setup shell, and diff it against the values above.
- GOTOOLCHAIN reverts to `auto` on any Go reinstall, because it is baked into /usr/local/go/go.env in every official tarball. If it is `auto` and anything in the dependency graph wants a newer Go, the guest tries to download a `golang.org/toolchain` module and dies with a network error rather than a clear version error. Detect: `go env GOTOOLCHAIN` must print `local` in the traced guest; assert it in the boot script.
- `go mod tidy`, `go get`, and `go list -m all` can fail offline even when the build is perfectly satisfiable, because .info files for canonical versions are not populated by download/tidy (golang/go#42723, still open). Do not use them as your completeness gate — you will chase a phantom. Conversely, if SWE-agent itself decides to run `go mod tidy` mid-episode, it will fail; budget for that in the trace or seed the .info files with the online `go list -m all` shown above.
- GOFLAGS=-mod=mod would let the go command rewrite go.mod/go.sum, which lands in `git diff` and corrupts SWE-bench patch extraction. It is also useless offline. Detect: `git -C /opt/prometheus status --porcelain go.mod go.sum` must be empty after the run.
- A stray vendor/ directory silently switches every subsequent build to -mod=vendor (auto-enabled at go>=1.14), and prometheus's .gitignore contains `/vendor` so it will NOT show up in `git status` — you can be in vendor mode and never see it. This changes the file-I/O profile of the traced workload. Detect: `go env GOFLAGS` plus `test ! -d /opt/prometheus/vendor`; the explicit `-mod=readonly` in GOFLAGS above also forces an error rather than a silent mode change.
- git 'dubious ownership' will break `go build` if the repo uid differs from the agent uid, because -buildvcs=auto shells out to git. It surfaces as `error obtaining VCS status: exit status 128`, which reads like a network problem but is not. Mitigated above by both `git config --global --add safe.directory` and `-buildvcs=false`.
- CGO_ENABLED is unset in my recipe, so it defaults to 1 whenever gcc is present in the guest — meaning gcc subprocesses appear in your trace and net/os-user use the cgo resolver. That may or may not be what you want to measure. Setting CGO_ENABLED=0 removes the gcc invocations and makes the build pure Go, but produces different machine code and invalidates every cgo-flavored GOCACHE entry (forcing a partial cold rebuild). Decide once, set it in /etc/go/env, and keep it identical between the build pass and the traced pass — a mismatch here is an invisible cache-miss generator.
- GOMAXPROCS=1 and single-vCPU pinning interact with build parallelism. The go command's own `-p` defaults to GOMAXPROCS, so setting GOMAXPROCS=1 also serializes compilation. If you want the build parallel but the test serial (or vice versa) you must set `-p` explicitly. Detect: wall-clock and process-count differences between build pass and traced pass that you cannot otherwise explain.
- I could not execute any of this — there is no Go toolchain on this host (`which go` -> exit 127, apt golang-go not installed). Every Go semantic above is verified against official docs or the go1.23.0 source tree, and every repo/instance fact is verified against the live GitHub API, but the command sequences themselves are unrun. Run the two `unshare -rn` gates before you commit to a VM snapshot; that is the only step that actually proves the whole thing.
- The build cache self-prunes: `go help cache` says "The go command periodically deletes cached data that has not been used recently." If your VM image sits for a long time, or the guest clock jumps forward when you re-boot it under TCG, a warm GOCACHE can be partially evicted between the build pass and the traced pass — turning an intended warm run into a half-cold one. I did not verify the exact trim window (commonly cited as 5 days) — treat that number as unconfirmed. Detect: compare `du -sh $GOCACHE` and the file count immediately before and after the TCG boot.

## Building the Ubuntu 24.04 QEMU guest image and tuning it for deterministic, low-noise SWE-agent tracing (vCPU-1 isolation, serial marker channel, process-tree pinning)

**Confidence:** high

### Findings
- IMAGE CHOICE — cloud image + cloud-init NoCloud seed ISO is the right tool here. virt-install and debootstrap are both non-starters on this host: I checked and `virt-install`, `virt-customize`, `guestfish`, `debootstrap` are all MISSING and `sudo -n true` fails (password required), so anything needing libvirt or root-only loop mounts costs an install + password. The cloud image path needs zero root. Verified: `~/qemu-custom/bin/qemu-img` exists (QEMU 9.2.4) even though there is no system-wide qemu-img in PATH.
- CLOUD IMAGE URL VERIFIED by download: https://cloud-images.ubuntu.com/noble/20260801/noble-server-cloudimg-amd64.img — 624239616 bytes, sha256 0533b0655c32e68b31d792ecd6ccfca95abdbc536c4446874fe0513bd4140ffe, qcow2, virtual size 3.5 GiB. The `/noble/current/` alias served the identical hash on 2026-08-06 but it MOVES (dated builds present: 20260323, 20260518, 20260615, 20260705, 20260725, 20260801). Pin the dated URL for reproducibility. SHA256SUMS lines are in `hash *name` form so `sha256sum -c` works directly.
- PARTITION LAYOUT VERIFIED (`fdisk -l` on the converted raw): GPT, p1 = root ext4 at sector 2099200..7339998 (2.5G, LAST partition on the disk), p14 = BIOS boot 4M, p15 = EFI 106M, p16 = /boot ext4 913M. Because root is physically last, `qemu-img resize` + cloud-init growpart/resizefs grows it with no manual partition surgery. /etc/fstab (read out of the real image with debugfs) is exactly: `LABEL=cloudimg-rootfs / ext4 discard,commit=30,errors=remount-ro 0 1` / `LABEL=BOOT /boot ext4 defaults 0 2` / `LABEL=UEFI /boot/efi vfat umask=0077 0 1` — NO swap entry, and there is no /swap.img in the image. Swap is already absent by default.
- GROWPART IS ON BY DEFAULT: /etc/cloud/cloud.cfg in the image lists `growpart` and `resizefs` in cloud_init_modules; cloud-init docs give defaults `growpart: {mode: auto, devices: ['/'], ignore_growroot_disabled: false}`. Default user is `ubuntu`, `disable_root: true`. Datasource list (/etc/cloud/cloud.cfg.d/90_dpkg.cfg) starts with NoCloud. cloud-init version in the 20260801 image is 26.1-0ubuntu1~24.04.1 — note `chpasswd: list:` is deprecated in this version, use `chpasswd: users:`.
- THE BIG GRUB GOTCHA (verified by reading both files out of the real image): /etc/default/grub EXISTS and says `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"`, but /etc/default/grub.d/50-cloudimg-settings.cfg then sets `GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0"`, GRUB_TIMEOUT=0, GRUB_RECORDFAIL_TIMEOUT=0, GRUB_TERMINAL=console. I confirmed the ordering in /usr/sbin/grub-mkconfig from the image: line 161 sources ${sysconfdir}/default/grub, line 164 then loops `for x in ${sysconfdir}/default/grub.d/*.cfg ; do . "$x" ; done`. So grub.d WINS and any edit you make to /etc/default/grub's GRUB_CMDLINE_LINUX_DEFAULT is silently discarded. Fix: drop your own /etc/default/grub.d/99-tracing.cfg (sorts after 50-) — or use GRUB_CMDLINE_LINUX, which the cloudimg file does not touch.
- SERIAL CONSOLE IS ALREADY WIRED: the stock cmdline is `console=tty1 console=ttyS0`, with ttyS0 LAST, so /dev/console == ttyS0. /usr/lib/systemd/system-generators/systemd-getty-generator and /usr/lib/systemd/system/serial-getty@.service are both present in the image, and /etc/systemd/system/getty.target.wants contains ONLY getty@tty1.service — i.e. the serial getty is instantiated automatically from console= on the cmdline, you do not need to enable it. You must preserve `console=tty1 console=ttyS0` when you write your 99-tracing.cfg.
- GUEST KERNEL SUPPORTS THE ISOLATION KNOBS — verified by extracting /boot from the image and reading config-6.8.0-136-generic: CONFIG_NO_HZ_FULL=y, CONFIG_RCU_NOCB_CPU=y, CONFIG_CPUSETS=y, CONFIG_HZ_1000=y, CONFIG_TRANSPARENT_HUGEPAGE=y with CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y (so THP default is `madvise`, not `always`; still set it to never), CONFIG_PREEMPT_DYNAMIC=y. Kernel shipped is linux-image-6.8.0-136-generic (via linux-image-virtual).
- KERNEL PARAM SEMANTICS (quoted from Documentation/admin-guide/kernel-parameters.txt v6.8, downloaded and grepped): `isolcpus=` is marked "[Deprecated - use cpusets instead]" but still functional; format is `[flag-list,]<cpu-list>` with flags nohz / domain / managed_irq. `managed_irq` = "Isolate from being targeted by managed interrupts which have an interrupt mask containing isolated CPUs. The affinity of managed interrupts is handled by the kernel and cannot be changed via the /proc/irq/* interfaces." — this is the ONLY way to keep virtio MSI-X queue IRQs off CPU 1. The `nohz` flag doc also warns: "by default the global workqueue runs on all CPUs, so to protect individual CPUs the 'cpumask' file has to be configured manually after bootup" (/sys/devices/virtual/workqueue/cpumask).
- `nohz_full=1` IS SAFE WITH CPU 0 AS BOOT CPU — kernel doc: "The boot CPU will be forced outside the range to maintain the timekeeping. Any CPUs in this list will have their RCU callbacks offloaded, just as if they had also been called out in the rcu_nocbs= boot parameter." So nohz_full=1 already implies rcu_nocbs=1; passing both is harmless and self-documenting. `norandmaps` is documented as "Don't use address space randomization. Equivalent to echo 0 > /proc/sys/kernel/randomize_va_space". `irqaffinity=` "Set the default irq affinity mask". `transparent_hugepage=[always|madvise|never]`. `nowatchdog` ("Disable both lockup detectors") and `audit=0` also exist and are worth adding.
- IRQ/WORKQUEUE SYSFS INTERFACES VERIFIED ON A LIVE 24.04 BOX: /proc/irq/default_smp_affinity takes a HEX MASK (reads `ffffffff`), NOT a cpu list — for a 4-vCPU guest with CPU1 isolated you write `d`. Per-IRQ you can use the list form: /proc/irq/<N>/smp_affinity_list exists and reads e.g. `2,18`. /sys/devices/virtual/workqueue/cpumask exists and is a hex mask (`ffffffff`). Per-workqueue masks live at /sys/bus/workqueue/devices/*/cpumask (writeback, blkcg_punt_bio, nvme-* etc. on this host). Sysctls kernel.timer_migration, kernel.watchdog, kernel.nmi_watchdog, vm.stat_interval, kernel.randomize_va_space, kernel.numa_balancing all exist.
- irqbalance IS NOT INSTALLED in the noble cloud image (checked /usr/sbin/irqbalance — ABSENT), so there is nothing fighting your /proc/irq writes out of the box. But systemd-timesyncd, snapd, multipathd ARE present. qemu-guest-agent is NOT installed (no /usr/sbin/qemu-ga) — install it during the build pass if you want an out-of-band host->guest channel that survives the no-network traced pass.
- EXACT LIST OF ENABLED NOISE (read from the image's /etc/systemd/system/*.wants): multi-user.target.wants = systemd-networkd, e2scrub_reap, remote-fs.target, dmesg, rsyslog, cron, pollinate, open-vm-tools, ua-reboot-cmds, ubuntu-advantage, networkd-dispatcher, console-setup, lxd-installer.socket, secureboot-db, ufw, sysstat, snapd.apparmor, snapd.autoimport, snapd.core-fixup, snapd.recovery-chooser-trigger, snapd.seeded, snapd, unattended-upgrades, ModemManager, grub-common, grub-initrd-fallback, apport. timers.target.wants = logrotate, dpkg-db-backup, e2scrub_all, fstrim, motd-news, fwupd-refresh, apt-daily-upgrade, apt-daily, ua-timer, update-notifier-download, update-notifier-motd, man-db, snapd.snap-repair, apport-autoreport. sockets.target.wants = systemd-networkd.socket, uuidd, iscsid, snapd, ssh, multipathd, apport-forward, dm-event. network-online.target.wants = systemd-networkd-wait-online.service (this one will stall a no-NIC boot for up to 120s — mask it for the traced pass).
- AFFINITY INHERITANCE — man 2 sched_setaffinity: "A child created via fork(2) inherits its parent's CPU affinity mask" and "The affinity mask is preserved across an execve(2)." I verified this empirically end-to-end on this host: `taskset -c 3 python3 -c "subprocess.run(['bash','-c','exec sh -c ...'])"` → the grandchild reports `Cpus_allowed_list: 3` and `nproc` returns 1. So taskset DOES reach Python→Go subprocess trees. The same man page also says "The system may further restrict the set of CPUs on which the thread runs if the 'cpuset' mechanism ... is being used" — i.e. cpuset is a hard ceiling that a process cannot raise with its own sched_setaffinity, which taskset alone is not.
- VERIFIED FAILURE MODE: `systemd-run --user --scope -p AllowedCPUs=1 ...` SILENTLY DOES NOTHING on Ubuntu 24.04. I ran it on this host and the payload still reported `Cpus_allowed_list: 0-31` and `nproc` 32. Root cause confirmed two ways: /sys/fs/cgroup/cgroup.subtree_control is `cpu memory pids` (no cpuset), and /usr/lib/systemd/system/user@.service has `Delegate=pids memory cpu` — cpuset is NOT delegated to user sessions. The same unit file in the guest image has the identical `Delegate=pids memory cpu`. You must use a SYSTEM-level unit/scope (root) for AllowedCPUs=, not `--user`. systemd 255 on both host and guest; systemd.resource-control(5) also notes AllowedCPUs "is supported only with the unified control group hierarchy", that it "doesn't guarantee that all of the CPUs will be used ... as it may be limited by parent units", and that the result is reported as EffectiveCPUs=.
- SEED-ISO TOOLING IS MISSING ON THIS HOST: cloud-localds, genisoimage, xorriso, mkisofs, mtools (mcopy/mmd) are ALL absent and sudo needs a password. Workaround I built and TESTED: `pip install pycdlib` + a 12-line script produces a valid seed — `file seed.iso` reports `ISO 9660 CD-ROM filesystem data 'CIDATA'`, and reading it back with pycdlib shows volume identifier CIDATA with both Rock Ridge and Joliet names `user-data` and `meta-data`. cloud-init's NoCloud doc requires exactly this: "A labeled vfat or iso9660 filesystem may be used. The filesystem volume must be labelled CIDATA". Script saved at /tmp/claude-1000/-home-rbera-work-bpeval-champsim-infra/46ab38b4-1504-46de-899d-d060c5dfc5f8/scratchpad/make_seed.py
- QEMU DUAL-SERIAL MARKER CHANNEL TESTED against ~/qemu-custom/bin/qemu-system-x86_64 9.2.4: `-chardev file,id=ser0,path=/tmp/console.log -device isa-serial,chardev=ser0,index=0 -chardev socket,id=mk,path=/tmp/mk.sock,server=on,wait=off -device isa-serial,chardev=mk,index=1` starts cleanly and creates both /tmp/console.log and the listening unix socket /tmp/mk.sock (QEMU unlinks the socket on exit). index=0 → guest /dev/ttyS0, index=1 → guest /dev/ttyS1. HARD LIMIT FOUND THE HARD WAY: QEMU rejects long paths — `UNIX socket path '<...>' is too long / Path must be less than 108 bytes`. Keep the socket under /tmp or /run. `nc -U /tmp/mk.sock` is available on this host for the watcher (`nc -h` lists `-U  Use UNIX domain socket`).
- cloud-init NoCloud alternative if you ever want to skip the ISO entirely: the official doc documents SMBIOS seeding, `-smbios type=1,serial=ds=nocloud;s=http://10.10.0.1:8000/` (host-side python -m http.server reachable at 10.0.2.2 from QEMU user-net). Useful only during the networked build pass; the CIDATA ISO is the safer default and is what I tested.

### Commands
```bash
mkdir -p ~/vm/trace && cd ~/vm/trace
cd ~/vm/trace && curl -fSL -O https://cloud-images.ubuntu.com/noble/20260801/noble-server-cloudimg-amd64.img && curl -fSL -O https://cloud-images.ubuntu.com/noble/20260801/SHA256SUMS && grep ' \*noble-server-cloudimg-amd64.img$' SHA256SUMS | sha256sum -c -
cd ~/vm/trace && cp noble-server-cloudimg-amd64.img disk.qcow2 && ~/qemu-custom/bin/qemu-img resize disk.qcow2 100G && ~/qemu-custom/bin/qemu-img info disk.qcow2
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
cd ~/vm/trace && cat > meta-data <<'EOF'
instance-id: iid-tracevm-0001
local-hostname: tracevm
EOF
cd ~/vm/trace && { cat <<'EOF'
#cloud-config
hostname: tracevm
manage_etc_hosts: true

users:
  - name: ubuntu
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    ssh_authorized_keys:
      - SSH_KEY_PLACEHOLDER

ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: ubuntu
      password: tracevm
      type: text

growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true

package_update: true
packages:
  - build-essential
  - git
  - python3-venv
  - python3-pip
  - pipx
  - jq
  - unzip
  - qemu-guest-agent

write_files:
  - path: /etc/default/grub.d/99-tracing.cfg
    permissions: '0644'
    content: |
      # Sorts AFTER 50-cloudimg-settings.cfg, which is what actually sets
      # GRUB_CMDLINE_LINUX_DEFAULT in this image. Editing /etc/default/grub
      # has NO effect. console=ttyS0 must stay LAST so /dev/console == ttyS0.
      GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0 isolcpus=managed_irq,domain,1 nohz_full=1 rcu_nocbs=1 irqaffinity=0,2,3 norandmaps transparent_hugepage=never nowatchdog audit=0"
      GRUB_TIMEOUT=0
      GRUB_RECORDFAIL_TIMEOUT=0
      GRUB_TERMINAL=console

  - path: /etc/sysctl.d/99-tracing.conf
    permissions: '0644'
    content: |
      kernel.randomize_va_space = 0
      kernel.nmi_watchdog = 0
      kernel.watchdog = 0
      kernel.timer_migration = 0
      kernel.numa_balancing = 0
      vm.stat_interval = 300
      vm.swappiness = 0

  - path: /usr/local/sbin/trace-quiesce.sh
    permissions: '0755'
    content: |
      #!/bin/sh
      # Housekeeping CPUs 0,2,3 -> hex mask 0xd. Isolated CPU is 1.
      set -u
      HKMASK=d
      HKLIST=0,2,3
      echo never > /sys/kernel/mm/transparent_hugepage/enabled
      echo never > /sys/kernel/mm/transparent_hugepage/defrag
      echo 0     > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
      swapoff -a 2>/dev/null || true
      # default mask for IRQs created later (HEX, not a list)
      echo $HKMASK > /proc/irq/default_smp_affinity 2>/dev/null || true
      # existing IRQs; kernel-managed (virtio MSI-X) ones return EIO -> ignore,
      # they are handled by isolcpus=managed_irq on the cmdline instead
      for d in /proc/irq/[0-9]*; do
        echo $HKLIST > "$d/smp_affinity_list" 2>/dev/null || true
      done
      # global + per-wq unbound workqueue masks (required per isolcpus docs)
      echo $HKMASK > /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true
      for w in /sys/bus/workqueue/devices/*/cpumask; do
        echo $HKMASK > "$w" 2>/dev/null || true
      done
      # fstab mounts / with commit=30 -> periodic writeback jitter
      mount -o remount,commit=600 / 2>/dev/null || true
      exit 0

  - path: /etc/systemd/system/trace-quiesce.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Quiesce isolated vCPU for tracing
      DefaultDependencies=no
      After=sysinit.target
      Before=multi-user.target
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/sbin/trace-quiesce.sh
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/trace.slice
    permissions: '0644'
    content: |
      [Unit]
      Description=Isolated-vCPU slice for the traced agent
      [Slice]
      AllowedCPUs=1
      AllowedMemoryNodes=0

  - path: /etc/systemd/system/traced-agent.service
    permissions: '0644'
    content: |
      [Unit]
      Description=SWE-agent traced run pinned to vCPU 1
      After=multi-user.target
      [Service]
      Type=oneshot
      User=ubuntu
      Group=ubuntu
      Slice=trace.slice
      AllowedCPUs=1
      AllowedMemoryNodes=0
      CPUAffinity=1
      Environment=GOMAXPROCS=1
      Environment=GOFLAGS=-p=1
      Environment=MAKEFLAGS=-j1
      WorkingDirectory=/home/ubuntu
      ExecStartPre=/bin/sh -c 'stty -F /dev/ttyS1 raw speed 115200 >/dev/null'
      ExecStartPre=/bin/sh -c 'printf "TRACE_BEGIN\\n" > /dev/ttyS1'
      ExecStart=/home/ubuntu/run_agent.sh
      ExecStopPost=/bin/sh -c 'printf "TRACE_END\\n" > /dev/ttyS1'
      [Install]
      WantedBy=multi-user.target

  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    permissions: '0644'
    content: |
      network: {config: disabled}

runcmd:
  - [ update-grub ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, trace-quiesce.service ]
  - [ systemctl, mask, serial-getty@ttyS1.service ]
  - systemctl disable --now unattended-upgrades.service snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service snapd.autoimport.service snapd.core-fixup.service snapd.recovery-chooser-trigger.service ModemManager.service pollinate.service ubuntu-advantage.service ua-reboot-cmds.service open-vm-tools.service secureboot-db.service sysstat.service ufw.service cron.service rsyslog.service apport.service lxd-installer.socket multipathd.socket iscsid.socket dm-event.socket apport-forward.socket uuidd.socket networkd-dispatcher.service systemd-timesyncd.service || true
  - systemctl disable --now apt-daily.timer apt-daily-upgrade.timer motd-news.timer fwupd-refresh.timer update-notifier-download.timer update-notifier-motd.timer ua-timer.timer man-db.timer logrotate.timer dpkg-db-backup.timer e2scrub_all.timer fstrim.timer snapd.snap-repair.timer apport-autoreport.timer || true
  - systemctl mask snapd.service snapd.socket unattended-upgrades.service systemd-networkd-wait-online.service || true
  - [ sh, -c, 'sed -i "/\\bswap\\b/d" /etc/fstab' ]

power_state:
  mode: poweroff
  timeout: 600
  condition: true
EOF
} | sed "s|SSH_KEY_PLACEHOLDER|$(cat ~/.ssh/id_ed25519.pub)|" > user-data && head -20 user-data
python3 -m pip install --user pycdlib
cd ~/vm/trace && cat > make_seed.py <<'PY'
#!/usr/bin/env python3
"""Build a NoCloud CIDATA seed ISO without genisoimage/xorriso/mtools."""
import io, os, sys, pycdlib
out, files = sys.argv[1], sys.argv[2:]
iso = pycdlib.PyCdlib()
iso.new(interchange_level=3, joliet=3, rock_ridge='1.09', vol_ident='CIDATA')
for path in files:
    name = os.path.basename(path)
    data = open(path, 'rb').read()
    iso_name = '/' + name.upper().replace('-', '_').replace('.', '_') + '.;1'
    iso.add_fp(io.BytesIO(data), len(data), iso_name,
               rr_name=name, joliet_path='/' + name)
iso.write(out); iso.close()
print('wrote', out, os.path.getsize(out), 'bytes')
PY
python3 make_seed.py seed.iso user-data meta-data && file seed.iso
cd ~/vm/trace && sudo apt-get install -y cloud-image-utils && cloud-localds seed.iso user-data meta-data
cd ~/vm/trace && rm -f build-console.log && ~/qemu-custom/bin/qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 4,sockets=1,cores=4,threads=1 -m 16384 -nographic -nodefaults -serial mon:stdio -drive file=disk.qcow2,if=virtio,format=qcow2,cache=writeback -drive file=seed.iso,if=virtio,format=raw,readonly=on -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 -device virtio-rng-pci
cd ~/vm/trace && ~/qemu-custom/bin/qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 4,sockets=1,cores=4,threads=1 -m 16384 -nographic -nodefaults -serial mon:stdio -drive file=disk.qcow2,if=virtio,format=qcow2,cache=writeback -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 -device virtio-rng-pci
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@127.0.0.1 'cat /proc/cmdline; echo ---; cat /sys/devices/system/cpu/isolated; cat /sys/devices/system/cpu/nohz_full; echo ---; cat /proc/sys/kernel/randomize_va_space; cat /sys/kernel/mm/transparent_hugepage/enabled; swapon --show || echo "no swap"; echo ---; lsblk; df -h /'
ssh -p 2222 ubuntu@127.0.0.1 'dmesg | grep -iE "isolcpus|nohz|rcu_nocbs|Offload RCU|housekeeping"'
ssh -p 2222 ubuntu@127.0.0.1 'cat /proc/irq/default_smp_affinity; cat /sys/devices/virtual/workqueue/cpumask; for d in /proc/irq/[0-9]*; do printf "%s %s\n" "${d##*/}" "$(cat $d/smp_affinity_list)"; done | sort -n'
ssh -p 2222 ubuntu@127.0.0.1 'systemctl list-units --type=service --state=running --no-legend; systemctl list-timers --all --no-legend'
ssh -p 2222 ubuntu@127.0.0.1 'sudo systemctl mask systemd-networkd-wait-online.service systemd-networkd.service ssh.socket; sudo touch /etc/cloud/cloud-init.disabled; sudo systemctl daemon-reload; sudo poweroff'
cd ~/vm/trace && cp disk.qcow2 disk-traced.qcow2 && ~/qemu-custom/bin/qemu-img info disk-traced.qcow2
rm -f /tmp/mk.sock /tmp/trace-console.log && cd ~/vm/trace && ~/qemu-custom/bin/qemu-system-x86_64 -machine q35,accel=tcg -cpu max -smp 4,sockets=1,cores=4,threads=1 -m 16384 -display none -nodefaults -nic none -drive file=disk-traced.qcow2,if=virtio,format=qcow2,cache=unsafe -chardev file,id=ser0,path=/tmp/trace-console.log -device isa-serial,chardev=ser0,index=0 -chardev socket,id=mk,path=/tmp/mk.sock,server=on,wait=off -device isa-serial,chardev=mk,index=1 -device virtio-rng-pci -monitor unix:/tmp/mon.sock,server=on,wait=off
nc -U /tmp/mk.sock | stdbuf -oL tr -d '\r' | while IFS= read -r line; do printf '[%s] %s\n' "$(date +%s.%N)" "$line"; case "$line" in TRACE_BEGIN) echo ARM-TRACER ;; TRACE_END) echo STOP-TRACER ;; esac; done
tail -F /tmp/trace-console.log
printf 'TRACE_BEGIN\n' > /dev/ttyS1
sudo stty -F /dev/ttyS1 raw speed 115200 && sudo systemctl mask serial-getty@ttyS1.service
sudo systemctl start traced-agent.service
sudo systemd-run --scope --slice=trace.slice -p AllowedCPUs=1 -p AllowedMemoryNodes=0 runuser -u ubuntu -- /home/ubuntu/run_agent.sh
systemctl show -p AllowedCPUs -p EffectiveCPUs -p CPUAffinity traced-agent.service
cat /sys/fs/cgroup/trace.slice/cpuset.cpus.effective && cat /sys/fs/cgroup/trace.slice/traced-agent.service/cgroup.procs
for p in $(cat /sys/fs/cgroup/trace.slice/traced-agent.service/cgroup.procs); do printf '%s %s\n' "$p" "$(grep Cpus_allowed_list /proc/$p/status | awk '{print $2}')"; done
ps -eLo pid,tid,psr,comm --sort=psr | awk '$3==1'
awk 'NR==1{print} /LOC/ {print}' /proc/interrupts
```

### Risks
- `/noble/current/` is a moving pointer — if you build from it today and rebuild in a month you get a different kernel (6.8.0-136 today) and different package set, and your traces stop being comparable. Detection: record `uname -r` and the image sha256 in the run metadata; use the dated URL /noble/20260801/ (verified same hash 0533b065…) so the rebuild is byte-identical.
- Editing /etc/default/grub is the obvious move and it SILENTLY does nothing — 50-cloudimg-settings.cfg re-assigns GRUB_CMDLINE_LINUX_DEFAULT afterwards. You will boot, see a normal system, and only discover the isolation never applied when your trace is noisy. Detection: after every image change run `cat /proc/cmdline` and `cat /sys/devices/system/cpu/isolated` (must print `1`) and `cat /sys/devices/system/cpu/nohz_full` (must print `1`) — do NOT trust `grep isolcpus /boot/grub/grub.cfg` alone, and never trust that update-grub 'succeeded'.
- nohz_full only stops the tick when EXACTLY ONE task is runnable on that CPU. A SWE-agent Python process plus a `go build`/`go test` child on the same vCPU means >=2 runnable tasks and the 1000 Hz tick comes straight back — you get the isolation label without the benefit. Detection: sample `grep LOC /proc/interrupts` before and after a workload window and look at the CPU1 column delta; if it grows at ~1000/s the tick is live. Mitigation is workload shaping (serialize the agent's subprocesses, GOMAXPROCS=1, -p 1), not more boot flags.
- Writes to /proc/irq/<N>/smp_affinity for virtio MSI-X queue vectors fail with EIO because they are kernel-managed — a naive `for` loop without `|| true` aborts your quiesce script halfway and leaves THP/workqueues untuned. That is why the script above swallows errors and why `isolcpus=managed_irq,...` is on the cmdline. Detection: after boot, dump every /proc/irq/*/smp_affinity_list and assert none contains CPU 1.
- `systemd-run --user --scope -p AllowedCPUs=1` is silently ignored on Ubuntu 24.04 (I reproduced it: payload still saw all CPUs) because user@.service has `Delegate=pids memory cpu` with no cpuset. If you script the pinning as the ubuntu user you will believe it worked. Detection: always assert `cat /sys/fs/cgroup/<path>/cpuset.cpus.effective` == 1 and `grep Cpus_allowed_list /proc/<pid>/status` for the actual agent PID and at least one Go child, not just the launcher.
- taskset alone is escapable: affinity is inherited and preserved across execve (verified), but any child that calls sched_setaffinity itself, or any process started via D-Bus/systemd rather than forked from the agent, escapes. cgroup cpuset is the enforcing ceiling. Use BOTH (`CPUAffinity=1` + `AllowedCPUs=1`) as in the unit above, and treat the cgroup as the source of truth.
- The stock /etc/fstab mounts / with `commit=30`, so ext4 writes back journal metadata every 30 s — a periodic, workload-independent jitter source right in the middle of your capture window. Detection: it shows up as regular jbd2/ext4 kworker activity in the trace. Mitigate with `mount -o remount,commit=600 /` (in the quiesce script) and `cache=unsafe` on the traced-pass -drive.
- systemd-networkd-wait-online.service is enabled in the image (verified in /etc/systemd/system/network-online.target.wants). Boot the traced pass with `-nic none` and anything pulling network-online.target stalls for up to 120 s of pure emulated-boot noise. Detection: `systemd-analyze blame` on the traced boot. Mask it before the traced pass.
- Under TCG with `-cpu max` the guest sees a different CPUID than under KVM with `-cpu host`, so the kernel may pick DIFFERENT spectre/meltdown mitigations (retpoline vs IBRS vs none) between the build pass and the traced pass. For branch-predictor work this materially changes the branch mix in kernel code. Detection: `grep . /sys/devices/system/cpu/vulnerabilities/*` under both passes and diff; pin an explicit -cpu model (not `host` in one pass and `max` in the other) and record the mitigation set alongside the trace. Decide deliberately whether to add `mitigations=off` — do not let it differ by accident.
- ISA serial is one `outb` per byte; under TCG a long marker string costs real emulated instructions inside your capture window. Keep markers <= 16 bytes and write them once. Also QEMU unlinks /tmp/mk.sock on exit, so a watcher started before QEMU sees ENOENT — start `nc -U` after the socket appears, and note the hard <108-byte path limit I hit (`Path must be less than 108 bytes`).
- cloud-init modules are per-instance: if you resize the qcow2 AFTER the first boot, growpart will not re-run and the filesystem stays small while `lsblk` shows a big disk. Detection: `df -h /` vs `lsblk`. Fix by bumping instance-id in meta-data or `sudo cloud-init clean --logs` before the next boot. Conversely, once you `touch /etc/cloud/cloud-init.disabled` for the traced pass, none of your user-data will ever re-apply — do all image changes before that step.
- cloud-init in this image is 26.1, where `chpasswd: list:` is deprecated; a stale user-data using `list:` may warn now and hard-fail later. Detection: `sudo cloud-init schema --system` and `grep -i 'deprecat\|error' /var/log/cloud-init.log` on the build pass before you trust the image.
- With CPU 1 isolated out of 4 vCPUs, `nproc` inside the cpuset returns 1 and Go/make will serialize — that is intended for determinism, but it also means the traced pass takes ~4x longer in wall-clock on top of the TCG slowdown. Budget for it; verify GOMAXPROCS actually collapsed with `go env GOMAXPROCS` run inside the cgroup, not outside it.

## Building and testing prometheus/prometheus for SWE-bench Multilingual instance prometheus__prometheus-15142

**Confidence:** high

### Findings
- base_commit = 16bba78f1549cfd7909b61ebd7c55c822c86630b -- 'discovery: Improve Azure test coverage to 50% (#14586)', Sun Oct 13 13:54:51 2024 +0530. Verified via the HF datasets-server /filter endpoint (num_rows_total=1). IMPORTANT: the /search URL given in the task (query=15142) returns 0 rows; /filter with where="instance_id"='prometheus__prometheus-15142' works, as does /search with query=prometheus (9 rows).
- SWE-bench harness spec for this exact instance, from https://raw.githubusercontent.com/SWE-bench/SWE-bench/main/swebench/harness/constants/go.py (SPECS_PROMETHEUS['15142']): docker_specs go_version = 1.23.8; install = ['go test -c ./tsdb']; test_cmd = ['go test -v ./tsdb -run "^TestHead"']. The dataset 'version' field is literally the string '15142', which is the dict key.
- FAIL_TO_PASS (3): TestHeadAppendHistogramAndCommitConcurrency and its two subtests /integer_histogram and /float_histogram. PASS_TO_PASS: 76 entries, every one matching ^TestHead. Full row saved to /tmp/claude-1000/-home-rbera-work-bpeval-champsim-infra/46ab38b4-1504-46de-899d-d060c5dfc5f8/scratchpad/filt.json
- test_patch = one file, tsdb/head_test.go, +57 lines (two goroutines x 10000 Appender/AppendHistogram/Commit cycles). Saved at /tmp/claude-1000/-home-rbera-work-bpeval-champsim-infra/46ab38b4-1504-46de-899d-d060c5dfc5f8/scratchpad/test_patch.diff (sha256 8a831e9477f412c30d8081868498aeb4b7663d96d860a54a6cc9f38b658e074f). Gold patch touches only tsdb/head_append.go, 204 diff lines, at /tmp/claude-1000/-home-rbera-work-bpeval-champsim-infra/46ab38b4-1504-46de-899d-d060c5dfc5f8/scratchpad/gold_patch.diff. Both apply cleanly at base_commit with git apply (verified).
- END-TO-END VERIFIED ON THIS HOST: at base_commit + test_patch, `go test -v ./tsdb -run "^TestHead"` exits 1 with 'Received unexpected error: duplicate sample for timestamp' at head_test.go:6568, failing exactly the 3 FAIL_TO_PASS tests while 28 other TestHead* groups pass. After additionally applying the gold patch, the same command exits 0 and TestHeadAppendHistogramAndCommitConcurrency PASSes. The SWE-bench grading contract is therefore reproducible.
- RACE DETERMINISM (matters for your single-pinned-vCPU plan): the FAIL_TO_PASS test reproduced the bug 10/10 times -- 5/5 at GOMAXPROCS=1 under `taskset -c 3`, and 5/5 at GOMAXPROCS=4 under `taskset -c 0-3`. It does NOT need -race and does NOT need multiple cores; the failure surfaces as a deterministic-looking 'duplicate sample for timestamp' error, not a race-detector report.
- GO TOOLCHAIN: go.mod at base_commit says `go 1.22.0` + `toolchain go1.23.0`. .promu.yml says `go: version: 1.23`. CI (.github/workflows/ci.yml) uses quay.io/prometheus/golang-builder:1.23-base for the main test job and 1.22-base with GOTOOLCHAIN=local for the 'oldest' job. SWE-bench pins 1.23.8. Use exactly go1.23.8 (linux-amd64 tarball is 73,666,093 bytes, extracts to 269 MB).
- NATIVE/CGO DEPS: zero. `grep -rn --include='*.go' 'import "C"'` over the tree at base_commit returns 0 files. `CGO_ENABLED=0 go build ./...` succeeds. runtime/cgo is only pulled in by the stdlib (net, os/user) at the default CGO_ENABLED=1, so a working cc is needed unless you set CGO_ENABLED=0. Apt packages: the SWE-bench Go base Dockerfile (swebench/harness/dockerfiles/go.py) installs exactly `wget git build-essential` on ubuntu:<version>. Nothing else.
- MEASURED TIMINGS (this host: Ryzen 32 threads, NVMe, warm page cache; 4-CPU column via `taskset -c 0-3` + GOMAXPROCS=4 which proxies your 4-vCPU guest). go mod download (cold, network): 23 s. go build ./... COLD: 34 s @32cpu / 86 s @4cpu (4m55s of user CPU either way). go build ./... incremental after touching one file: 5.6 s @4cpu, 14.2 s @1cpu. go test -c ./tsdb from a totally cold build cache: 28 s @4cpu. go test -c ./tsdb warm: 4.5 s @32cpu, 7.3 s @4cpu; incremental: 1.3 s @4cpu, 2.3 s @1cpu. Full `go test -v ./tsdb -run "^TestHead"`: 12.6 s @32cpu, 11.4 s @4cpu, 12.5 s @1cpu -- it barely parallelizes because 8.1 s of it is the single serial TestHeadSeriesChunkRace. Agent inner loop (edit head_append.go -> compile -> run ^TestHead): 9.3 s @4cpu, 15.8 s @1cpu. Compiling EVERY test package in the repo (`go test -run='^$' ./...`): 20.8 s @32cpu / 2m42s user CPU.
- MEASURED DISK. go1.23.8 toolchain: 269 MB. GOMODCACHE after plain `go mod download`: 1.3 GB; after `go mod download all`: 1.5 GB. GOCACHE after only `go test -c ./tsdb`: 283 MB; after `go build ./...`: 1.3 GB; after also compiling every test package: 1.7 GB. Clean worktree: 27 MB. .git from a full clone: 286 MB (total 312 MB); `--filter=blob:none` blobless clone: 58 MB total; `--depth 1` shallow: 40 MB. Budget ~3.5 GB pre-populated (269 MB toolchain + 1.3 GB modcache + 1.7 GB buildcache + 313 MB repo).
- OFFLINE SUFFICIENCY VERIFIED: with GOPROXY=off GOTOOLCHAIN=local and only a plain `go mod download` having been run, all of `go build ./...`, `go test -c ./tsdb`, `go test -run='^$' ./...` (compiles every test binary in the repo) and `go list -deps -test ./...` succeed. Plain `go mod download` is sufficient for anything the agent can plausibly do, and it leaves go.sum untouched.
- go.sum GOTCHA: `go mod download all` adds 144 lines to go.sum (verified with git diff --stat). Plain `go mod download` adds 0. Do not run `go mod download all` during the build pass, or the agent starts on a dirty tree and its diff is polluted.
- REPO POLLUTION GOTCHA: SWE-bench's literal install step `go test -c ./tsdb` writes a 32,836,113-byte `tsdb.test` binary into the repo root, which then shows in `git status --porcelain` as `?? tsdb.test`. Use `go test -c -o /dev/null ./tsdb` instead (same cache warming, no artifact).
- go vet RED HERRING: `go vet ./tsdb` exits 1 at base_commit with 3 PRE-EXISTING stdmethods false positives (tsdb/querier.go:752, tsdb/querier.go:1196, tsdb/querier_test.go:765 -- 'method Seek(t int64) chunkenc.ValueType should have signature Seek(int64, int) (int64, error)'). These are unrelated to the task. `go test` is unaffected because stdmethods is not in go test's default vet subset.
- SWE-bench setup/eval procedure (swebench/harness/test_spec/utils.py, make_repo_script_list_common / make_eval_script_list_common). Setup: git clone -o origin https://github.com/prometheus/prometheus /testbed; chmod -R 777 /testbed; cd /testbed; git reset --hard <base_commit>; git remote remove origin; then the install commands. Eval: cd /testbed; git config --global --add safe.directory /testbed; git checkout <base_commit> tsdb/head_test.go; git apply --verbose --reject <test_patch heredoc>; go test -v ./tsdb -run "^TestHead"; git checkout <base_commit> tsdb/head_test.go. Note it removes the git remote so the agent cannot see newer commits -- do the same in your guest.
- The tsdb TestHead* tests do zero networking: `grep -c 'httptest|net.Listen|http.Get' tsdb/head_test.go` returns 0. They only use t.TempDir(). Safe for a no-network traced pass.
- Problem statement for the agent is prometheus/prometheus issue #15139 ('race in tsdb.headAppender.AppendHistogram'), a pasted Go race-detector report from Mimir. The fix landed as PR #15142, merge commit b8867f8eada6f604365eb62f416e6d95cd2cb07f (2024-10-14).

### Commands
```bash
sudo apt-get update && sudo apt-get install -y wget git build-essential ca-certificates
cd /tmp && wget -O go.tgz https://dl.google.com/go/go1.23.8.linux-amd64.tar.gz && sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go.tgz && rm -f /tmp/go.tgz
export PATH=/usr/local/go/bin:$PATH
go version
sudo mkdir -p /testbed && sudo chown "$USER:$USER" /testbed
git clone -o origin https://github.com/prometheus/prometheus /testbed
cd /testbed && git reset --hard 16bba78f1549cfd7909b61ebd7c55c822c86630b
cd /testbed && git rev-parse HEAD
cd /testbed && git remote remove origin
export GOMODCACHE=$HOME/go/pkg/mod GOCACHE=$HOME/.cache/go-build GOTOOLCHAIN=local
cd /testbed && go mod download
cd /testbed && go build ./...
cd /testbed && go test -c -o /dev/null ./tsdb
cd /testbed && go test -count=1 -run='^$' ./...
cd /testbed && git status --porcelain
cd /testbed && GOPROXY=off GOTOOLCHAIN=local go build ./... && echo OFFLINE_BUILD_OK
cd /testbed && GOPROXY=off GOTOOLCHAIN=local go test -c -o /dev/null ./tsdb && echo OFFLINE_TESTCOMPILE_OK
cd /testbed && git apply --verbose /path/to/test_patch.diff
cd /testbed && GOPROXY=off GOTOOLCHAIN=local go test -v -count=1 ./tsdb -run '^TestHeadAppendHistogramAndCommitConcurrency$'
cd /testbed && for i in 1 2 3 4 5 6 7 8 9 10; do taskset -c 3 env GOMAXPROCS=1 GOPROXY=off GOTOOLCHAIN=local go test -count=1 ./tsdb -run '^TestHeadAppendHistogramAndCommitConcurrency$' >/dev/null 2>&1 && echo "$i UNEXPECTED_PASS" || echo "$i EXPECTED_FAIL"; done
cd /testbed && GOPROXY=off GOTOOLCHAIN=local go test -v -count=1 ./tsdb -run '^TestHead'
cd /testbed && git checkout 16bba78f1549cfd7909b61ebd7c55c822c86630b tsdb/head_test.go
cd /testbed && git status --porcelain && du -sh /testbed $HOME/go/pkg/mod $HOME/.cache/go-build /usr/local/go
export PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=readonly GOMODCACHE=$HOME/go/pkg/mod GOCACHE=$HOME/.cache/go-build
```

### Risks
- Wrong Go version silently triggers a toolchain download. go.mod carries `toolchain go1.23.0`, so with Go < 1.23.0 and the default GOTOOLCHAIN=auto, every go command tries to fetch go1.23.0 from the proxy. In the no-network traced pass this hangs on DNS/TCP timeouts rather than failing fast, and it will show up in your trace as a multi-second network stall. DETECT/MITIGATE: install exactly go1.23.8 and export GOTOOLCHAIN=local in the guest profile so a mismatch fails immediately with 'go.mod requires go >= ...' instead of hanging.
- `go mod download all` dirties go.sum by +144 lines. If you run it during the build pass 'for safety', the agent starts on a dirty tree and its final `git diff` contains 144 unrelated go.sum lines, which fails SWE-bench grading in a confusing way. DETECT: `cd /testbed && git status --porcelain` must be completely empty before you snapshot. Plain `go mod download` is verified sufficient for offline `go build ./...`, `go test ./tsdb`, and even compiling every test package in the repo.
- SWE-bench's literal install command `go test -c ./tsdb` drops a 32 MB `tsdb.test` binary in /testbed. It shows as `?? tsdb.test`, and any agent step that does `git add -A` will swallow it into the patch. DETECT: `git status --porcelain` shows `?? tsdb.test`. MITIGATE: use `go test -c -o /dev/null ./tsdb`, or `rm -f /testbed/tsdb.test` after the install step.
- A cross-compiling or conda CC in the environment breaks the build in a way that looks like a prometheus problem. On this measurement host, conda's exported CC=aarch64-conda-linux-gnu-cc made `go build ./...` fail with `# runtime/cgo` / `unrecognized command-line option '-m64'` in 0.5 s. DETECT: `go env CC` must print `gcc`. MITIGATE: build under `env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS`, or set CGO_ENABLED=0 (verified to build the whole repo fine, since the repo has zero `import \"C\"`).
- Go build cache trimming can silently evict your pre-warmed GOCACHE. `go build` runs a trim pass about once a day and drops entries unused for more than 5 days. If the recorded VM image sits for a week between the build pass and the traced pass, the agent's first `go test -c ./tsdb` becomes a 28 s cold compile instead of a 1-2 s incremental one, distorting the trace. DETECT: time the first `go test -c -o /dev/null ./tsdb` in the traced guest; >10 s at 4 vCPU means the cache went cold. MITIGATE: re-run `go build ./... && go test -c -o /dev/null ./tsdb` immediately before starting the recording.
- Blobless (--filter=blob:none) or shallow (--depth 1) clones save 250 MB but break offline `git log -p`, `git show <old-sha>`, and `git blame`, because they lazily fetch blobs from the removed/unreachable remote. SWE-agent commonly runs git history commands while exploring. DETECT: in the guest with network off, run `git log -p -3 -- tsdb/head_append.go` -- a blobless clone errors with 'unable to read sha1 file' / 'fatal: promisor remote'. MITIGATE: use a plain full clone (286 MB .git), which is what SWE-bench itself does.
- The FAIL_TO_PASS test is scheduler-dependent by construction. I got 10/10 reproductions natively including at GOMAXPROCS=1 on a single pinned CPU, but TCG emulation changes goroutine interleaving substantially and I could not test that here. If it spuriously passes before the fix, the whole traced run is scientifically worthless. DETECT: during the build pass, run the 10x loop command above under the exact same taskset/GOMAXPROCS pinning you will use for tracing; all 10 must fail with 'duplicate sample for timestamp'.
- Test wall time is dominated by one unrelated test. Of the ~11 s for `go test -v ./tsdb -run "^TestHead"`, 8.1 s is TestHeadSeriesChunkRace alone, which is mostly serial and sleep-bound and will not parallelize. Under TCG at a typical 10-50x slowdown this single command becomes roughly 2-10 minutes of mostly-uninteresting emulation. DETECT: the per-test timings in the `go test -v` output. MITIGATE: consider tracing `-run '^TestHeadAppendHistogramAndCommitConcurrency'` (0.22 s native) for the tight loop and reserving the full ^TestHead run for a single final grading pass.
- `go vet ./tsdb` exits 1 at base_commit on 3 pre-existing stdmethods false positives in tsdb/querier.go and tsdb/querier_test.go. An agent that vets before/after its edit will see a nonzero exit unrelated to its change and may burn turns chasing it, lengthening and distorting the trace. DETECT: the 3 'method Seek(t int64) chunkenc.ValueType should have signature ...' lines. Note `go test` is unaffected -- stdmethods is not in go test's default vet subset.
- The HF /search endpoint URL in the task brief returns zero rows for query=15142, so a naive lookup yields nothing and could lead someone to guess a base_commit. Use the /filter endpoint with an explicit where clause (exact command listed in findings). A wrong base_commit would not be caught until the test patch fails to apply, hours into the build.

## Installing and configuring SWE-agent with the SWE-ReX LOCAL (no-Docker) deployment, pointed at a local OpenAI-compatible proxy, for a single SWE-bench Multilingual instance (prometheus__prometheus-15142) in an offline QEMU guest

**Confidence:** high

### Findings
- SWE-agent is NOT installable from PyPI. The PyPI name `swe-agent` 404s; the name `sweagent` exists but is an author-reserved stub whose ONLY release is 0.0.1 (verified: `curl https://pypi.org/pypi/sweagent/json` -> releases == ['0.0.1'], author 'John Yang', links to the old princeton-nlp repo). `pip install sweagent` would silently install a dead 0.0.1 package. Git clone + editable install is the only correct path (matches https://swe-agent.com/latest/installation/source/).
- Version/Python facts, verified by installing: pyproject `requires-python = ">=3.11"`; installed and ran successfully on Ubuntu's python3.12.3. Resulting stack: SWE-agent 1.1.0 (git 3ea751c087f32b16e039a2233dd6eefecef325d5, HEAD of main as of 2026-07-16), SWE-ReX 1.4.0, litellm 1.95.0. Dependency pins in pyproject: `swe-rex>=1.4.0`, `litellm>=1.44.12,!=1.82.7,!=1.82.8`.
- IMPORTANT PROJECT STATUS: https://swe-agent.com/latest/installation/ states SWE-agent "has been superseded by mini-swe-agent" and is "now in maintenance-only mode". mini-swe-agent IS on PyPI (v2.4.6, requires-python >=3.10) and would be a much simpler local/no-Docker target. Flagging because it may change the workload choice; SWE-agent still works fine.
- LOCAL deployment flag verified: `--env.deployment.type=local`. SWE-ReX `src/swerex/deployment/config.py` defines `LocalDeploymentConfig` with `type: Literal["local"] = "local"` and no other fields. Verified by parsing a full CLI arg list -> resolved to `LocalDeploymentConfig type='local'`, and by an actual completed end-to-end run. The `--env.deployment.type=` dotted form is confirmed by SWE-agent's own `sweagent run --help` example (`--env.deployment.type=modal`). Full set of deployment literals: local, docker, modal, fargate, remote, dummy, daytona.
- BLOCKER (verified by running as uid 1000): the LOCAL deployment REQUIRES ROOT. SWE-agent hardcodes `/root/...` paths that under LocalDeployment are the REAL filesystem, not a container: `/root/tools/<bundle>` (sweagent/tools/tools.py:270), `/root/state.json` (:263), `/root/.swe-agent-env` (:262), `/root/model.patch` (sweagent/agent/agents.py:887), `/root/.bashrc` as bash startup_source (sweagent/environment/swe_env.py:186). As a non-root user the run dies with `PermissionError: [Errno 13] Permission denied: '/root/tools'`. Run the agent as root in the guest.
- BLOCKER (verified by re-running): SWE-ReX `LocalRuntime.upload` calls `shutil.copytree(source, target)` WITHOUT `dirs_exist_ok=True` (venv/.../swerex/runtime/local.py:467). A second run therefore aborts with `FileExistsError: [Errno 17] File exists: '/root/tools/registry'`. `/root/tools` MUST be deleted before every run. This bites exactly the build-pass-then-traced-pass workflow.
- Repo placement: the repo must live at `/<repo_name>` (filesystem ROOT) under local deployment. `SWEEnv.reset()` does `cd /` then `_copy_repo()` then `cd /<repo_name>` (sweagent/environment/swe_env.py:144-160). `LocalRepoConfig.copy()` uploads to `/{repo_name}` and then runs `chown -R root:root /{repo_name}` (sweagent/environment/repo.py). Use `--env.repo.type=preexisting --env.repo.repo_name=prometheus` with the repo pre-placed at `/prometheus` -> `copy()` is a no-op, avoiding a multi-GB copy during the traced pass.
- NO-NETWORK BLOCKER: `_get_git_reset_commands()` (sweagent/environment/repo.py) begins with `git fetch`, run via `communicate(..., check="raise", timeout=120)`. Verified empirically: with an `origin` remote and no network, `git fetch` HANGS (I killed it at 20s); the 120s timeout would then fail the run. Verified: with NO remotes configured at all, `git fetch` exits 0 immediately. Two independent fixes: (a) `--env.repo.reset=false` (only exists on PreExistingRepoConfig, NOT on LocalRepoConfig), and/or (b) `git remote remove origin` in the guest during the build pass.
- NO-NETWORK BLOCKER: `tools/edit_anthropic/install.sh` runs `pip install 'tree-sitter==0.21.3'` and `pip install 'tree-sitter-languages'` on every run. Both are `|| true` so they cannot fail the run, but offline pip retries/timeouts stall startup and pollute the trace. My first end-to-end attempt exceeded a 10-minute timeout in this install phase. Pre-install both wheels during the build pass so pip short-circuits with 'already satisfied'.
- NO-NETWORK BLOCKER: litellm fetches its model-cost map over HTTP from GitHub at import time unless `LITELLM_LOCAL_MODEL_COST_MAP=True` is set (verified in venv/.../litellm/litellm_core_utils/get_model_cost_map.py:1-9 and :277). Set that env var for the traced pass or every process start pays an httpx timeout.
- NO-NETWORK BLOCKER: `--instances.type=swe_bench` calls `datasets.load_dataset(...)` at startup (sweagent/run/batch_instances.py). The multilingual subset maps to the HF dataset `swe-bench/SWE-Bench_Multilingual`. Requires network unless the HF cache is pre-populated and HF_HUB_OFFLINE=1/HF_DATASETS_OFFLINE=1 are set. Simplest offline answer: don't use it (see next finding).
- `--instances.type=swe_bench` is INCOMPATIBLE with local deployment. `SimpleBatchInstance.from_swe_bench()` unconditionally populates a Docker image name (`docker.io/swebench/sweb.eval.x86_64.<id>:latest`) when the dataset row lacks one, and `to_full_batch_instance()` then raises `ValueError: Local deployment does not support image_name` for LocalDeploymentConfig (sweagent/run/batch_instances.py:139-142, :175-193). Verified by source reading. You must supply your own instances file with `image_name: ""`, or use `sweagent run` (single).
- Model config verified END-TO-END against a real local OpenAI-compatible server on 127.0.0.1:8000: `--agent.model.name=openai/<name>`, `--agent.model.api_base=http://127.0.0.1:8000/v1`, `--agent.model.api_key=<key>`, `--agent.model.temperature=0.0`. My mock server logged exactly: `{"model": "mock-model", "temperature": 0.0, "top_p": 1.0, "auth": "Bearer dummy-key"}`. Note the `openai/` litellm routing prefix IS STRIPPED before the wire request — the proxy receives the bare model name.
- MUST set `--agent.model.per_instance_cost_limit=0 --agent.model.total_cost_limit=0` for a local model. GenericAPIModelConfig defaults are `per_instance_cost_limit=3.0` / `total_cost_limit=0.0`; when litellm cannot price an unknown model name SWE-agent raises `ModelConfigurationError` telling you to zero both. Verified: with both at 0 the run completed and reported `instance_cost: 0`.
- Once cost limits are zeroed, `per_instance_call_limit` is the ONLY remaining automatic stop. It is enforced at sweagent/agent/models.py:667 (`if 0 < self.config.per_instance_call_limit < self.stats.api_calls: raise InstanceCallLimitExceededError`) and DEFAULTS TO 0 = disabled. My unbounded test run reached 57 API calls and kept going. For a bounded, reproducible trace you must set it explicitly.
- Env-var alternative verified working with litellm 1.95.0: `OPENAI_API_BASE=http://127.0.0.1:8000/v1 OPENAI_API_KEY=<key>` with model `openai/<name>` produced `{"model": "env-test-model", "auth": "Bearer env-var-key"}` on the server. SWE-agent also auto-loads a `.env` from CWD or repo root (sweagent/utils/config.py:60-80), overridable with `--env_var_path`. The explicit `--agent.model.*` flags are preferred (they beat ambient env and are recorded in the run's config.yaml).
- Output artifacts verified by inspecting a real completed run. `sweagent run --output_dir=DIR` writes `DIR/<instance_id>/`: `<instance_id>.traj`, `<instance_id>.info.log`, `<instance_id>.debug.log`, `<instance_id>.trace.log`, `config.yaml`. The `.traj` is JSON (`json.dumps(data, indent=2)`, agents.py:787) with top-level keys `['trajectory','history','info','replay_config','environment']`. Each `trajectory[i]` has `['action','observation','response','thought','execution_time','state','query','extra_info']`. `info` has `['swe_agent_hash','swe_agent_version','swe_rex_version','swe_rex_hash','submission','exit_status','edited_files30','edited_files50','edited_files70','model_stats']`; `model_stats` = `{'instance_cost','tokens_sent','tokens_received','api_calls'}`.
- `run-batch` additionally writes `<output_dir>/preds.json` (merged), `run_batch.log`, `run_batch_exit_statuses.yaml`, `run_batch.config.yaml`, and per-instance `<instance_id>.pred` = `{"model_name_or_path", "instance_id", "model_patch"}` (sweagent/run/common.py:370-379). `sweagent run` (single) does NOT write `.pred`/`preds.json` — the patch is in `.traj` under `info.submission`.
- For SWE-bench Multilingual (Go) use `config/benchmarks/anthropic_filemap_multilingual.yaml`, not `config/default.yaml`: it strips Python-specific prompt language and swaps in the `multilingual_setup` tool bundle. Verified its bundle list resolves to ['multilingual_setup','registry','edit_anthropic','review_on_submit_m','diff_state']. Caveat: `tools/multilingual_setup/install.sh` reads `/proc/1/environ` to import PID-1 env vars — harmless in Docker, but under local deployment as root in the guest PID 1 is systemd, and it will import systemd's environment (it does skip PATH-merging safely and excludes PWD/LANG/PYTHONPATH/etc.).
- `--instances.filter` uses `re.match` (sweagent/run/batch_instances.py:75), which is a PREFIX match, not a full match. `--instances.filter=prometheus__prometheus-1514` would also match `-15142`, `-15140`, etc. Anchor it with `$`.
- The `expert_file` instance source is the only batch path giving full per-instance control (it validates full `BatchInstance` objects, so you can set `env.repo.reset: false`, which `InstancesFromFile`/SimpleBatchInstance cannot express — SimpleBatchInstance has no `reset` field and always builds `PreExistingRepoConfig` with the default `reset=True`). Verified: an expert_file entry with `reset: false` yields `get_reset_commands() == []`, i.e. no `git fetch`.

### Commands
```bash
# ============================================================
# BUILD PASS (network available, run as root in the guest)
# ============================================================
apt-get update && apt-get install -y python3.12 python3.12-venv git golang-go
git clone https://github.com/SWE-agent/SWE-agent.git /opt/SWE-agent
git -C /opt/SWE-agent checkout 3ea751c087f32b16e039a2233dd6eefecef325d5   # pin the exact commit I verified (SWE-agent 1.1.0)
python3.12 -m venv /opt/swea-venv
/opt/swea-venv/bin/python -m pip install --upgrade pip
/opt/swea-venv/bin/pip install --editable /opt/SWE-agent
/opt/swea-venv/bin/sweagent --help   # verify: prints 'SWE-agent version 1.1.0 ... with SWE-ReX version 1.4.0'
# Pre-install the tool-bundle deps so edit_anthropic/install.sh does NOT hit the network at trace time
/opt/swea-venv/bin/pip install 'tree-sitter==0.21.3' 'tree-sitter-languages'
# Place the repo at the FILESYSTEM ROOT (required by local deployment) and pin the base commit
git clone https://github.com/prometheus/prometheus.git /prometheus
git -C /prometheus checkout <BASE_COMMIT_FROM_THE_SWEBENCH_INSTANCE>
# Kill the remote so any stray 'git fetch' exits 0 instantly offline instead of hanging
git -C /prometheus remote remove origin
git -C /prometheus status --porcelain   # MUST be empty; a dirty tree changes agent behavior
# Pre-populate the Go module cache so the agent's builds/tests work offline
cd /prometheus && go mod download && go build ./... && go vet ./... 2>/dev/null || true
# Write the problem statement to a file (avoids shell-quoting a huge issue body)
# Put the instance's 'problem_statement' field verbatim into /root/problem_statement.md
# Smoke-test the whole path ONCE now, while network still exists (proxy must be up on 127.0.0.1:8000)
rm -rf /root/tools /root/state.json /root/.swe-agent-env /root/model.patch
/opt/swea-venv/bin/sweagent run --config /opt/SWE-agent/config/benchmarks/anthropic_filemap_multilingual.yaml --agent.model.name=openai/local-model --agent.model.api_base=http://127.0.0.1:8000/v1 --agent.model.api_key=dummy --agent.model.temperature=0.0 --agent.model.per_instance_cost_limit=0 --agent.model.total_cost_limit=0 --agent.model.per_instance_call_limit=5 --env.deployment.type=local --env.repo.type=preexisting --env.repo.repo_name=prometheus --env.repo.reset=false --problem_statement.type=text_file --problem_statement.path=/root/problem_statement.md --problem_statement.id=prometheus__prometheus-15142 --output_dir=/root/swea-smoke
# ============================================================
# TRACED PASS (NO network, run as root, pinned to the isolated vCPU)
# ============================================================
# MANDATORY: stale tool dirs make SWE-ReX's copytree raise FileExistsError
rm -rf /root/tools /root/state.json /root/.swe-agent-env /root/model.patch
git -C /prometheus reset --hard && git -C /prometheus clean -fdq
export LITELLM_LOCAL_MODEL_COST_MAP=True
export HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 TRANSFORMERS_OFFLINE=1
export PIP_NO_INDEX=1 PIP_RETRIES=0 PIP_TIMEOUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true
export NO_PROXY='*' no_proxy='*'
taskset -c 3 /opt/swea-venv/bin/sweagent run --config /opt/SWE-agent/config/benchmarks/anthropic_filemap_multilingual.yaml --agent.model.name=openai/local-model --agent.model.api_base=http://127.0.0.1:8000/v1 --agent.model.api_key=dummy --agent.model.temperature=0.0 --agent.model.per_instance_cost_limit=0 --agent.model.total_cost_limit=0 --agent.model.per_instance_call_limit=100 --env.deployment.type=local --env.repo.type=preexisting --env.repo.repo_name=prometheus --env.repo.reset=false --problem_statement.type=text_file --problem_statement.path=/root/problem_statement.md --problem_statement.id=prometheus__prometheus-15142 --output_dir=/root/swea-out
# Results:
#   /root/swea-out/prometheus__prometheus-15142/prometheus__prometheus-15142.traj   <- JSON trajectory
#   /root/swea-out/prometheus__prometheus-15142/prometheus__prometheus-15142.info.log
#   /root/swea-out/prometheus__prometheus-15142/config.yaml
# Extract the produced patch and the step/token counts from the .traj:
/opt/swea-venv/bin/python -c "import json,sys; d=json.load(open('/root/swea-out/prometheus__prometheus-15142/prometheus__prometheus-15142.traj')); print('exit_status:', d['info'].get('exit_status')); print('model_stats:', d['info'].get('model_stats')); print('steps:', len(d['trajectory'])); print(d['info'].get('submission') or '<no patch>')"
# ============================================================
# ALTERNATIVE: run-batch by instance_id (gives preds.json, SWE-bench-format)
# Requires your OWN instances file: image_name MUST be "" or local deployment raises.
# ============================================================
cat > /root/instances.json <<'EOF'
[
  {
    "env": {
      "deployment": {"type": "local"},
      "repo": {"type": "preexisting", "repo_name": "prometheus",
               "base_commit": "<BASE_COMMIT>", "reset": false}
    },
    "problem_statement": {"type": "text", "id": "prometheus__prometheus-15142",
                          "text": "<PROBLEM STATEMENT TEXT>"}
  }
]
EOF
rm -rf /root/tools /root/state.json /root/.swe-agent-env /root/model.patch
taskset -c 3 /opt/swea-venv/bin/sweagent run-batch --config /opt/SWE-agent/config/benchmarks/anthropic_filemap_multilingual.yaml --instances.type=expert_file --instances.path=/root/instances.json --instances.filter='prometheus__prometheus-15142$' --agent.model.name=openai/local-model --agent.model.api_base=http://127.0.0.1:8000/v1 --agent.model.api_key=dummy --agent.model.temperature=0.0 --agent.model.per_instance_cost_limit=0 --agent.model.total_cost_limit=0 --agent.model.per_instance_call_limit=100 --output_dir=/root/swea-batch-out
```

### Risks
- SILENT WRONG PACKAGE: `pip install sweagent` succeeds and installs a dead 0.0.1 stub with no `sweagent` CLI. Detect: `sweagent --help` must print 'This is SWE-agent version 1.1.0 ... with SWE-ReX version 1.4.0'. If it prints nothing or the command is missing, you installed the stub.
- SECOND RUN ALWAYS CRASHES unless `/root/tools` is removed: SWE-ReX's `shutil.copytree` lacks `dirs_exist_ok`, giving `FileExistsError: /root/tools/registry`. This is guaranteed to bite you between the build-pass smoke test and the traced pass. Always `rm -rf /root/tools` first. Detect: grep the run log for `FileExistsError`.
- RUNNING AS NON-ROOT fails at tool install with `PermissionError: /root/tools`. If your guest runs the agent as a normal user to look 'realistic', local deployment simply will not work without patching hardcoded `/root` paths. Detect: `PermissionError` in the log. There is no config key to relocate these paths.
- OFFLINE HANG on `git fetch`: if you leave an `origin` remote on /prometheus AND do not pass `--env.repo.reset=false`, the reset chain blocks for the full 120s `communicate` timeout and then fails the run with 'Failed to clean repository'. I reproduced the hang directly. Belt-and-braces: do BOTH `git remote remove origin` and `reset=false`. Detect: a ~120s stall right after 'Resetting repository' in the log.
- OFFLINE STALL on pip: `edit_anthropic/install.sh` pip-installs tree-sitter on EVERY run and swallows failures with `|| true`, so it will never error — it will just burn minutes of wall clock and inject pip/network syscalls into your trace. My first run blew a 10-minute timeout here. Detect: time from process start to the first model API call; it should be seconds, not minutes. Verify with `/opt/swea-venv/bin/pip show tree-sitter`.
- OFFLINE STALL on litellm import: without `LITELLM_LOCAL_MODEL_COST_MAP=True`, litellm tries to GET its cost map from GitHub at import. Adds an httpx timeout to every process start and pollutes the trace with network syscalls. Detect: unexplained multi-second delay before the banner prints.
- UNBOUNDED RUN: with both cost limits at 0 (which you MUST set for a local model), `per_instance_call_limit` defaults to 0 = DISABLED, so nothing stops the agent. My test run hit 57 API calls and was still looping when I killed it. For a fixed-length trace this is the difference between a bounded workload and an infinite one. Always set `--agent.model.per_instance_call_limit=<N>` and confirm `info.model_stats.api_calls` in the .traj.
- `--instances.type=swe_bench` CANNOT work with local deployment (raises `ValueError: Local deployment does not support image_name`) and also needs HF network access. If you try the 'obvious' `--instances.type=swe_bench --instances.subset=multilingual --instances.filter=<id>`, it will fail. Use `sweagent run` or an `expert_file` instances file.
- PREFIX-MATCH FILTER: `--instances.filter` uses `re.match`, so an unanchored instance id can select more instances than intended, silently turning a 1-instance trace into an N-instance one. Always append `$`. Detect: 'Instance filter: X -> Y instances' in the log; Y must be 1.
- DIRTY REPO changes the workload non-deterministically. With `reset=false` nothing cleans /prometheus, so a leftover edit from the build-pass smoke test persists into the traced pass and the agent sees a different starting state. Always `git -C /prometheus reset --hard && git clean -fdq` immediately before the traced run, and confirm `git status --porcelain` is empty.
- TRACE CONTAMINATION from the smoke test: the build-pass smoke run leaves /root/tools, /root/state.json and a modified /prometheus behind. Clean all of them before recording, or the traced pass measures a different code path (skipped tool install) than a cold start.
- PROXY CONTRACT: the proxy receives the model name with the `openai/` prefix STRIPPED (verified: `openai/local-model` arrived as `local-model`). If your proxy routes on the exact string, register the bare name. It also receives `top_p: 1.0` and an `Authorization: Bearer <key>` header; litellm requires a non-empty api_key even for a keyless local proxy.
- TOOL-CALLING REQUIRED: the default and multilingual configs use `parse_function: {type: function_calling}` and send a `tools` array (3 tools in my default-config run). A proxy or local model that does not implement OpenAI tool_calls will make the agent fail or requery in a loop. Validate the proxy against a tool-calling request before the traced pass.
- `multilingual_setup/install.sh` reads `/proc/1/environ` and exports PID-1's environment into the agent shell. In the guest PID 1 is systemd (not a container init), so the agent inherits systemd's env. It excludes PWD/LANG/PYTHONPATH/etc. and merges PATH safely, but if you see odd env-dependent behavior in the agent shell, this is the cause.
- UNVERIFIED IN-GUEST: I could not execute the full agent loop against the real prometheus checkout here — the host blocks both root and unprivileged user namespaces (Ubuntu 24.04 restricts unprivileged userns), so I validated the run by redirecting the hardcoded /root paths to a writable dir. The config parsing, local deployment startup, proxy plumbing, and .traj output are all empirically confirmed; the `/root`-as-root path and the Go-repo-specific agent behavior are inferred from source and must be smoke-tested in the guest during the build pass.

---

# Verification: what was independently checked

Agent output is evidence, not fact. These were confirmed against primary sources
or by running them on this host.

## Verified correct

| Claim | Check | Result |
|---|---|---|
| `base_commit` = `16bba78f1549cfd7909b61ebd7c55c822c86630b` | HF datasets-server `/filter` on `SWE-bench/SWE-bench_Multilingual` | **confirmed** |
| `FAIL_TO_PASS` = `TestHeadAppendHistogramAndCommitConcurrency` (+subtests) | same query | **confirmed** |
| repo = `prometheus/prometheus`, version `15142` | same query | **confirmed** |
| `/search` endpoint is useless for this lookup | returned 0 rows for `15142`; `/filter` returned 1 | **confirmed** |
| Guest boots under KVM, serial console works | booted the image, 848 serial lines | **confirmed** |
| `setfacl` on `/dev/kvm` is not durable | ACL verified present, then gone ~30 min later | **confirmed** |

## Corrected

**`base_commit` conflict.** The Prometheus researcher reported
`032ca9ef96ce0dd236c75bcdea2a8e9f7a74c6e8`; the SWE-agent researcher reported
`16bba78f…`. The dataset says `16bba78f…`. `032ca9ef…` is PR 15142's merge base
on GitHub, which is *not* the same thing as the benchmark row's `base_commit`.
Every downstream fact the Prometheus report derived from `032ca9ef…` — go.mod
contents, dependency counts, timings — must be re-derived at `16bba78f…` before
being trusted.

**Dataset name casing.** The synthesis uses `swe-bench/SWE-Bench_Multilingual`.
The name that resolved here is `SWE-bench/SWE-bench_Multilingual`.

## Explicitly NOT verified — treat as hypotheses

- Every Go command sequence. The Prometheus researcher stated plainly that it
  could not execute any of them: there is no Go toolchain on this host. The
  `unshare -n` offline gate must be run before committing to an image.
- The `go mod download` vs `go mod download all` conflict. The reports disagree
  (completeness vs. a 144-line `go.sum` dirt that breaks patch extraction). The
  synthesis proposes `all` followed by `git checkout -- go.mod go.sum`. Plausible,
  unproven — resolve empirically with the offline gate, not by argument.
- That the FAIL_TO_PASS test reproduces reliably **under TCG**. It is a
  concurrency test, and TCG changes goroutine interleaving. If it spuriously
  passes before the fix, the run is scientifically worthless. This is the single
  biggest scientific risk in Pass 1 and must be gated during the build pass.
- Disk sizing (40 G) and all wall-clock estimates.
