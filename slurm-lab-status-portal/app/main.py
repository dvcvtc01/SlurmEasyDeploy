from __future__ import annotations

import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates


APP_NAME = "Slurm Lab Status Portal"
CONTROLLER_HOST = os.getenv("CONTROLLER_HOST", "slurm-ctrl01")
CONTROLLER_IP = os.getenv("CONTROLLER_IP", "10.0.10.10")
COMPUTE_HOST = os.getenv("COMPUTE_HOST", "slurm-c01")
COMPUTE_USER = os.getenv("COMPUTE_USER", "compute-user")
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "12"))
COMMAND_TIMEOUT_SECONDS = float(os.getenv("COMMAND_TIMEOUT_SECONDS", "3"))
INCLUDE_SERVICE_LOGS = os.getenv("INCLUDE_SERVICE_LOGS", "false").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}

SSH_BASE_ARGS = [
    "ssh",
    "-o",
    "BatchMode=yes",
    "-o",
    "StrictHostKeyChecking=accept-new",
    "-o",
    "ConnectTimeout=2",
    f"{COMPUTE_USER}@{COMPUTE_HOST}",
]

BASE_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

app = FastAPI(title=APP_NAME)
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def run_command(args: list[str], timeout: float = COMMAND_TIMEOUT_SECONDS) -> dict[str, Any]:
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return {
            "ok": result.returncode == 0,
            "returncode": result.returncode,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
            "args": args,
        }
    except FileNotFoundError:
        return {
            "ok": False,
            "returncode": -1,
            "stdout": "",
            "stderr": f"command not found: {args[0]}",
            "args": args,
        }
    except subprocess.TimeoutExpired:
        return {
            "ok": False,
            "returncode": -1,
            "stdout": "",
            "stderr": f"command timed out after {timeout} seconds",
            "args": args,
        }


def run_local(args: list[str], timeout: float = COMMAND_TIMEOUT_SECONDS) -> dict[str, Any]:
    return run_command(args, timeout=timeout)


def run_compute(remote_cmd: str, timeout: float = COMMAND_TIMEOUT_SECONDS) -> dict[str, Any]:
    return run_command(SSH_BASE_ARGS + [remote_cmd], timeout=timeout)


