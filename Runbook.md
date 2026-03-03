# Slurm 2-VM Handover Runbook (Ubuntu)

## Topology and roles
- Controller: `slurm-ctrl01` (`10.0.10.10`)
- Compute: `slurm-c01` (`10.0.10.11`)
- `slurmctld` runs **only** on controller.
- `slurmd` runs **only** on compute.
- cgroup plugins are intentionally disabled for this handover:
  - `ProctrackType=proctrack/linuxproc`
  - `TaskPlugin=task/none`

## Prerequisites
- `/etc/hosts` resolves both hostnames on both nodes.
- Munge installed/running on both, and key matches on both.
- Ubuntu packages installed:
  - Controller: `slurmctld slurm-client`
  - Compute: `slurmd slurm-client`
- Config file path: `/etc/slurm-llnl/slurm.conf`
- Symlink path: `/etc/slurm/slurm.conf -> /etc/slurm-llnl/slurm.conf`

## Install commands (if rebuilding)

### Controller (`slurm-ctrl01`)
```bash
sudo apt update
sudo apt install -y munge slurmctld slurm-client
```

### Compute (`slurm-c01`)
```bash
sudo apt update
sudo apt install -y munge slurmd slurm-client
```

## Final `/etc/slurm-llnl/slurm.conf`
```conf
# --------------------
# CORE IDENTIFICATION
# --------------------
ClusterName=slurm-lab
SlurmctldHost=slurm-ctrl01
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid

# --------------------
# AUTH
# --------------------
AuthType=auth/munge
SlurmUser=slurm

# --------------------
# NETWORK PORTS (defaults)
# 6817 slurmctld, 6818 slurmd
# --------------------
SlurmctldPort=6817
SlurmdPort=6818
SrunPortRange=60001-60010

# --------------------
# STATE / SPOOL
# --------------------
StateSaveLocation=/var/spool/slurm-llnl/slurmctld
SlurmdSpoolDir=/var/spool/slurm-llnl/slurmd

# --------------------
# SCHEDULING
# --------------------
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core

# --------------------
# CGROUPS (recommended)
# --------------------
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none

# --------------------
# TIMEOUTS
# --------------------
SlurmctldTimeout=300
SlurmdTimeout=300
ReturnToService=2

# --------------------
# LOGS
# --------------------
SlurmctldLogFile=/var/log/slurm-llnl/slurmctld.log
SlurmdLogFile=/var/log/slurm-llnl/slurmd.log

# --------------------
# NODES
# Replace the next line with EXACT output of: sudo slurmd -C (from compute node)
NodeName=slurm-c01 CPUs=4 Boards=1 SocketsPerBoard=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15996

# --------------------
# PARTITIONS
# --------------------
PartitionName=debug Nodes=slurm-c01 Default=YES MaxTime=01:00:00 State=UP
```

## Configuration and permissions

### Controller (`slurm-ctrl01`)
```bash
sudo mkdir -p /var/spool/slurm-llnl/slurmctld /var/log/slurm-llnl
sudo chown -R slurm:slurm /var/spool/slurm-llnl/slurmctld /var/log/slurm-llnl
sudo ln -sfn /etc/slurm-llnl/slurm.conf /etc/slurm/slurm.conf
```

### Compute (`slurm-c01`)
```bash
sudo mkdir -p /var/spool/slurm-llnl/slurmd /var/log/slurm-llnl
sudo chown -R slurm:slurm /var/spool/slurm-llnl/slurmd /var/log/slurm-llnl
sudo ln -sfn /etc/slurm-llnl/slurm.conf /etc/slurm/slurm.conf
```

## Firewall (only if UFW enabled)

### Controller (`slurm-ctrl01`)
```bash
sudo ufw allow 6817/tcp
sudo ufw allow from 10.0.10.11 to any port 60001:60010 proto tcp
```

### Compute (`slurm-c01`)
```bash
sudo ufw allow 6818/tcp
```

## Service restart order (required)

### 1) Controller first
```bash
sudo systemctl restart slurmctld
sudo systemctl is-active slurmctld
```

### 2) Compute second
```bash
sudo systemctl restart slurmd
sudo systemctl is-active slurmd
```

### If `slurmd` has a stale process
```bash
sudo pkill -9 slurmd
sudo systemctl reset-failed slurmd
sudo systemctl restart slurmd
```

## Hardware sync for NodeName

### Compute (`slurm-c01`)
```bash
sudo slurmd -C
```
- Keep `NodeName=` in `slurm.conf` exactly matched to:
  - Hostname: `slurm-c01` (case-sensitive)
  - `CPUs` and `RealMemory` from `slurmd -C`

## Validation commands

### Controller (`slurm-ctrl01`)
```bash
sinfo -N -l
scontrol show node slurm-c01
```

### Resume node if drained
```bash
scontrol update NodeName=slurm-c01 State=RESUME
```

### Functional test (`srun`)
```bash
srun -N1 -n1 -w slurm-c01 hostname
```

### Functional test (`sbatch`)
```bash
cat > /tmp/sbatch-test.sh <<'EOF'
#!/bin/bash
hostname
date -u +%FT%TZ
EOF
chmod +x /tmp/sbatch-test.sh
jobid=$(sbatch --parsable -N1 -n1 --nodelist=slurm-c01 -o /tmp/sbatch-test-%j.out /tmp/sbatch-test.sh)
scontrol show job "$jobid"
```
- On non-shared storage, `/tmp/sbatch-test-<jobid>.out` will exist on the compute node that ran the job (`slurm-c01`).

## Troubleshooting

### Controller logs
```bash
sudo systemctl status slurmctld --no-pager -l
sudo journalctl -u slurmctld -n 200 --no-pager
sudo tail -n 200 /var/log/slurm-llnl/slurmctld.log
```

### Compute logs
```bash
sudo systemctl status slurmd --no-pager -l
sudo journalctl -u slurmd -n 200 --no-pager
sudo tail -n 200 /var/log/slurm-llnl/slurmd.log
```

### Foreground debug on compute
```bash
sudo systemctl stop slurmd
sudo slurmd -Dvvv -f /etc/slurm-llnl/slurm.conf
```

## Final known-good state from this handover
- `slurmctld`: active (running) on controller.
- `slurmd`: active (running) on compute.
- `sinfo`: node `slurm-c01` in `idle` state.
- `scontrol show node slurm-c01`: `State=IDLE`.
- `srun -N1 -n1 --nodelist=slurm-c01 hostname`: returned `slurm-c01`.
- `sbatch` test completed `ExitCode=0:0` and output file contained `slurm-c01`.
