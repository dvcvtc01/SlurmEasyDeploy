# Changelog

All notable changes to this project will be documented in this file.

## [0.2.1-alpha] - 2026-03-03
### Changed
- Frontend polling now follows backend-configured `POLL_SECONDS` from the template.
- Service failure logs are redacted by default unless `INCLUDE_SERVICE_LOGS=true`.
- Deployment-generated `/etc/slurm-portal/appliance.env` now sets `INCLUDE_SERVICE_LOGS=false`.
- Example credential placeholders use `<vcenter-secret>` to reduce secret-scan false positives.

### Fixed
- Hardened OVA extraction in `appliance/add-vapp-properties.py` with path and link safety checks.

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
