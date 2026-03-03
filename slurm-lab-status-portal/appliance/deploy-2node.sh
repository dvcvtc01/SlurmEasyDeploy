#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

usage() {
  cat <<'EOF'
Deploy a 2-node Slurm cluster appliance (controller + compute) from separate OVAs.

Requirements:
  - govc, jq, base64, ssh-keygen
  - GOVC_URL / GOVC_USERNAME / GOVC_PASSWORD / GOVC_INSECURE exported

Example (static IP):
  ./appliance/deploy-2node.sh \
    --controller-ova ./dist/slurm-ctrl01.ova \
    --compute-ova ./dist/slurm-c01.ova \
    --datacenter DC01 \
    --datastore datastore1 \
    --network "VM Network" \
    --resource-pool "/DC01/host/Cluster/Resources" \
    --controller-vm-name cust-slurm-ctrl01 \
    --compute-vm-name cust-slurm-c01 \
    --controller-hostname cust-slurm-ctrl01 \
    --compute-hostname cust-slurm-c01 \
    --controller-cpu 4 --controller-memory-mb 8192 --controller-disk-gb 80 \
    --compute-cpu 8 --compute-memory-mb 16384 --compute-disk-gb 120 \
    --controller-ip-cidr 10.0.10.10/24 \
    --compute-ip-cidr 10.0.10.11/24 \
    --gateway 10.0.10.1 \
    --dns 10.0.10.2,1.1.1.1 \
    --portal-ssh-user slurmportal \
    --domain example.local \
    --timezone Europe/London

Example (DHCP):
  ./appliance/deploy-2node.sh \
    --controller-ova ./dist/slurm-ctrl01.ova \
    --compute-ova ./dist/slurm-c01.ova \
    --datacenter DC01 \
    --datastore datastore1 \
    --network "VM Network" \
    --resource-pool "/DC01/host/Cluster/Resources" \
    --controller-vm-name cust-slurm-ctrl01 \
    --compute-vm-name cust-slurm-c01 \
    --controller-hostname cust-slurm-ctrl01 \
    --compute-hostname cust-slurm-c01 \
    --controller-cpu 4 --controller-memory-mb 8192 \
    --compute-cpu 8 --compute-memory-mb 16384 \
    --dhcp

Notes:
  - SSH trust for portal health probes is automated:
    - Generates an ed25519 keypair for --portal-ssh-user (default: slurmportal)
    - Installs public key into ~<compute-user>/.ssh/authorized_keys on compute
    - Seeds known_hosts and verifies BatchMode SSH from controller
EOF
}

b64enc_file() {
  local input="$1"
  if base64 --help 2>/dev/null | grep -q -- "-w"; then
    base64 -w0 "$input"
  else
    base64 "$input" | tr -d '\n'
  fi
}

join_csv_as_yaml_array() {
  local csv="$1"
  local arr=()
  local item
  IFS=',' read -r -a arr <<<"$csv"
  printf "["
  for i in "${!arr[@]}"; do
    item="$(echo "${arr[$i]}" | xargs)"
    printf "'%s'" "$item"
    if [[ "$i" -lt "$((${#arr[@]} - 1))" ]]; then
      printf ", "
    fi
  done
  printf "]"
}

ip_from_cidr() {
  local cidr="$1"
  printf '%s' "${cidr%%/*}"
}

import_vm_from_ova() {
  local ova="$1"
  local vm_name="$2"
  local vm_network="$3"
  local spec_raw="$4"
  local spec_patched="$5"

  GOVC_DATACENTER="$DATACENTER" govc import.spec "$ova" >"$spec_raw"
  jq \
    --arg name "$vm_name" \
    --arg net "$vm_network" \
    '
    .Name = $name
    | .NetworkMapping = (.NetworkMapping | map(.Network = $net))
    ' \
    "$spec_raw" >"$spec_patched"

  local args=(
    import.ova
    -dc "$DATACENTER"
    -ds "$DATASTORE"
    -pool "$RESOURCE_POOL"
    -options "$spec_patched"
  )
  if [[ -n "$FOLDER" ]]; then
    args+=(-folder "$FOLDER")
  fi
  args+=("$ova")
  govc "${args[@]}"
}