def parse_pipe_output(output: str, fields: list[str]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split("|")
        padded = parts + ([""] * max(0, len(fields) - len(parts)))
        rows.append({field: padded[idx].strip() for idx, field in enumerate(fields)})
    return rows


def parse_key_value_line(line: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    matches = list(re.finditer(r"([A-Za-z][A-Za-z0-9_]*)=", line))
    for index, match in enumerate(matches):
        key = match.group(1)
        value_start = match.end()
        value_end = matches[index + 1].start() if index + 1 < len(matches) else len(line)
        parsed[key] = line[value_start:value_end].strip()
    return parsed


def parse_scontrol_nodes(output: str) -> list[dict[str, Any]]:
    nodes: list[dict[str, Any]] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        kv = parse_key_value_line(line)
        nodes.append(
            {
                "name": kv.get("NodeName", ""),
                "state": kv.get("State", "UNKNOWN"),
                "cpus": kv.get("CPUTot", kv.get("CPUs", "")),
                "cpu_alloc": kv.get("CPUAlloc", ""),
                "real_memory_mb": kv.get("RealMemory", ""),
                "alloc_memory_mb": kv.get("AllocMem", ""),
                "reason": kv.get("Reason", "none"),
                "partitions": kv.get("Partitions", ""),
                "address": kv.get("NodeAddr", ""),
                "hostname": kv.get("NodeHostName", ""),
                "version": kv.get("Version", ""),
                "uptime_start": kv.get("SlurmdStartTime", ""),
            }
        )
    return nodes


def parse_uptime_load(uptime_output: str) -> list[str]:
    match = re.search(r"load average[s]?:\s*(.+)$", uptime_output)
    if not match:
        return []
    return [item.strip() for item in match.group(1).split(",") if item.strip()]


def parse_memory_from_free_m(output: str) -> dict[str, Any]:
    for line in output.splitlines():
        if line.startswith("Mem:"):
            parts = line.split()
            if len(parts) >= 4:
                return {
                    "total_mb": parts[1],
                    "used_mb": parts[2],
                    "free_mb": parts[3],
                }
    return {"total_mb": "", "used_mb": "", "free_mb": ""}


def parse_root_disk_from_df_h(output: str) -> dict[str, Any]:
    lines = [line for line in output.splitlines() if line.strip()]
    if len(lines) < 2:
        return {
            "filesystem": "",
            "size": "",
            "used": "",
            "avail": "",
            "use_percent": "",
            "mount": "",
        }
    parts = lines[1].split()
    if len(parts) < 6:
        return {
            "filesystem": lines[1],
            "size": "",
            "used": "",
            "avail": "",
            "use_percent": "",
            "mount": "",
        }
    return {
        "filesystem": parts[0],
        "size": parts[1],
        "used": parts[2],
        "avail": parts[3],
        "use_percent": parts[4],
        "mount": parts[5],
    }


def parse_ip_br_a(output: str) -> list[dict[str, str]]:
    interfaces: list[dict[str, str]] = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        iface = parts[0]
        if iface == "lo":
            continue
        interfaces.append(
            {
                "interface": iface,
                "state": parts[1],
                "addresses": " ".join(parts[2:]),
            }
        )
    return interfaces


def collect_partitions() -> dict[str, Any]:
    result = run_local(["sinfo", "-h", "-o", "%P|%a|%l|%D|%t|%N"])
    payload: dict[str, Any] = {
        "timestamp": now_iso(),
        "command": "sinfo -h -o %P|%a|%l|%D|%t|%N",
        "data": [],
    }
    if not result["ok"]:
        payload["error"] = result["stderr"] or "sinfo failed"
        return payload
    payload["data"] = parse_pipe_output(
        result["stdout"],
        ["partition", "availability", "time_limit", "node_count", "state", "nodes"],
    )
    return payload


def collect_nodes() -> dict[str, Any]:
    result = run_local(["scontrol", "show", "node", "-o"])
    payload: dict[str, Any] = {
        "timestamp": now_iso(),
        "command": "scontrol show node -o",
        "data": [],
    }
    if not result["ok"]:
        payload["error"] = result["stderr"] or "scontrol failed"
        return payload
    payload["data"] = parse_scontrol_nodes(result["stdout"])
    return payload


def collect_jobs() -> dict[str, Any]:
    jobs_payload: dict[str, Any] = {
        "timestamp": now_iso(),
        "commands": {
            "squeue": "squeue -h -o %i|%u|%T|%M|%D|%R|%j",
            "sacct": "sacct -n -P -X --state=COMPLETED --starttime now-7days -o JobID,User,State,Elapsed,NNodes,NodeList,JobName",
        },
        "queued_or_running": [],
        "completed": [],
        "summary": {"queued": 0, "running": 0, "completed": 0},
        "sacct_available": shutil.which("sacct") is not None,
    }

    squeue_result = run_local(["squeue", "-h", "-o", "%i|%u|%T|%M|%D|%R|%j"])
    if squeue_result["ok"]:
        queue_rows = parse_pipe_output(
            squeue_result["stdout"],
            ["job_id", "user", "state", "elapsed", "nodes", "reason", "name"],
        )
        jobs_payload["queued_or_running"] = queue_rows
        jobs_payload["summary"]["queued"] = sum(
            1 for row in queue_rows if row.get("state", "").upper().startswith("PEND")
        )
        jobs_payload["summary"]["running"] = sum(
            1 for row in queue_rows if row.get("state", "").upper().startswith("RUN")
        )
    else:
        jobs_payload["error"] = squeue_result["stderr"] or "squeue failed"

    if jobs_payload["sacct_available"]:
        sacct_result = run_local(
            [
                "sacct",
                "-n",
                "-P",
                "-X",
                "--state=COMPLETED",
                "--starttime",
                "now-7days",
                "-o",
                "JobID,User,State,Elapsed,NNodes,NodeList,JobName",
            ]
        )
        if sacct_result["ok"]:
            completed_rows = parse_pipe_output(
                sacct_result["stdout"],
                ["job_id", "user", "state", "elapsed", "nodes", "node_list", "name"],
            )
            filtered_rows = [row for row in completed_rows if row.get("job_id") and "." not in row["job_id"]]
            jobs_payload["completed"] = filtered_rows[-10:]
            jobs_payload["summary"]["completed"] = len(jobs_payload["completed"])
        else:
            jobs_payload["sacct_error"] = sacct_result["stderr"] or "sacct failed"
    return jobs_payload


def collect_health(target: str) -> dict[str, Any]:
    remote = target == "compute"
    host_name = COMPUTE_HOST if remote else CONTROLLER_HOST
    host_ip = "" if remote else CONTROLLER_IP

    def execute_local(args: list[str]) -> dict[str, Any]:
        return run_local(args)

    def execute_remote(command: str) -> dict[str, Any]:
        return run_compute(command)

    payload: dict[str, Any] = {
        "timestamp": now_iso(),
        "target": target,
        "host": host_name,
        "ip": host_ip,
        "reachable": True,
        "uptime": "",
        "load_average": [],
        "cpu_count": "",
        "memory_mb": {"total_mb": "", "used_mb": "", "free_mb": ""},
        "disk_root": {
            "filesystem": "",
            "size": "",
            "used": "",
            "avail": "",
            "use_percent": "",
            "mount": "",
        },
        "interfaces": [],
    }

    if remote:
        hostname_result = execute_remote("hostname")
        if not hostname_result["ok"]:
            payload["reachable"] = False
            payload["error"] = hostname_result["stderr"] or "compute host unreachable"
            return payload
        payload["host"] = hostname_result["stdout"] or host_name
    else:
        hostname_result = execute_local(["hostname"])
        if hostname_result["ok"] and hostname_result["stdout"]:
            payload["host"] = hostname_result["stdout"]

    if remote:
        uptime_result = execute_remote("uptime")
        nproc_result = execute_remote("nproc")
        free_result = execute_remote("free -m")
        df_result = execute_remote("df -h /")
        ip_result = execute_remote("ip -br a")
    else:
        uptime_result = execute_local(["uptime"])
        nproc_result = execute_local(["nproc"])
        free_result = execute_local(["free", "-m"])
        df_result = execute_local(["df", "-h", "/"])
        ip_result = execute_local(["ip", "-br", "a"])

    errors: list[str] = []

    if uptime_result["ok"]:
        payload["uptime"] = uptime_result["stdout"]
        payload["load_average"] = parse_uptime_load(uptime_result["stdout"])
    else:
        errors.append(f"uptime: {uptime_result['stderr']}")

    if nproc_result["ok"]:
        payload["cpu_count"] = nproc_result["stdout"]
    else:
        errors.append(f"nproc: {nproc_result['stderr']}")

    if free_result["ok"]:
        payload["memory_mb"] = parse_memory_from_free_m(free_result["stdout"])
    else:
        errors.append(f"free -m: {free_result['stderr']}")

    if df_result["ok"]:
        payload["disk_root"] = parse_root_disk_from_df_h(df_result["stdout"])
    else:
        errors.append(f"df -h /: {df_result['stderr']}")

    if ip_result["ok"]:
        payload["interfaces"] = parse_ip_br_a(ip_result["stdout"])
    else:
        errors.append(f"ip -br a: {ip_result['stderr']}")

    if errors:
        payload["error"] = " | ".join(errors)
    return payload


def service_status(service_name: str, remote: bool) -> dict[str, Any]:
    if remote:
        active_result = run_compute(f"systemctl is-active {service_name}")
        enabled_result = run_compute(f"systemctl is-enabled {service_name}")
    else:
        active_result = run_local(["systemctl", "is-active", service_name])
        enabled_result = run_local(["systemctl", "is-enabled", service_name])

    active_value = active_result["stdout"] or "unknown"
    enabled_value = enabled_result["stdout"] or "unknown"

    entry: dict[str, Any] = {
        "service": service_name,
        "active": active_value,
        "enabled": enabled_value,
    }

    if not active_result["ok"] and active_result["stderr"]:
        entry["active_error"] = active_result["stderr"]
    if not enabled_result["ok"] and enabled_result["stderr"]:
        entry["enabled_error"] = enabled_result["stderr"]

    if active_value not in {"active"}:
        if not INCLUDE_SERVICE_LOGS:
            entry["recent_logs_redacted"] = True
            return entry
        if remote:
            journal_result = run_compute(f"journalctl -u {service_name} -n 20 --no-pager")
        else:
            journal_result = run_local(["journalctl", "-u", service_name, "-n", "20", "--no-pager"])

        if journal_result["ok"]:
            entry["recent_logs"] = journal_result["stdout"].splitlines()[-20:]
        else:
            entry["recent_logs_error"] = journal_result["stderr"] or "journalctl failed"

    return entry


def port_listening(ss_output: str, port: int) -> bool:
    pattern = re.compile(rf":{port}\b")
    for line in ss_output.splitlines():
        if pattern.search(line):
            return True
    return False


def parse_slurm_conf_plugins() -> dict[str, str]:
    proctrack = ""
    task_plugin = ""
    conf_path = Path("/etc/slurm-llnl/slurm.conf")
    if not conf_path.exists():
        return {"proctrack": "", "task_plugin": "", "status": "UNKNOWN"}

    for raw_line in conf_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        if line.startswith("ProctrackType="):
            proctrack = line.split("=", 1)[1].strip()
        if line.startswith("TaskPlugin="):
            task_plugin = line.split("=", 1)[1].strip()

    status = "UNKNOWN"
    if proctrack == "proctrack/linuxproc" and task_plugin == "task/none":
        status = "DISABLED (linuxproc + task/none)"
    elif "cgroup" in proctrack.lower() or "cgroup" in task_plugin.lower():
        status = "ENABLED"

    return {"proctrack": proctrack, "task_plugin": task_plugin, "status": status}


def collect_services() -> dict[str, Any]:
    controller_services = ["munge", "slurmctld", "chrony"]
    compute_services = ["munge", "slurmd", "chrony"]

    controller_entries = [service_status(service, remote=False) for service in controller_services]
    compute_entries = [service_status(service, remote=True) for service in compute_services]

    controller_ss = run_local(["ss", "-ltn"])
    compute_ss = run_compute("ss -ltn")

    controller_ss_out = controller_ss["stdout"] if controller_ss["ok"] else ""
    compute_ss_out = compute_ss["stdout"] if compute_ss["ok"] else ""

    controller_reach = True
    compute_reach_result = run_compute("hostname")
    compute_reach = compute_reach_result["ok"]

    slurmctld_active = next(
        (entry.get("active") for entry in controller_entries if entry["service"] == "slurmctld"),
        "unknown",
    )
    slurmd_active = next(
        (entry.get("active") for entry in compute_entries if entry["service"] == "slurmd"),
        "unknown",
    )

    slurmdbd_installed = shutil.which("slurmdbd") is not None
    slurmdbd_status = "NOT INSTALLED"
    if slurmdbd_installed:
        slurmdbd_active_result = run_local(["systemctl", "is-active", "slurmdbd"])
        slurmdbd_status = "READY" if slurmdbd_active_result["stdout"] == "active" else "INSTALLED (NOT RUNNING)"

    cgroup_status = parse_slurm_conf_plugins()

    return {
        "timestamp": now_iso(),
        "controller_services": controller_entries,
        "compute_services": compute_entries,
        "ports": [
            {
                "host": CONTROLLER_HOST,
                "service": "slurmctld",
                "expected_port": 6817,
                "listening": port_listening(controller_ss_out, 6817),
            },
            {
                "host": COMPUTE_HOST,
                "service": "slurmd",
                "expected_port": 6818,
                "listening": port_listening(compute_ss_out, 6818),
            },
        ],
        "health_indicators": {
            "controller_reachable": controller_reach,
            "compute_reachable": compute_reach,
            "slurmctld_active": slurmctld_active == "active",
            "slurmd_active": slurmd_active == "active",
        },
        "capabilities": {
            "job_submission_page": "NOT IMPLEMENTED",
            "accounting_slurmdbd": slurmdbd_status,
            "cgroup_enforcement": "NOT IMPLEMENTED",
            "rbac_login": "NOT IMPLEMENTED",
            "detected_slurmdbd": slurmdbd_status,
            "detected_cgroup_plugin_mode": cgroup_status,
        },
        "ss_errors": {
            "controller": controller_ss["stderr"] if not controller_ss["ok"] else "",
            "compute": compute_ss["stderr"] if not compute_ss["ok"] else "",
        },
    }


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "app_name": APP_NAME,
            "controller_host": CONTROLLER_HOST,
            "controller_ip": CONTROLLER_IP,
            "compute_host": COMPUTE_HOST,
            "poll_seconds": POLL_SECONDS,
        },
    )


@app.get("/api/slurm/partitions")
def api_slurm_partitions():
    return collect_partitions()


@app.get("/api/slurm/nodes")
def api_slurm_nodes():
    return collect_nodes()


@app.get("/api/slurm/jobs")
def api_slurm_jobs():
    return collect_jobs()


@app.get("/api/health/controller")
def api_health_controller():
    return collect_health("controller")


@app.get("/api/health/compute")
def api_health_compute():
    return collect_health("compute")


@app.get("/api/services")
def api_services():
    return collect_services()
