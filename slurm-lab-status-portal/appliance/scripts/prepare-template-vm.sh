#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./prepare-template-vm.sh" >&2
  exit 1
fi

echo "Installing prerequisites for VMware + cloud-init..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y cloud-init open-vm-tools qemu-guest-agent

echo "Configuring cloud-init datasource preference for VMware..."
cat >/etc/cloud/cloud.cfg.d/99-vmware-datasource.cfg <<'EOF'
datasource_list: [ VMware, OVF, NoCloud, None ]
EOF

echo "Ensuring slurm-portal runtime env directory exists..."
mkdir -p /etc/slurm-portal
if [[ ! -f /etc/slurm-portal/appliance.env ]]; then
  cat >/etc/slurm-portal/appliance.env <<'EOF'
BIND_HOST=0.0.0.0
BIND_PORT=18080
CONTROLLER_HOST=slurm-ctrl01
CONTROLLER_IP=10.0.10.10
COMPUTE_HOST=slurm-c01
COMPUTE_USER=compute-user
POLL_SECONDS=12
COMMAND_TIMEOUT_SECONDS=3
EOF
fi

echo "Enable services required at boot..."
systemctl enable open-vm-tools || true
systemctl enable qemu-guest-agent || true
systemctl enable slurm-portal || true

echo "Generalize machine before export..."
cloud-init clean --logs
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
rm -rf /tmp/* /var/tmp/*
find /var/log -type f -exec truncate -s 0 {} \;

echo
echo "Template prep complete."
echo "Next steps:"
echo "  1) shutdown -h now"
echo "  2) Export VM to OVA using appliance/build-ova.sh"
