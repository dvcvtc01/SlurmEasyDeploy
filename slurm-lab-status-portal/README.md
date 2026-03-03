# Slurm Lab Status Portal

Status: **alpha**

Read-only FastAPI dashboard for a small Slurm lab cluster. The portal surfaces live scheduler state, host health, and service status using real system commands.

## Highlights
- Live Slurm data (no mocked values): `sinfo`, `squeue`, `scontrol`, optional `sacct`
- Controller and compute health cards
- Service/port checks (`munge`, `slurmctld`, `slurmd`, optional `chrony`)
- JSON API + simple dashboard UI
- VMware appliance scripts for repeatable deployment

## Architecture
- Backend: FastAPI + Jinja2
- Frontend: server-rendered template + vanilla JS polling
- Runtime model: read-only command execution with command timeouts

## API
- `GET /api/slurm/partitions`
- `GET /api/slurm/nodes`
- `GET /api/slurm/jobs`
- `GET /api/health/controller`
- `GET /api/health/compute`
- `GET /api/services`

## Quick Start (Controller VM)
1. Clone/copy this project to `/opt/slurm-portal`.
2. Create a dedicated runtime user.
3. Create venv and install requirements.
4. Install and start the systemd unit.

```bash
sudo useradd -m -s /bin/bash slurmportal || true
sudo mkdir -p /opt/slurm-portal
sudo chown -R slurmportal:slurmportal /opt/slurm-portal

sudo apt update
sudo apt install -y python3-venv python3-pip

sudo -iu slurmportal bash -lc 'cd /opt/slurm-portal && python3 -m venv .venv'
sudo -iu slurmportal bash -lc 'cd /opt/slurm-portal && ./.venv/bin/pip install --upgrade pip'
sudo -iu slurmportal bash -lc 'cd /opt/slurm-portal && ./.venv/bin/pip install -r requirements.txt'

sudo cp /opt/slurm-portal/systemd/slurm-portal.service /etc/systemd/system/slurm-portal.service
sudo systemctl daemon-reload
sudo systemctl enable --now slurm-portal
sudo systemctl status slurm-portal --no-pager -l
```

If UFW is enabled:
```bash
sudo ufw allow 18080/tcp
sudo ufw status
```

Open:
- `http://<controller-ip>:18080/`

## Runtime Configuration
Set values in `/etc/slurm-portal/appliance.env` (loaded by the systemd unit):

```ini
BIND_HOST=0.0.0.0
BIND_PORT=18080
CONTROLLER_HOST=slurm-ctrl01
CONTROLLER_IP=10.0.10.10
COMPUTE_HOST=slurm-c01
COMPUTE_USER=compute-user
POLL_SECONDS=12
COMMAND_TIMEOUT_SECONDS=3
INCLUDE_SERVICE_LOGS=false
```

## Compute SSH Trust
For compute health collection, the portal host needs passwordless SSH from the portal user to the compute user.

If you deploy with `appliance/deploy-2node.sh`, this is automated.

Manual flow:
```bash
sudo -iu slurmportal bash -lc 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
sudo -iu slurmportal bash -lc 'ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519'
sudo -iu slurmportal bash -lc 'ssh-copy-id -i ~/.ssh/id_ed25519.pub <compute-user>@<compute-host>'
sudo -iu slurmportal bash -lc 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=2 <compute-user>@<compute-host> "hostname && uptime"'
```

## VMware Deployment
See [appliance/README.md](./appliance/README.md) for all supported methods:
- Automated 2-node deployment (`deploy-2node.sh`)
- Interactive vSphere OVF wizard (`add-vapp-properties.py`)
- Single-OVA portal deployment (`deploy-ova.sh`)
- OVA build workflow (`build-ova.sh`)

## Validation
```bash
curl -sS http://127.0.0.1:18080/api/slurm/partitions | jq .
curl -sS http://127.0.0.1:18080/api/slurm/nodes | jq .
curl -sS http://127.0.0.1:18080/api/services | jq .
```

## Security Notes
- This project is intentionally read-only and unauthenticated in alpha.
- Service logs are redacted by default (`INCLUDE_SERVICE_LOGS=false`) to reduce data exposure.
- Do not expose it to untrusted networks without adding auth, TLS, and hardening.

## Project Status
- Current state: alpha
- Planned next steps: [ROADMAP.md](./ROADMAP.md)
- Change history: [CHANGELOG.md](./CHANGELOG.md)
- Contribution guide: [CONTRIBUTING.md](./CONTRIBUTING.md)
- License: [LICENSE](./LICENSE)
