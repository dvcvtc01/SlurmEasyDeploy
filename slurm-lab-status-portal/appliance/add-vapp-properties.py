#!/usr/bin/env python3
"""Add VMware vApp/OVF properties to an appliance OVA for GUI deploy prompts."""

from __future__ import annotations

import argparse
import hashlib
import tarfile
import tempfile
from pathlib import Path
import xml.etree.ElementTree as ET

OVF_NS = "http://schemas.dmtf.org/ovf/envelope/1"


def qname(local: str) -> str:
    return f"{{{OVF_NS}}}{local}"


def add_category(product_section: ET.Element, name: str) -> None:
    ET.SubElement(product_section, qname("Category")).text = name


def add_property(
    product_section: ET.Element,
    *,
    key: str,
    label: str,
    description: str,
    default_value: str = "",
    user_configurable: bool = True,
    value_type: str = "string",
) -> None:
    prop = ET.SubElement(product_section, qname("Property"))
    prop.set(qname("key"), key)
    prop.set(qname("type"), value_type)
    prop.set(qname("userConfigurable"), "true" if user_configurable else "false")
    prop.set(qname("value"), default_value)
    ET.SubElement(prop, qname("Label")).text = label
    ET.SubElement(prop, qname("Description")).text = description


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def patch_ovf(ovf_path: Path, args: argparse.Namespace) -> None:
    ET.register_namespace("", OVF_NS)
    ET.register_namespace("ovf", OVF_NS)
    ET.register_namespace("cim", "http://schemas.dmtf.org/wbem/wscim/1/common")
    ET.register_namespace(
        "rasd",
        "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData",
    )
    ET.register_namespace("vssd", "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData")
    ET.register_namespace("vmw", "http://www.vmware.com/schema/ovf")
    ET.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

    tree = ET.parse(ovf_path)
    root = tree.getroot()

    virtual_system = root.find(qname("VirtualSystem"))
    if virtual_system is None:
        raise RuntimeError(f"Could not find VirtualSystem in {ovf_path}")

    # Needed for guestinfo.ovfEnv transport in VMware.
    virtual_system.set(qname("transport"), "com.vmware.guestInfo")

    # Replace existing generated section if present.
    for section in list(virtual_system):
        if section.tag != qname("ProductSection"):
            continue
        if section.get(qname("class")) == "slurm.lab.portal":
            virtual_system.remove(section)

    product_section = ET.Element(qname("ProductSection"))
    product_section.set(qname("class"), "slurm.lab.portal")
    ET.SubElement(product_section, qname("Info")).text = "Slurm appliance deployment properties"
    ET.SubElement(product_section, qname("Product")).text = "Slurm Lab Appliance"
    ET.SubElement(product_section, qname("Vendor")).text = "Slurm Lab Community"
    ET.SubElement(product_section, qname("Version")).text = "1.0"

    add_category(product_section, "General")
    add_property(
        product_section,
        key="slurm.role",
        label="Role",
        description="Appliance role.",
        default_value=args.role,
        user_configurable=False,
    )
    add_property(
        product_section,
        key="appliance.hostname",
        label="Hostname",
        description="VM hostname to configure at first boot.",
        default_value=args.hostname,
    )
    add_property(
        product_section,
        key="appliance.domain",
        label="Domain",
        description="DNS domain suffix (for FQDN).",
        default_value=args.domain,
    )
    add_property(
        product_section,
        key="appliance.timezone",
        label="Timezone",
        description="Linux timezone (example: Europe/London).",
        default_value=args.timezone,
    )

    add_category(product_section, "Network")
    add_property(
        product_section,
        key="network.mode",
        label="Network Mode",
        description="dhcp or static",
        default_value=args.network_mode,
    )
    add_property(
        product_section,
        key="network.ip_cidr",
        label="Static IP/CIDR",
        description="Only used when Network Mode is static.",
        default_value=args.ip_cidr,
    )
    add_property(
        product_section,
        key="network.gateway",
        label="Gateway",
        description="Only used when Network Mode is static.",
        default_value=args.gateway,
    )
    add_property(
        product_section,
        key="network.dns",
        label="DNS Servers",
        description="Comma-separated DNS servers.",
        default_value=args.dns,
    )

    add_category(product_section, "Slurm")
    add_property(
        product_section,
        key="slurm.controller_host",
        label="Controller Hostname",
        description="Slurm controller hostname.",
        default_value=args.controller_host,
    )
    add_property(
        product_section,
        key="slurm.controller_ip",
        label="Controller IP",
        description="Slurm controller IP address.",
        default_value=args.controller_ip,
    )
    add_property(
        product_section,
        key="slurm.compute_host",
        label="Compute Hostname",
        description="Slurm compute node hostname.",
        default_value=args.compute_host,
    )
    add_property(
        product_section,
        key="slurm.compute_ip",
        label="Compute IP",
        description="Slurm compute node IP address.",
        default_value=args.compute_ip,
    )

    add_category(product_section, "Portal")
    add_property(
        product_section,
        key="portal.compute_user",
        label="Compute SSH User",
        description="SSH user for controller -> compute health probes.",
        default_value=args.compute_user,
    )
    add_property(
        product_section,
        key="portal.bind_port",
        label="Portal Port",
        description="Portal bind port on controller VM.",
        default_value=str(args.portal_port),
    )

    vh_section = virtual_system.find(qname("VirtualHardwareSection"))
    if vh_section is not None:
        vh_index = list(virtual_system).index(vh_section)
        virtual_system.insert(vh_index, product_section)
    else:
        virtual_system.append(product_section)

    tree.write(ovf_path, encoding="utf-8", xml_declaration=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inject interactive vApp properties into a Slurm appliance OVA."
    )
    parser.add_argument("--input-ova", required=True, help="Source OVA")
    parser.add_argument("--output-ova", required=True, help="Output OVA")
    parser.add_argument(
        "--role",
        required=True,
        choices=["controller", "compute"],
        help="Appliance role",
    )
    parser.add_argument("--hostname", default="", help="Default hostname value")
    parser.add_argument("--domain", default="example.local")
    parser.add_argument("--timezone", default="UTC")
    parser.add_argument("--network-mode", default="dhcp", choices=["dhcp", "static"])
    parser.add_argument("--ip-cidr", default="")
    parser.add_argument("--gateway", default="")
    parser.add_argument("--dns", default="")
    parser.add_argument("--controller-host", default="slurm-ctrl01")
    parser.add_argument("--controller-ip", default="")
    parser.add_argument("--compute-host", default="slurm-c01")
    parser.add_argument("--compute-ip", default="")
    parser.add_argument("--compute-user", default="compute-user")
    parser.add_argument("--portal-port", default=18080, type=int)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_ova = Path(args.input_ova).resolve()
    output_ova = Path(args.output_ova).resolve()
    if not input_ova.is_file():
        raise SystemExit(f"Input OVA not found: {input_ova}")

    if not args.hostname:
        args.hostname = "slurm-ctrl01" if args.role == "controller" else "slurm-c01"

    output_ova.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="vapp-ovf-") as tmp:
        tmp_path = Path(tmp)
        with tarfile.open(input_ova, "r:*") as tf:
            tf.extractall(tmp_path)

        ovf_files = sorted(tmp_path.glob("*.ovf"))
        if len(ovf_files) != 1:
            raise SystemExit(f"Expected exactly one OVF in archive, found {len(ovf_files)}")
        ovf_path = ovf_files[0]
        patch_ovf(ovf_path, args)

        mf_files = sorted(tmp_path.glob("*.mf"))
        if len(mf_files) > 1:
            raise SystemExit(f"Expected at most one manifest file, found {len(mf_files)}")
        mf_path = mf_files[0] if mf_files else None

        if mf_path is not None:
            lines = []
            for item in sorted(list(tmp_path.glob("*.vmdk")) + [ovf_path], key=lambda p: p.name):
                lines.append(f"SHA256({item.name})= {sha256_file(item)}")
            mf_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        ordered_files = [ovf_path.name]
        ordered_files.extend(sorted([p.name for p in tmp_path.glob("*.vmdk")]))
        if mf_path is not None:
            ordered_files.append(mf_path.name)
        extras = sorted(
            [
                p.name
                for p in tmp_path.iterdir()
                if p.is_file() and p.name not in ordered_files
            ]
        )
        ordered_files.extend(extras)

        with tarfile.open(output_ova, "w", format=tarfile.USTAR_FORMAT) as tf:
            for name in ordered_files:
                tf.add(tmp_path / name, arcname=name, recursive=False)

    print(f"Created vApp-enabled OVA: {output_ova}")
    print(f"Role: {args.role}")
    print(f"Default hostname: {args.hostname}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
