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
Deploy Slurm Lab Status Portal OVA to VMware (vSphere) and customize first boot.

Requirements:
  - govc
  - jq
  - base64
  - GOVC_URL / GOVC_USERNAME / GOVC_PASSWORD / GOVC_INSECURE exported

Example (static IP):
  ./appliance/deploy-ova.sh \
    --ova ./dist/slurm-portal.ova \
    --vm-name customer-slurm-portal01 \
    --datacenter DC01 \
    --datastore datastore1 \
    --network "VM Network" \
    --resource-pool "/DC01/host/Cluster01/Resources" \
    --cpu 4 --memory-mb 8192 --disk-gb 80 \
    --hostname customer-slurm-portal01 \
    --ip-cidr 10.0.10.20/24 \
    --gateway 10.0.10.1 \
    --dns 10.0.10.10,1.1.1.1 \
    --controller-host slurm-ctrl01 \
    --controller-ip 10.0.10.10 \
    --compute-host slurm-c01 \
    --compute-user compute-user

Example (DHCP):
  ./appliance/deploy-ova.sh \
    --ova ./dist/slurm-portal.ova \
    --vm-name customer-slurm-portal01 \
    --datacenter DC01 \
    --datastore datastore1 \
    --network "VM Network" \
    --resource-pool "/DC01/host/Cluster01/Resources" \
    --cpu 4 --memory-mb 8192 --disk-gb 80 \
    --hostname customer-slurm-portal01 \
    --dhcp

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

require_env() {
  local key="$1"
  [[ -n "${!key:-}" ]] || die "Missing required environment variable: $key"
}

OVA_PATH=""
VM_NAME=""
DATACENTER=""
DATASTORE=""
NETWORK=""
RESOURCE_POOL=""
FOLDER=""
CPU="4"
MEMORY_MB="8192"
DISK_GB="80"
HOSTNAME_TARGET=""
DOMAIN="example.local"
TIMEZONE="UTC"
NETWORK_MODE=""
IP_CIDR=""
GATEWAY=""
DNS_SERVERS=""
CONTROLLER_HOST="slurm-ctrl01"
CONTROLLER_IP="10.0.10.10"
COMPUTE_HOST="slurm-c01"
COMPUTE_USER="compute-user"
POLL_SECONDS="12"
COMMAND_TIMEOUT_SECONDS="3"
PORTAL_PORT="18080"
POWER_ON="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ova) OVA_PATH="$2"; shift 2 ;;
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --datacenter) DATACENTER="$2"; shift 2 ;;
    --datastore) DATASTORE="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --resource-pool) RESOURCE_POOL="$2"; shift 2 ;;
    --folder) FOLDER="$2"; shift 2 ;;
    --cpu) CPU="$2"; shift 2 ;;
    --memory-mb) MEMORY_MB="$2"; shift 2 ;;
    --disk-gb) DISK_GB="$2"; shift 2 ;;
    --hostname) HOSTNAME_TARGET="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    --dhcp) NETWORK_MODE="dhcp"; shift ;;
    --ip-cidr) NETWORK_MODE="static"; IP_CIDR="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --dns) DNS_SERVERS="$2"; shift 2 ;;
    --controller-host) CONTROLLER_HOST="$2"; shift 2 ;;
    --controller-ip) CONTROLLER_IP="$2"; shift 2 ;;
    --compute-host) COMPUTE_HOST="$2"; shift 2 ;;
    --compute-user) COMPUTE_USER="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --command-timeout-seconds) COMMAND_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --portal-port) PORTAL_PORT="$2"; shift 2 ;;
    --no-power-on) POWER_ON="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd govc
need_cmd jq
need_cmd base64

require_env GOVC_URL
require_env GOVC_USERNAME
require_env GOVC_PASSWORD
require_env GOVC_INSECURE

[[ -f "$OVA_PATH" ]] || die "OVA file not found: $OVA_PATH"
[[ -n "$VM_NAME" ]] || die "--vm-name is required"
[[ -n "$DATACENTER" ]] || die "--datacenter is required"
[[ -n "$DATASTORE" ]] || die "--datastore is required"
[[ -n "$NETWORK" ]] || die "--network is required"
[[ -n "$RESOURCE_POOL" ]] || die "--resource-pool is required"
[[ -n "$HOSTNAME_TARGET" ]] || die "--hostname is required"

if [[ -z "$NETWORK_MODE" ]]; then
  die "Specify either --dhcp or --ip-cidr/--gateway/--dns for static IP."
fi

if [[ "$NETWORK_MODE" == "static" ]]; then
  [[ -n "$IP_CIDR" ]] || die "--ip-cidr is required in static mode"
  [[ -n "$GATEWAY" ]] || die "--gateway is required in static mode"
  [[ -n "$DNS_SERVERS" ]] || die "--dns is required in static mode"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SPEC_JSON="$TMP_DIR/import-spec.json"
