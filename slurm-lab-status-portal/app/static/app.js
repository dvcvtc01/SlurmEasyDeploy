function configuredPollMs() {
  const raw = document.body?.dataset?.pollSeconds || "12";
  const seconds = Number.parseInt(raw, 10);
  const safeSeconds = Number.isFinite(seconds) && seconds > 0 ? seconds : 12;
  return safeSeconds * 1000;
}

async function fetchJson(url) {
  try {
    const response = await fetch(url, { cache: "no-store" });
    const payload = await response.json();
    return payload;
  } catch (error) {
    return { error: String(error) };
  }
}

function badgeClass(value) {
  const normalized = String(value || "").toLowerCase();
  if (normalized === "active" || normalized === "true" || normalized.includes("ready")) {
    return "good";
  }
  if (normalized === "failed" || normalized === "false" || normalized.includes("not")) {
    return "bad";
  }
  return "neutral";
}

function badge(value) {
  const span = document.createElement("span");
  span.className = `badge ${badgeClass(value)}`;
  span.textContent = String(value);
  return span;
}

function setTableRows(tbodyId, rows, colBuilder) {
  const tbody = document.getElementById(tbodyId);
  tbody.innerHTML = "";
  if (!rows || rows.length === 0) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = 8;
    td.className = "muted";
    td.textContent = "No data";
    tr.appendChild(td);
    tbody.appendChild(tr);
    return;
  }

  rows.forEach((row) => {
    const tr = document.createElement("tr");
    colBuilder(row).forEach((cell) => tr.appendChild(cell));
    tbody.appendChild(tr);
  });
}

function tdText(value) {
  const td = document.createElement("td");
  td.textContent = value === undefined || value === null ? "" : String(value);
  return td;
}

function tdBadge(value) {
  const td = document.createElement("td");
  td.appendChild(badge(value));
  return td;
}

function renderPartitions(payload) {
  const rows = payload.data || [];
  setTableRows("partitions-body", rows, (row) => [
    tdText(row.partition),
    tdText(row.availability),
    tdText(row.time_limit),
    tdText(row.node_count),
    tdBadge(row.state),
    tdText(row.nodes),
  ]);
}

function renderNodes(payload) {
  const rows = payload.data || [];
  setTableRows("nodes-body", rows, (row) => [
    tdText(row.name),
    tdBadge(row.state),
    tdText(row.cpus),
    tdText(row.cpu_alloc),
    tdText(row.real_memory_mb),
    tdText(row.alloc_memory_mb),
    tdText(row.reason),
  ]);
}

function renderJobs(payload) {
  const activeRows = payload.queued_or_running || [];
  const completedRows = payload.completed || [];

  setTableRows("jobs-active-body", activeRows, (row) => [
    tdText(row.job_id),
    tdText(row.user),
    tdBadge(row.state),
    tdText(row.elapsed),
    tdText(row.nodes),
    tdText(row.reason),
    tdText(row.name),
  ]);

  setTableRows("jobs-completed-body", completedRows, (row) => [
    tdText(row.job_id),
    tdText(row.user),
    tdBadge(row.state),
    tdText(row.elapsed),
    tdText(row.node_list),
    tdText(row.name),
  ]);

  const summary = payload.summary || {};
  const meta = document.getElementById("jobs-meta");
  const sacctFlag = payload.sacct_available ? "sacct detected" : "sacct not installed";
  const sacctError = payload.sacct_error ? ` | sacct error: ${payload.sacct_error}` : "";
  meta.textContent = `Queued: ${summary.queued || 0} | Running: ${summary.running || 0} | Completed shown: ${summary.completed || 0} | ${sacctFlag}${sacctError}`;
}

function healthCardHtml(title, payload) {
  if (payload.error && payload.reachable === false) {
    return `
      <h3>${title}</h3>
      <p class="badge bad">UNREACHABLE</p>
      <p class="mono">${payload.error}</p>
    `;
  }

  const mem = payload.memory_mb || {};
  const disk = payload.disk_root || {};
  const interfaces = (payload.interfaces || [])
    .map((item) => `${item.interface} (${item.state}) ${item.addresses}`)
    .join("<br>");

  return `
    <h3>${title}</h3>
    <p><strong>Host:</strong> <span class="mono">${payload.host || ""}</span></p>
    <p><strong>Reachable:</strong> <span class="badge ${badgeClass(payload.reachable)}">${payload.reachable ? "YES" : "NO"}</span></p>
    <p><strong>Uptime:</strong> <span class="mono">${payload.uptime || ""}</span></p>
    <p><strong>Load Avg:</strong> <span class="mono">${(payload.load_average || []).join(", ") || "n/a"}</span></p>
    <p><strong>CPU Count:</strong> <span class="mono">${payload.cpu_count || "n/a"}</span></p>
    <p><strong>RAM (MB):</strong> <span class="mono">${mem.used_mb || "?"} / ${mem.total_mb || "?"}</span></p>
    <p><strong>Disk /:</strong> <span class="mono">${disk.used || "?"} / ${disk.size || "?"} (${disk.use_percent || "?"})</span></p>
    <p><strong>IP:</strong> <span class="mono">${interfaces || "n/a"}</span></p>
    ${payload.error ? `<p class="mono muted">Partial errors: ${payload.error}</p>` : ""}
  `;
}

