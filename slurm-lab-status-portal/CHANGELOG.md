# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0-alpha] - 2026-03-03
### Added
- VMware 2-node deploy automation (`appliance/deploy-2node.sh`).
- vApp property injector (`appliance/add-vapp-properties.py`) for interactive OVF deploys.
- Automated SSH trust bootstrap for controller -> compute health probes.
- Alpha release documentation (`ROADMAP.md`, `CONTRIBUTING.md`).

### Changed
- Sanitized repository defaults and examples (hostnames, IPs, usernames).
- Improved README structure for public publishing.
- Updated appliance docs with supported deployment methods.

### Fixed
- `govc import.spec` compatibility by using `GOVC_DATACENTER` for spec generation.

## [0.1.0-alpha] - 2026-03-03
### Added
- Initial FastAPI dashboard with live Slurm and system health endpoints.
- Systemd unit and appliance deployment scripts.