SPEC_PATCHED="$TMP_DIR/import-spec.patched.json"
META_DATA="$TMP_DIR/meta-data.yaml"
USER_DATA="$TMP_DIR/user-data.yaml"

echo "Generating import spec..."
GOVC_DATACENTER="$DATACENTER" govc import.spec "$OVA_PATH" >"$SPEC_JSON"

jq \
  --arg name "$VM_NAME" \
  --arg net "$NETWORK" \
  '
  .Name = $name
  | .NetworkMapping = (.NetworkMapping | map(.Network = $net))
  ' \
  "$SPEC_JSON" >"$SPEC_PATCHED"

echo "Generating cloud-init metadata and userdata..."
if [[ "$NETWORK_MODE" == "dhcp" ]]; then
  cat >"$META_DATA" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${HOSTNAME_TARGET}
network:
  version: 2
  ethernets:
    nic0:
      match:
        name: "e*"
      dhcp4: true
EOF
else
  DNS_YAML="$(join_csv_as_yaml_array "$DNS_SERVERS")"
  cat >"$META_DATA" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${HOSTNAME_TARGET}
network:
  version: 2
  ethernets:
    nic0:
      match:
        name: "e*"
      dhcp4: false
      addresses: ['${IP_CIDR}']
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: ${DNS_YAML}
EOF
fi

cat >"$USER_DATA" <<EOF
#cloud-config
preserve_hostname: false
hostname: ${HOSTNAME_TARGET}
fqdn: ${HOSTNAME_TARGET}.${DOMAIN}
manage_etc_hosts: true
timezone: ${TIMEZONE}
write_files:
  - path: /etc/slurm-portal/appliance.env
    permissions: "0644"
    owner: root:root
    content: |
      BIND_HOST=0.0.0.0
      BIND_PORT=${PORTAL_PORT}
      CONTROLLER_HOST=${CONTROLLER_HOST}
      CONTROLLER_IP=${CONTROLLER_IP}
      COMPUTE_HOST=${COMPUTE_HOST}
      COMPUTE_USER=${COMPUTE_USER}
      POLL_SECONDS=${POLL_SECONDS}
      COMMAND_TIMEOUT_SECONDS=${COMMAND_TIMEOUT_SECONDS}
      INCLUDE_SERVICE_LOGS=false
runcmd:
  - [bash, -lc, "mkdir -p /etc/slurm-portal"]
  - [bash, -lc, "ufw allow ${PORTAL_PORT}/tcp || true"]
  - [bash, -lc, "systemctl daemon-reload"]
  - [bash, -lc, "systemctl enable --now slurm-portal"]
EOF

IMPORT_ARGS=(
  import.ova
  -dc "$DATACENTER"
  -ds "$DATASTORE"
  -pool "$RESOURCE_POOL"
  -options "$SPEC_PATCHED"
)
if [[ -n "$FOLDER" ]]; then
  IMPORT_ARGS+=(-folder "$FOLDER")
fi
IMPORT_ARGS+=("$OVA_PATH")

echo "Importing OVA..."
govc "${IMPORT_ARGS[@]}"

echo "Applying hardware customizations..."
govc vm.change -dc "$DATACENTER" -vm "$VM_NAME" -c "$CPU" -m "$MEMORY_MB"
if [[ -n "$DISK_GB" ]]; then
  govc vm.disk.change -dc "$DATACENTER" -vm "$VM_NAME" -disk.label "Hard disk 1" -size "${DISK_GB}G" || \
    echo "WARN: disk resize failed; adjust disk manually in vSphere if required."
fi

META_B64="$(b64enc_file "$META_DATA")"
USER_B64="$(b64enc_file "$USER_DATA")"

echo "Injecting cloud-init guestinfo..."
govc vm.change -dc "$DATACENTER" -vm "$VM_NAME" \
  -e "guestinfo.metadata=${META_B64}" \
  -e "guestinfo.metadata.encoding=base64" \
  -e "guestinfo.userdata=${USER_B64}" \
  -e "guestinfo.userdata.encoding=base64"

if [[ "$POWER_ON" == "true" ]]; then
  echo "Powering on VM..."
  govc vm.power -dc "$DATACENTER" -on "$VM_NAME"
  echo "Waiting for first reported IP..."
  VM_IP="$(govc vm.ip -dc "$DATACENTER" -wait=10m "$VM_NAME" || true)"
else
  VM_IP=""
fi

echo
echo "Deployment complete."
echo "VM Name:            $VM_NAME"
echo "Datacenter:         $DATACENTER"
echo "Network mode:       $NETWORK_MODE"
if [[ "$NETWORK_MODE" == "static" ]]; then
  echo "Static IP/CIDR:     $IP_CIDR"
fi
if [[ -n "$VM_IP" ]]; then
  echo "Detected VM IP:     $VM_IP"
  echo "Portal URL:         http://${VM_IP}:${PORTAL_PORT}/"
else
  echo "Portal URL:         http://<vm-ip>:${PORTAL_PORT}/"
fi