inject_cloud_init() {
  local vm_name="$1"
  local metadata_file="$2"
  local userdata_file="$3"
  local meta_b64
  local user_b64
  meta_b64="$(b64enc_file "$metadata_file")"
  user_b64="$(b64enc_file "$userdata_file")"
  govc vm.change -dc "$DATACENTER" -vm "$vm_name" \
    -e "guestinfo.metadata=${meta_b64}" \
    -e "guestinfo.metadata.encoding=base64" \
    -e "guestinfo.userdata=${user_b64}" \
    -e "guestinfo.userdata.encoding=base64"
}

configure_vm_hardware() {
  local vm_name="$1"
  local cpu="$2"
  local mem_mb="$3"
  local disk_gb="$4"
  govc vm.change -dc "$DATACENTER" -vm "$vm_name" -c "$cpu" -m "$mem_mb"
  if [[ -n "$disk_gb" ]]; then
    govc vm.disk.change -dc "$DATACENTER" -vm "$vm_name" -disk.label "Hard disk 1" -size "${disk_gb}G" || \
      echo "WARN: disk resize failed for $vm_name; resize manually in vSphere if required."
  fi
}

create_metadata_file() {
  local output_file="$1"
  local hostname_target="$2"
  local ip_cidr="$3"
  local gateway="$4"
  local dns_csv="$5"

  if [[ "$NETWORK_MODE" == "dhcp" ]]; then
    cat >"$output_file" <<EOF
instance-id: ${hostname_target}-$(date +%s)
local-hostname: ${hostname_target}
network:
  version: 2
  ethernets:
    nic0:
      match:
        name: "e*"
      dhcp4: true
EOF
  else
    local dns_yaml
    dns_yaml="$(join_csv_as_yaml_array "$dns_csv")"
    cat >"$output_file" <<EOF
instance-id: ${hostname_target}-$(date +%s)
local-hostname: ${hostname_target}
network:
  version: 2
  ethernets:
    nic0:
      match:
        name: "e*"
      dhcp4: false
      addresses: ['${ip_cidr}']
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses: ${dns_yaml}
EOF
  fi
}

