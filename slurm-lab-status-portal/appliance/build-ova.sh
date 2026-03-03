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
Export a prepared VMware VM to an OVA appliance.

Requirements:
  - ovftool installed and in PATH

Examples:
  # Export from a local VMX
  ./appliance/build-ova.sh \
    --source "/vmware/portal-template/portal-template.vmx" \
    --output "./dist/slurm-portal-appliance.ova" \
    --name "slurm-portal-appliance"

  # Export from vCenter inventory object
  ./appliance/build-ova.sh \
    --source "vi://<vcenter-user>:<vcenter-password>@<vcenter-fqdn>/DC01/vm/Templates/slurm-portal-template" \
    --output "./dist/slurm-portal-appliance.ova" \
    --name "slurm-portal-appliance"

  # Optional: inject interactive vApp properties after export
  python3 ./appliance/add-vapp-properties.py \
    --input-ova "./dist/slurm-portal-appliance.ova" \
    --output-ova "./dist/slurm-portal-appliance-vapp.ova" \
    --role controller
EOF
}

SOURCE=""
OUTPUT=""
NAME="slurm-portal-appliance"
OVERWRITE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --overwrite) OVERWRITE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd ovftool

[[ -n "$SOURCE" ]] || die "--source is required"
[[ -n "$OUTPUT" ]] || die "--output is required"

mkdir -p "$(dirname "$OUTPUT")"

if [[ -f "$OUTPUT" && "$OVERWRITE" != "true" ]]; then
  die "Output already exists: $OUTPUT (use --overwrite to replace)"
fi

OVF_ARGS=(
  --acceptAllEulas
  --allowExtraConfig
  --skipManifestCheck
  "--name=${NAME}"
)

if [[ "$OVERWRITE" == "true" ]]; then
  OVF_ARGS+=(--overwrite)
fi

echo "Exporting OVA..."
ovftool "${OVF_ARGS[@]}" "$SOURCE" "$OUTPUT"

echo "OVA created: $OUTPUT"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUTPUT"
fi