function renderHealth(controllerPayload, computePayload) {
  const controllerEl = document.getElementById("controller-health");
  const computeEl = document.getElementById("compute-health");
  controllerEl.innerHTML = healthCardHtml("Controller Health", controllerPayload);
  computeEl.innerHTML = healthCardHtml("Compute Health", computePayload);
}

function logExcerpt(entry) {
  if (entry.recent_logs_redacted) {
    return "redacted (set INCLUDE_SERVICE_LOGS=true to include logs)";
  }
  if (!entry.recent_logs || entry.recent_logs.length === 0) {
    return entry.active === "active" ? "none" : (entry.recent_logs_error || entry.active_error || "no logs");
  }
  return entry.recent_logs.slice(-3).join(" | ");
}

function renderServices(payload) {
  setTableRows("services-controller-body", payload.controller_services || [], (row) => [
    tdText(row.service),
    tdBadge(row.active),
    tdText(row.enabled),
    tdText(logExcerpt(row)),
  ]);

  setTableRows("services-compute-body", payload.compute_services || [], (row) => [
    tdText(row.service),
    tdBadge(row.active),
    tdText(row.enabled),
    tdText(logExcerpt(row)),
  ]);

  setTableRows("ports-body", payload.ports || [], (row) => [
    tdText(row.host),
    tdText(row.service),
    tdText(row.expected_port),
    tdBadge(row.listening ? "YES" : "NO"),
  ]);

  const indicators = payload.health_indicators || {};
  const container = document.getElementById("quick-indicators");
  container.innerHTML = "";
  const items = [
    ["Controller Reachable", indicators.controller_reachable],
    ["Compute Reachable", indicators.compute_reachable],
    ["slurmctld Active", indicators.slurmctld_active],
    ["slurmd Active", indicators.slurmd_active],
  ];
  items.forEach(([label, val]) => {
    const item = document.createElement("div");
    item.className = "indicator";
    item.textContent = `${label}: `;
    item.appendChild(badge(val ? "YES" : "NO"));
    container.appendChild(item);
  });

  const caps = payload.capabilities || {};
  const slurmdbdEl = document.getElementById("cap-slurmdbd");
  slurmdbdEl.className = `badge ${badgeClass(caps.detected_slurmdbd || caps.accounting_slurmdbd || "unknown")}`;
  slurmdbdEl.textContent = caps.detected_slurmdbd || caps.accounting_slurmdbd || "UNKNOWN";

  const cgroupEl = document.getElementById("cap-cgroup");
  const plugin = (caps.detected_cgroup_plugin_mode || {});
  cgroupEl.textContent = `Detected plugin mode: ${plugin.status || "UNKNOWN"} (${plugin.proctrack || "?"}, ${plugin.task_plugin || "?"})`;
}

function renderError(tbodyId, message) {
  setTableRows(tbodyId, [{ error: message }], () => [tdText(message)]);
}

async function refresh() {
  const [partitions, nodes, jobs, controllerHealth, computeHealth, services] = await Promise.all([
    fetchJson("/api/slurm/partitions"),
    fetchJson("/api/slurm/nodes"),
    fetchJson("/api/slurm/jobs"),
    fetchJson("/api/health/controller"),
    fetchJson("/api/health/compute"),
    fetchJson("/api/services"),
  ]);

  if (partitions.error) {
    renderError("partitions-body", partitions.error);
  } else {
    renderPartitions(partitions);
  }

  if (nodes.error) {
    renderError("nodes-body", nodes.error);
  } else {
    renderNodes(nodes);
  }

  if (jobs.error) {
    renderError("jobs-active-body", jobs.error);
  } else {
    renderJobs(jobs);
  }

  renderHealth(controllerHealth, computeHealth);

  if (services.error) {
    renderError("services-controller-body", services.error);
    renderError("services-compute-body", services.error);
  } else {
    renderServices(services);
  }

  const stamp = document.getElementById("last-updated");
  const now = new Date();
  stamp.textContent = `Last updated: ${now.toLocaleString()}`;
}

refresh();
setInterval(refresh, configuredPollMs());