create_controller_firstboot_script() {
  local output_file="$1"
  local portal_priv_key_b64="$2"
  local portal_pub_key_b64="$3"
  cat >"$output_file" <<EOF
#!/usr/bin/env bash
set -euxo pipefail

CTRL_HOST="${CONTROLLER_HOSTNAME}"
CMP_HOST="${COMPUTE_HOSTNAME}"
CTRL_IP="${CONTROLLER_IP}"
CMP_IP="${COMPUTE_IP}"
NODE_CPUS="${COMPUTE_CPU}"
NODE_REALMEM="${COMPUTE_REAL_MEMORY}"
NODE_SOCKETS="${COMPUTE_SOCKETS_PER_BOARD}"
NODE_CORES="${COMPUTE_CORES_PER_SOCKET}"
NODE_THREADS="${COMPUTE_THREADS_PER_CORE}"
PORTAL_SSH_USER="${PORTAL_SSH_USER}"
COMPUTE_SSH_USER="${COMPUTE_USER}"
PORTAL_PRIV_KEY_B64="${portal_priv_key_b64}"
PORTAL_PUB_KEY_B64="${portal_pub_key_b64}"
SLURM_CONF="/etc/slurm-llnl/slurm.conf"

if [[ -n "\$CTRL_IP" && -n "\$CMP_IP" ]]; then
  sed -i '/# slurm-managed$/d' /etc/hosts || true
  printf '%s %s # slurm-managed\n' "\$CTRL_IP" "\$CTRL_HOST" >> /etc/hosts
  printf '%s %s # slurm-managed\n' "\$CMP_IP" "\$CMP_HOST" >> /etc/hosts
fi

if [[ -f "\$SLURM_CONF" ]]; then
  sed -i -E "s|^SlurmctldHost=.*|SlurmctldHost=\${CTRL_HOST}|; s|^SlurmctldPidFile=.*|SlurmctldPidFile=/run/slurmctld.pid|; s|^SlurmdPidFile=.*|SlurmdPidFile=/run/slurmd.pid|; s|^ProctrackType=.*|ProctrackType=proctrack/linuxproc|; s|^TaskPlugin=.*|TaskPlugin=task/none|" "\$SLURM_CONF"

  if grep -q '^SrunPortRange=' "\$SLURM_CONF"; then
    sed -i 's|^SrunPortRange=.*|SrunPortRange=60001-60010|' "\$SLURM_CONF"
  else
    sed -i '/^SlurmdPort=/a SrunPortRange=60001-60010' "\$SLURM_CONF"
  fi

  NODE_LINE="NodeName=\${CMP_HOST} CPUs=\${NODE_CPUS} Boards=1 SocketsPerBoard=\${NODE_SOCKETS} CoresPerSocket=\${NODE_CORES} ThreadsPerCore=\${NODE_THREADS} RealMemory=\${NODE_REALMEM}"
  if grep -q '^NodeName=' "\$SLURM_CONF"; then
    sed -i -E "s|^NodeName=.*|\${NODE_LINE}|" "\$SLURM_CONF"
  else
    printf '%s\n' "\$NODE_LINE" >> "\$SLURM_CONF"
  fi

  PART_LINE="PartitionName=debug Nodes=\${CMP_HOST} Default=YES MaxTime=01:00:00 State=UP"
  if grep -q '^PartitionName=' "\$SLURM_CONF"; then
    sed -i -E "s|^PartitionName=.*|\${PART_LINE}|" "\$SLURM_CONF"
  else
    printf '%s\n' "\$PART_LINE" >> "\$SLURM_CONF"
  fi
fi

ln -sfn /etc/slurm-llnl/slurm.conf /etc/slurm/slurm.conf || true
mkdir -p /var/spool/slurm-llnl/slurmctld /var/log/slurm-llnl
chown -R slurm:slurm /var/spool/slurm-llnl/slurmctld /var/log/slurm-llnl || true

# Configure one-time SSH trust for portal -> compute probes.
if ! id -u "\$PORTAL_SSH_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "\$PORTAL_SSH_USER"
fi
SSH_HOME="$(getent passwd "\$PORTAL_SSH_USER" | cut -d: -f6)"
install -d -m 700 -o "\$PORTAL_SSH_USER" -g "\$PORTAL_SSH_USER" "\$SSH_HOME/.ssh"
printf '%s' "\$PORTAL_PRIV_KEY_B64" | base64 -d >"\$SSH_HOME/.ssh/id_ed25519"
printf '%s' "\$PORTAL_PUB_KEY_B64" | base64 -d >"\$SSH_HOME/.ssh/id_ed25519.pub"
touch "\$SSH_HOME/.ssh/known_hosts"
chown "\$PORTAL_SSH_USER:\$PORTAL_SSH_USER" "\$SSH_HOME/.ssh/id_ed25519" "\$SSH_HOME/.ssh/id_ed25519.pub" "\$SSH_HOME/.ssh/known_hosts"
chmod 600 "\$SSH_HOME/.ssh/id_ed25519" "\$SSH_HOME/.ssh/known_hosts"
chmod 644 "\$SSH_HOME/.ssh/id_ed25519.pub"
for ssh_target in "\$CMP_HOST" "\$CMP_IP"; do
  if [[ -n "\$ssh_target" ]]; then
    ssh-keyscan -T 2 -H "\$ssh_target" >>"\$SSH_HOME/.ssh/known_hosts" 2>/dev/null || true
  fi
done
if command -v ssh >/dev/null 2>&1; then
  su -s /bin/bash "\$PORTAL_SSH_USER" -c \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=2 \${COMPUTE_SSH_USER}@\${CMP_HOST} hostname" || true
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 6817/tcp || true
  if [[ -n "\$CMP_IP" ]]; then
    ufw allow from "\$CMP_IP" to any port 60001:60010 proto tcp || true
  fi
fi

systemctl daemon-reload || true
systemctl enable munge slurmctld || true
systemctl restart munge || true
systemctl restart slurmctld || true
if systemctl list-unit-files | grep -q '^slurm-portal.service'; then
  systemctl enable slurm-portal || true
  systemctl restart slurm-portal || true
fi
EOF
}

