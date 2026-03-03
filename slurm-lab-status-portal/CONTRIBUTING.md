# Contributing

Thanks for helping improve the Slurm Lab Status Portal.

## Development setup
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Basic checks
```bash
python -m py_compile app/main.py appliance/add-vapp-properties.py
```

## Contribution guidelines
- Keep command execution read-only unless explicitly required.
- Use argument-array subprocess calls (no shell injection).
- Keep command timeouts and error handling intact.
- Update documentation when behavior changes.
- Do not commit secrets, credentials, or generated OVAs/VMDKs.

## Pull request expectations
- Clear summary of change and reason.
- Validation notes (what was tested).
- Backward compatibility considerations.