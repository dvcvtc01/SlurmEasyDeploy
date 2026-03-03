# Appliance Deployment Guide

Status: **alpha**

This folder contains scripts for packaging and deploying the Slurm Lab Status Portal appliance and a 2-node Slurm lab (controller + compute).

## Prerequisites
- Linux shell with: `bash`, `python3`, `govc`, `jq`, `base64`, `ssh-keygen`
- `ovftool` only for OVA export
- vSphere permissions to import OVAs and modify VM settings

Optional preparation:
```bash
chmod +x appliance/build-ova.sh appliance/deploy-ova.sh appliance/deploy-2node.sh appliance/add-vapp-properties.py appliance/scripts/prepare-template-vm.sh
```

## Method 1: Automated 2-node deployment (recommended)
Script: `appliance/deploy-2node.sh`

What it does:
- Imports controller and compute OVAs
- Applies hostname/network/hardware settings
- Rewrites Slurm topology on first boot
- Configures linuxproc/task-none cgroup workaround
- Automates SSH trust for controller -> compute portal probes

Static IP example:
```bash
./appliance/deploy-2node.sh \
  --controller-ova ./dist/slurm-ctrl01.ova \
  --compute-ova ./dist/slurm-c01.ova \
  --datacenter DC01 \
  --datastore <DATASTORE> \
  --network "<PORTGROUP>" \
  --resource-pool "<RESOURCE_POOL_PATH>" \
  --controller-vm-name slurm-ctrl01 \
  --compute-vm-name slurm-c01 \
  --controller-hostname slurm-ctrl01 \
  --compute-hostname slurm-c01 \
  --controller-cpu 4 --controller-memory-mb 8192 --controller-disk-gb 80 \
  --compute-cpu 8 --compute-memory-mb 16384 --compute-disk-gb 120 \
  --controller-ip-cidr 10.0.10.10/24 \
  --compute-ip-cidr 10.0.10.11/24 \
  --gateway 10.0.10.1 \
  --dns 10.0.10.2,1.1.1.1 \
  --compute-user compute-user \
  --portal-ssh-user slurmportal \
  --domain example.local \
  --timezone UTC
```

DHCP example:
```bash
./appliance/deploy-2node.sh \
  --controller-ova ./dist/slurm-ctrl01.ova \
  --compute-ova ./dist/slurm-c01.ova \
  --datacenter DC01 \
  --datastore <DATASTORE> \
  --network "<PORTGROUP>" \
  --resource-pool "<RESOURCE_POOL_PATH>" \
  --controller-vm-name slurm-ctrl01 \
  --compute-vm-name slurm-c01 \
  --controller-hostname slurm-ctrl01 \
  --compute-hostname slurm-c01 \
  --dhcp
```

## Method 2: Interactive vSphere wizard (vApp properties)
Script: `appliance/add-vapp-properties.py`

Generate wizard-friendly OVAs:
```bash
python3 appliance/add-vapp-properties.py \
  --input-ova ./dist/slurm-ctrl01.ova \
  --output-ova ./dist/slurm-ctrl01-vapp.ova \
  --role controller \
  --hostname slurm-ctrl01 \
  --controller-host slurm-ctrl01 \
  --compute-host slurm-c01 \
  --compute-user compute-user

python3 appliance/add-vapp-properties.py \
  --input-ova ./dist/slurm-c01.ova \
  --output-ova ./dist/slurm-c01-vapp.ova \
  --role compute \
  --hostname slurm-c01 \
  --controller-host slurm-ctrl01 \
  --compute-host slurm-c01
```

Expected wizard groups:
- `General`
- `Network`
- `Slurm`
- `Portal`

## Method 3: Single-OVA portal deployment
Script: `appliance/deploy-ova.sh`

```bash
./appliance/deploy-ova.sh \
  --ova ./dist/slurm-portal-appliance.ova \
  --vm-name slurm-portal01 \
  --datacenter DC01 \
  --datastore <DATASTORE> \
  --network "<PORTGROUP>" \
  --resource-pool "<RESOURCE_POOL_PATH>" \
  --hostname slurm-portal01 \
  --ip-cidr 10.0.10.20/24 \
  --gateway 10.0.10.1 \
  --dns 10.0.10.2,1.1.1.1 \
  --controller-host slurm-ctrl01 \
  --controller-ip 10.0.10.10 \
  --compute-host slurm-c01 \
  --compute-user compute-user \
  --portal-port 18080
```

## Method 4: Build OVA from template VM
1. Prepare template VM:
```bash
sudo bash appliance/scripts/prepare-template-vm.sh
sudo shutdown -h now
```
2. Export OVA:
```bash
./appliance/build-ova.sh \
  --source "vi://<vcenter-user>:<vcenter-password>@<vcenter-fqdn>/<dc>/vm/<template-vm>" \
  --output "./dist/slurm-portal-appliance.ova" \
  --name "slurm-portal-appliance" \
  --overwrite
```

## govc Environment
```bash
cp appliance/govc.env.example appliance/govc.env
vi appliance/govc.env
set -a; source appliance/govc.env; set +a
```

Alternative template file:
```bash
cp appliance/govc.site.env.example appliance/govc.env
```

## Post-deploy Validation
```bash
sinfo
scontrol show node <compute-host>
srun -N1 -n1 -w <compute-host> hostname
curl -sS http://127.0.0.1:18080/api/slurm/nodes | jq .
```

## Notes
- Do not commit built OVAs/VMDKs to source control.
- Keep credentials out of files; use environment variables or secret stores.