create_compute_firstboot_script() {
  local output_file="$1"
  local portal_pub_key_b64="$2"
  cat >"$output_file" <<EOF
#!/usr/bin/env bash
set -euxo pipefail

CTRL_HOST="${CONTROLLER_HOSTNAME}"
CMP_HOST="${COMPUTE_HOSTNAME}"
CTRL_IP="${CONTROLLER_IP}"
CMP_IP="${COMPUTE_IP}"
NODE_CPUS="${COMPUTE_CPU}"
NODE_REALMEM="${COMPUTE_REAL_MEMORY}"
NODE_SOCKETS="${COMPUTE_SOCKETS_PER_BOARD}"
NODE_CORES="${COMPUTE_CORES_PER_SOCKET}"
NODE_THREADS="${COMPUTE_THREADS_PER_CORE}"
COMPUTE_SSH_USER="${COMPUTE_USER}"
PORTAL_PUB_KEY_B64="${portal_pub_key_b64}"
SLURM_CONF="/etc/slurm-llnl/slurm.conf"

if [[ -n "\$CTRL_IP" && -n "\$CMP_IP" ]]; then
  sed -i '/# slurm-managed$/d' /etc/hosts || true
  printf '%s %s # slurm-managed\n' "\$CTRL_IP" "\$CTRL_HOST" >> /etc/hosts
  printf '%s %s # slurm-managed\n' "\$CMP_IP" "\$CMP_HOST" >> /etc/hosts
fi

if [[ -f "\$SLURM_CONF" ]]; then
  sed -i -E "s|^SlurmctldHost=.*|SlurmctldHost=\${CTRL_HOST}|; s|^SlurmctldPidFile=.*|SlurmctldPidFile=/run/slurmctld.pid|; s|^SlurmdPidFile=.*|SlurmdPidFile=/run/slurmd.pid|; s|^ProctrackType=.*|ProctrackType=proctrack/linuxproc|; s|^TaskPlugin=.*|TaskPlugin=task/none|" "\$SLURM_CONF"

  NODE_LINE="NodeName=\${CMP_HOST} CPUs=\${NODE_CPUS} Boards=1 SocketsPerBoard=\${NODE_SOCKETS} CoresPerSocket=\${NODE_CORES} ThreadsPerCore=\${NODE_THREADS} RealMemory=\${NODE_REALMEM}"
  if grep -q '^NodeName=' "\$SLURM_CONF"; then
    sed -i -E "s|^NodeName=.*|\${NODE_LINE}|" "\$SLURM_CONF"
  else
    printf '%s\n' "\$NODE_LINE" >> "\$SLURM_CONF"
  fi

  PART_LINE="PartitionName=debug Nodes=\${CMP_HOST} Default=YES MaxTime=01:00:00 State=UP"
  if grep -q '^PartitionName=' "\$SLURM_CONF"; then
    sed -i -E "s|^PartitionName=.*|\${PART_LINE}|" "\$SLURM_CONF"
  else
    printf '%s\n' "\$PART_LINE" >> "\$SLURM_CONF"
  fi
fi

ln -sfn /etc/slurm-llnl/slurm.conf /etc/slurm/slurm.conf || true
mkdir -p /var/spool/slurm-llnl/slurmd /var/log/slurm-llnl
chown -R slurm:slurm /var/spool/slurm-llnl/slurmd /var/log/slurm-llnl || true

# Authorize controller portal key for no-prompt compute SSH checks.
if id -u "\$COMPUTE_SSH_USER" >/dev/null 2>&1; then
  CMP_SSH_HOME="$(getent passwd "\$COMPUTE_SSH_USER" | cut -d: -f6)"
  CMP_AUTH_KEYS="\$CMP_SSH_HOME/.ssh/authorized_keys"
  PORTAL_PUB_KEY="$(printf '%s' "\$PORTAL_PUB_KEY_B64" | base64 -d)"
  install -d -m 700 -o "\$COMPUTE_SSH_USER" -g "\$COMPUTE_SSH_USER" "\$CMP_SSH_HOME/.ssh"
  touch "\$CMP_AUTH_KEYS"
  if ! grep -Fxq "\$PORTAL_PUB_KEY" "\$CMP_AUTH_KEYS"; then
    printf '%s\n' "\$PORTAL_PUB_KEY" >>"\$CMP_AUTH_KEYS"
  fi
  chown "\$COMPUTE_SSH_USER:\$COMPUTE_SSH_USER" "\$CMP_AUTH_KEYS"
  chmod 600 "\$CMP_AUTH_KEYS"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 6818/tcp || true
fi

systemctl enable munge slurmd || true
systemctl restart munge || true
pkill -9 slurmd || true
systemctl reset-failed slurmd || true
systemctl restart slurmd || true
EOF
}

create_controller_userdata_file() {
  local output_file="$1"
  local firstboot_script_b64="$2"
  cat >"$output_file" <<EOF
#cloud-config
preserve_hostname: false
hostname: ${CONTROLLER_HOSTNAME}
fqdn: ${CONTROLLER_HOSTNAME}.${DOMAIN}
manage_etc_hosts: true
timezone: ${TIMEZONE}
write_files:
  - path: /usr/local/sbin/slurm-firstboot-controller.sh
    permissions: "0755"
    owner: root:root
    encoding: b64
    content: ${firstboot_script_b64}
  - path: /etc/slurm-portal/appliance.env
    permissions: "0644"
    owner: root:root
    content: |
      BIND_HOST=0.0.0.0
      BIND_PORT=${PORTAL_PORT}
      CONTROLLER_HOST=${CONTROLLER_HOSTNAME}
      CONTROLLER_IP=${CONTROLLER_IP}
      COMPUTE_HOST=${COMPUTE_HOSTNAME}
      COMPUTE_USER=${COMPUTE_USER}
      POLL_SECONDS=${POLL_SECONDS}
      COMMAND_TIMEOUT_SECONDS=${COMMAND_TIMEOUT_SECONDS}
      INCLUDE_SERVICE_LOGS=false
runcmd:
  - [bash, -lc, "mkdir -p /etc/slurm-portal"]
  - [bash, -lc, "/usr/local/sbin/slurm-firstboot-controller.sh"]
EOF
}

create_compute_userdata_file() {
  local output_file="$1"
  local firstboot_script_b64="$2"
  cat >"$output_file" <<EOF
#cloud-config
preserve_hostname: false
hostname: ${COMPUTE_HOSTNAME}
fqdn: ${COMPUTE_HOSTNAME}.${DOMAIN}
manage_etc_hosts: true
timezone: ${TIMEZONE}
write_files:
  - path: /usr/local/sbin/slurm-firstboot-compute.sh
    permissions: "0755"
    owner: root:root
    encoding: b64
    content: ${firstboot_script_b64}
runcmd:
  - [bash, -lc, "/usr/local/sbin/slurm-firstboot-compute.sh"]
EOF
}

OVA_CONTROLLER=""
OVA_COMPUTE=""
DATACENTER=""
DATASTORE=""
NETWORK=""
CONTROLLER_NETWORK=""
COMPUTE_NETWORK=""
RESOURCE_POOL=""
FOLDER=""
CONTROLLER_VM_NAME=""
COMPUTE_VM_NAME=""
CONTROLLER_HOSTNAME=""
COMPUTE_HOSTNAME=""
DOMAIN="example.local"
TIMEZONE="UTC"
NETWORK_MODE=""
CONTROLLER_IP_CIDR=""
COMPUTE_IP_CIDR=""
GATEWAY=""
DNS_SERVERS=""
CONTROLLER_CPU="4"
CONTROLLER_MEMORY_MB="8192"
CONTROLLER_DISK_GB="80"
COMPUTE_CPU="4"
COMPUTE_MEMORY_MB="8192"
COMPUTE_DISK_GB="80"
COMPUTE_REAL_MEMORY=""
COMPUTE_SOCKETS_PER_BOARD="1"
COMPUTE_CORES_PER_SOCKET=""
COMPUTE_THREADS_PER_CORE="1"
COMPUTE_USER="compute-user"
PORTAL_PORT="18080"
POLL_SECONDS="12"
COMMAND_TIMEOUT_SECONDS="3"
PORTAL_SSH_USER="slurmportal"
REPLACE_EXISTING="false"
POWER_ON="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --controller-ova) OVA_CONTROLLER="$2"; shift 2 ;;
    --compute-ova) OVA_COMPUTE="$2"; shift 2 ;;
    --datacenter) DATACENTER="$2"; shift 2 ;;
    --datastore) DATASTORE="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --controller-network) CONTROLLER_NETWORK="$2"; shift 2 ;;
    --compute-network) COMPUTE_NETWORK="$2"; shift 2 ;;
    --resource-pool) RESOURCE_POOL="$2"; shift 2 ;;
    --folder) FOLDER="$2"; shift 2 ;;
    --controller-vm-name) CONTROLLER_VM_NAME="$2"; shift 2 ;;
    --compute-vm-name) COMPUTE_VM_NAME="$2"; shift 2 ;;
    --controller-hostname) CONTROLLER_HOSTNAME="$2"; shift 2 ;;
    --compute-hostname) COMPUTE_HOSTNAME="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    --dhcp) NETWORK_MODE="dhcp"; shift ;;
    --controller-ip-cidr) NETWORK_MODE="static"; CONTROLLER_IP_CIDR="$2"; shift 2 ;;
    --compute-ip-cidr) NETWORK_MODE="static"; COMPUTE_IP_CIDR="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --dns) DNS_SERVERS="$2"; shift 2 ;;
    --controller-cpu) CONTROLLER_CPU="$2"; shift 2 ;;
    --controller-memory-mb) CONTROLLER_MEMORY_MB="$2"; shift 2 ;;
    --controller-disk-gb) CONTROLLER_DISK_GB="$2"; shift 2 ;;
    --compute-cpu) COMPUTE_CPU="$2"; shift 2 ;;
    --compute-memory-mb) COMPUTE_MEMORY_MB="$2"; shift 2 ;;
    --compute-disk-gb) COMPUTE_DISK_GB="$2"; shift 2 ;;
    --compute-real-memory) COMPUTE_REAL_MEMORY="$2"; shift 2 ;;
    --compute-sockets-per-board) COMPUTE_SOCKETS_PER_BOARD="$2"; shift 2 ;;
    --compute-cores-per-socket) COMPUTE_CORES_PER_SOCKET="$2"; shift 2 ;;
    --compute-threads-per-core) COMPUTE_THREADS_PER_CORE="$2"; shift 2 ;;
    --compute-user) COMPUTE_USER="$2"; shift 2 ;;
    --portal-port) PORTAL_PORT="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --command-timeout-seconds) COMMAND_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --portal-ssh-user) PORTAL_SSH_USER="$2"; shift 2 ;;
    --replace-existing) REPLACE_EXISTING="true"; shift ;;
    --no-power-on) POWER_ON="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd govc
need_cmd jq
need_cmd base64
need_cmd ssh-keygen

[[ -n "${GOVC_URL:-}" ]] || die "Missing GOVC_URL"
[[ -n "${GOVC_USERNAME:-}" ]] || die "Missing GOVC_USERNAME"
[[ -n "${GOVC_PASSWORD:-}" ]] || die "Missing GOVC_PASSWORD"
[[ -n "${GOVC_INSECURE:-}" ]] || die "Missing GOVC_INSECURE"

[[ -f "$OVA_CONTROLLER" ]] || die "Controller OVA not found: $OVA_CONTROLLER"
[[ -f "$OVA_COMPUTE" ]] || die "Compute OVA not found: $OVA_COMPUTE"
[[ -n "$DATACENTER" ]] || die "--datacenter is required"
[[ -n "$DATASTORE" ]] || die "--datastore is required"
[[ -n "$NETWORK" ]] || die "--network is required"
[[ -n "$RESOURCE_POOL" ]] || die "--resource-pool is required"
[[ -n "$CONTROLLER_VM_NAME" ]] || die "--controller-vm-name is required"
[[ -n "$COMPUTE_VM_NAME" ]] || die "--compute-vm-name is required"
[[ -n "$CONTROLLER_HOSTNAME" ]] || die "--controller-hostname is required"
[[ -n "$COMPUTE_HOSTNAME" ]] || die "--compute-hostname is required"

if [[ -z "$CONTROLLER_NETWORK" ]]; then
  CONTROLLER_NETWORK="$NETWORK"
fi
if [[ -z "$COMPUTE_NETWORK" ]]; then
  COMPUTE_NETWORK="$NETWORK"
fi

if [[ -z "$NETWORK_MODE" ]]; then
  die "Specify either --dhcp or static details (--controller-ip-cidr, --compute-ip-cidr, --gateway, --dns)."
fi

if [[ "$NETWORK_MODE" == "static" ]]; then
  [[ -n "$CONTROLLER_IP_CIDR" ]] || die "--controller-ip-cidr is required in static mode"
  [[ -n "$COMPUTE_IP_CIDR" ]] || die "--compute-ip-cidr is required in static mode"
  [[ -n "$GATEWAY" ]] || die "--gateway is required in static mode"
  [[ -n "$DNS_SERVERS" ]] || die "--dns is required in static mode"
fi

CONTROLLER_IP=""
COMPUTE_IP=""
if [[ "$NETWORK_MODE" == "static" ]]; then
  CONTROLLER_IP="$(ip_from_cidr "$CONTROLLER_IP_CIDR")"
  COMPUTE_IP="$(ip_from_cidr "$COMPUTE_IP_CIDR")"
fi

if [[ -z "$COMPUTE_CORES_PER_SOCKET" ]]; then
  COMPUTE_CORES_PER_SOCKET="$COMPUTE_CPU"
fi
if [[ -z "$COMPUTE_REAL_MEMORY" ]]; then
  # Keep memory slightly under VM total to avoid slurmd startup mismatches.
  COMPUTE_REAL_MEMORY="$((COMPUTE_MEMORY_MB - 512))"
fi
if [[ "$COMPUTE_REAL_MEMORY" -lt 512 ]]; then
  die "--compute-real-memory resolved to invalid value: $COMPUTE_REAL_MEMORY"
fi

if [[ "$REPLACE_EXISTING" == "true" ]]; then
  govc vm.destroy -dc "$DATACENTER" "$CONTROLLER_VM_NAME" 2>/dev/null || true
  govc vm.destroy -dc "$DATACENTER" "$COMPUTE_VM_NAME" 2>/dev/null || true
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CTRL_SPEC_RAW="$TMP_DIR/controller-spec.raw.json"
CTRL_SPEC_PATCH="$TMP_DIR/controller-spec.patch.json"
CMP_SPEC_RAW="$TMP_DIR/compute-spec.raw.json"
CMP_SPEC_PATCH="$TMP_DIR/compute-spec.patch.json"
CTRL_META="$TMP_DIR/controller-meta.yaml"
CTRL_USER="$TMP_DIR/controller-user.yaml"
CMP_META="$TMP_DIR/compute-meta.yaml"
CMP_USER="$TMP_DIR/compute-user.yaml"
CTRL_BOOTSTRAP="$TMP_DIR/controller-firstboot.sh"
CMP_BOOTSTRAP="$TMP_DIR/compute-firstboot.sh"
PORTAL_PRIV_KEY="$TMP_DIR/slurmportal_id_ed25519"
PORTAL_PUB_KEY="$TMP_DIR/slurmportal_id_ed25519.pub"

echo "Generating SSH trust keypair for portal probes..."
ssh-keygen -t ed25519 -N "" -C "${PORTAL_SSH_USER}@${CONTROLLER_HOSTNAME}" -f "$PORTAL_PRIV_KEY" >/dev/null
PORTAL_PRIV_KEY_B64="$(b64enc_file "$PORTAL_PRIV_KEY")"
PORTAL_PUB_KEY_B64="$(b64enc_file "$PORTAL_PUB_KEY")"

echo "Importing controller OVA..."
import_vm_from_ova "$OVA_CONTROLLER" "$CONTROLLER_VM_NAME" "$CONTROLLER_NETWORK" "$CTRL_SPEC_RAW" "$CTRL_SPEC_PATCH"
echo "Importing compute OVA..."
import_vm_from_ova "$OVA_COMPUTE" "$COMPUTE_VM_NAME" "$COMPUTE_NETWORK" "$CMP_SPEC_RAW" "$CMP_SPEC_PATCH"

echo "Applying hardware settings..."
configure_vm_hardware "$CONTROLLER_VM_NAME" "$CONTROLLER_CPU" "$CONTROLLER_MEMORY_MB" "$CONTROLLER_DISK_GB"
configure_vm_hardware "$COMPUTE_VM_NAME" "$COMPUTE_CPU" "$COMPUTE_MEMORY_MB" "$COMPUTE_DISK_GB"

echo "Generating first-boot cloud-init payloads..."
create_metadata_file "$CTRL_META" "$CONTROLLER_HOSTNAME" "$CONTROLLER_IP_CIDR" "$GATEWAY" "$DNS_SERVERS"
create_metadata_file "$CMP_META" "$COMPUTE_HOSTNAME" "$COMPUTE_IP_CIDR" "$GATEWAY" "$DNS_SERVERS"
create_controller_firstboot_script "$CTRL_BOOTSTRAP" "$PORTAL_PRIV_KEY_B64" "$PORTAL_PUB_KEY_B64"
create_compute_firstboot_script "$CMP_BOOTSTRAP" "$PORTAL_PUB_KEY_B64"
CTRL_BOOTSTRAP_B64="$(b64enc_file "$CTRL_BOOTSTRAP")"
CMP_BOOTSTRAP_B64="$(b64enc_file "$CMP_BOOTSTRAP")"
create_controller_userdata_file "$CTRL_USER" "$CTRL_BOOTSTRAP_B64"
create_compute_userdata_file "$CMP_USER" "$CMP_BOOTSTRAP_B64"

echo "Injecting cloud-init guestinfo payloads..."
inject_cloud_init "$CONTROLLER_VM_NAME" "$CTRL_META" "$CTRL_USER"
inject_cloud_init "$COMPUTE_VM_NAME" "$CMP_META" "$CMP_USER"

if [[ "$POWER_ON" == "true" ]]; then
  echo "Powering on controller..."
  govc vm.power -dc "$DATACENTER" -on "$CONTROLLER_VM_NAME"
  echo "Powering on compute..."
  govc vm.power -dc "$DATACENTER" -on "$COMPUTE_VM_NAME"
fi

CTRL_IP_DETECTED=""
CMP_IP_DETECTED=""
if [[ "$POWER_ON" == "true" ]]; then
  CTRL_IP_DETECTED="$(govc vm.ip -dc "$DATACENTER" -wait=10m "$CONTROLLER_VM_NAME" || true)"
  CMP_IP_DETECTED="$(govc vm.ip -dc "$DATACENTER" -wait=10m "$COMPUTE_VM_NAME" || true)"
fi

echo
echo "2-node deployment complete."
echo "Controller VM:          $CONTROLLER_VM_NAME"
echo "Compute VM:             $COMPUTE_VM_NAME"
echo "Controller hostname:    $CONTROLLER_HOSTNAME"
echo "Compute hostname:       $COMPUTE_HOSTNAME"
echo "Controller CPU/RAM:     ${CONTROLLER_CPU} vCPU / ${CONTROLLER_MEMORY_MB} MB"
echo "Compute CPU/RAM:        ${COMPUTE_CPU} vCPU / ${COMPUTE_MEMORY_MB} MB"
echo "Compute RealMemory cfg: ${COMPUTE_REAL_MEMORY} MB"
echo "Portal SSH user:        ${PORTAL_SSH_USER}"
echo "Compute SSH user:       ${COMPUTE_USER}"
echo "Network mode:           $NETWORK_MODE"
if [[ "$NETWORK_MODE" == "static" ]]; then
  echo "Controller IP/CIDR:     $CONTROLLER_IP_CIDR"
  echo "Compute IP/CIDR:        $COMPUTE_IP_CIDR"
  echo "Gateway:                $GATEWAY"
  echo "DNS:                    $DNS_SERVERS"
fi
if [[ -n "$CTRL_IP_DETECTED" ]]; then
  echo "Detected controller IP: $CTRL_IP_DETECTED"
fi
if [[ -n "$CMP_IP_DETECTED" ]]; then
  echo "Detected compute IP:    $CMP_IP_DETECTED"
fi
if [[ "$NETWORK_MODE" == "static" ]]; then
  echo "Portal URL:             http://${CONTROLLER_IP}:${PORTAL_PORT}/"
else
  echo "Portal URL:             http://<controller-ip>:${PORTAL_PORT}/"
fi
