/* Virtual Office - Live Dashboard */

var CONFIG = {
  POLL_INTERVAL: 120000,
  MAX_EVENTS: 50,
  API_BASE: ""
};

// --- Agent color map ---
var AGENT_COLORS = {
  "scrum-master": "#3b82f6",   // blue
  "bug-killer": "#ef4444",     // red
  "emailer": "#22c55e"         // green
};
function getAgentColor(name) {
  if (AGENT_COLORS[name]) return AGENT_COLORS[name];
  // Generate a consistent color from name hash for unknown agents
  var hash = 0;
  for (var i = 0; i < name.length; i++) hash = name.charCodeAt(i) + ((hash << 5) - hash);
  var hue = Math.abs(hash) % 360;
  return "hsl(" + hue + ", 70%, 65%)";
}

// --- State ---
var lastDashboardJSON = "";
var lastEventsJSON = "";
var isConnected = false;
var agentConfig = null;
var agentErrors = {};
var latestEvents = [];
var allEvents = [];
var activeGroup = null;
var activeTopTab = "agents";
var lastDashboard = null;

// --- Fetch helpers ---

async function fetchConfig() {
  var response = await fetch(CONFIG.API_BASE + "/api/config", { cache: "no-store" });
  if (!response.ok) throw new Error("HTTP " + response.status);
  return await response.json();
}

async function fetchDashboard() {
  var response = await fetch(CONFIG.API_BASE + "/api/dashboard", { cache: "no-store" });
  if (!response.ok) throw new Error("HTTP " + response.status);
  return await response.json();
}

async function fetchEvents() {
  var response = await fetch(CONFIG.API_BASE + "/api/events", { cache: "no-store" });
  if (!response.ok) throw new Error("HTTP " + response.status);
  return await response.json();
}

async function fetchAllEvents() {
  var response = await fetch(CONFIG.API_BASE + "/api/events?limit=all", { cache: "no-store" });
  if (!response.ok) throw new Error("HTTP " + response.status);
  return await response.json();
}

async function fetchErrors() {
  var response = await fetch(CONFIG.API_BASE + "/api/errors", { cache: "no-store" });
  if (!response.ok) throw new Error("HTTP " + response.status);
  return await response.json();
}

// --- URL helpers ---

function stripOutputPrefix(path) {
  if (path && path.startsWith("output/")) {
    return path.substring("output/".length);
  }
  return path;
}

function getReportHref(lastOutput) {
  if (!lastOutput) return "#";
  var outputPath = stripOutputPrefix(lastOutput);
  return "/api/output/" + outputPath.replace(/\\/g, "/");
}

// --- Time formatting ---

function formatTimeAgo(timestamp) {
  // Detailed PST timestamp: "Mar 22 10:30 PM" for today, "Mar 20 3:15 PM" for older
  if (!timestamp) return "never";
  var d = new Date(timestamp);
  if (isNaN(d.getTime())) return "unknown";
  var opts = { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", hour12: true, timeZone: "America/Los_Angeles" };
  var now = new Date();
  // Add year if not current year
  if (d.getFullYear() !== now.getFullYear()) {
    opts.year = "numeric";
  }
  return d.toLocaleString("en-US", opts) + " PST";
}

function formatTimestamp(timestamp) {
  if (!timestamp) return "";
  var d = new Date(timestamp);
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " " + d.toLocaleTimeString();
}

// --- Normalization helpers ---

function normalizeJobState(raw) {
  return {
    status: raw.status || "idle",
    started: raw.started || null,
    runId: raw.run_id || raw.runId || null,
    runsCompleted: raw.runs_completed || raw.runsCompleted || 0,
    lastCompleted: raw.last_completed || raw.lastCompleted || null,
    lastOutput: raw.lastOutput || raw.last_output || null,
    lastOutputTime: raw.lastOutputTime || raw.last_output_time || null,
    queueDepth: raw.queue_depth || raw.queueDepth || 0
  };
}

// --- Top-level tab navigation ---

function switchTopTab(tabName) {
  activeTopTab = tabName;
  document.querySelectorAll(".top-tab").forEach(function(btn) {
    btn.classList.toggle("active", btn.dataset.tab === tabName);
  });
  document.querySelectorAll(".view").forEach(function(v) {
    v.style.display = "none";
    v.classList.remove("active");
  });
  var target = document.getElementById("view-" + tabName);
  if (target) {
    target.style.display = "";
    target.classList.add("active");
  }

  // Update URL
  var url = new URL(window.location);
  url.searchParams.set("view", tabName);
  if (tabName !== "agents") {
    url.searchParams.delete("tab");
  } else if (activeGroup) {
    url.searchParams.set("tab", activeGroup);
  }
  window.history.replaceState({}, "", url);

  // Load events when switching to events tab
  if (tabName === "events" && allEvents.length === 0) {
    loadAllEvents();
  }
}

// --- Render agents ---

function getAgentStatus(agentData) {
  if (agentData.enabled === false) return "disabled";
  if (agentData.running_job || agentData.status === "busy") return "busy";
  return "idle";
}

function getAgentIcon(agentData) {
  if (agentData.icon) return agentData.icon;
  return "\uD83E\uDD16";
}

function renderAgentCard(name, agentData) {
  var status = getAgentStatus(agentData);
  var icon = getAgentIcon(agentData);

  var card = document.createElement("div");
  card.className = "agent-card " + status;
  card.dataset.agent = name;

  // Header
  var header = document.createElement("div");
  header.className = "card-header";

  var dot = document.createElement("span");
  dot.className = "status-dot " + status;
  header.appendChild(dot);

  var iconSpan = document.createElement("span");
  iconSpan.className = "agent-icon";
  iconSpan.textContent = icon;
  header.appendChild(iconSpan);

  var nameSpan = document.createElement("span");
  nameSpan.className = "agent-name";
  nameSpan.textContent = agentData.display_name || name;
  header.appendChild(nameSpan);

  card.appendChild(header);

  // Status line
  var statusLine = document.createElement("div");
  statusLine.className = "card-status-line";

  if (status === "busy" && agentData.running_job) {
    statusLine.className += " running";
    var runInfo = agentData.running_job;
    var text = "Running: " + (runInfo.job || runInfo.name || "unknown");
    if (runInfo.run) text += " (run " + runInfo.run + ")";
    statusLine.textContent = text;
  } else if (status === "disabled") {
    statusLine.textContent = "Disabled";
  } else if (agentData.last_completed) {
    statusLine.textContent = "Last completed: " + formatTimeAgo(agentData.last_completed);
  } else {
    statusLine.textContent = "Idle";
  }
  card.appendChild(statusLine);

  // Queue badge
  var queueDepth = 0;
  if (agentData.queue && Array.isArray(agentData.queue)) {
    queueDepth = agentData.queue.length;
  } else if (typeof agentData.queue_depth === "number") {
    queueDepth = agentData.queue_depth;
  }

  if (queueDepth > 0) {
    var badge = document.createElement("span");
    badge.className = "queue-badge";
    badge.textContent = queueDepth + " queued";
    card.appendChild(badge);
  }

  // Error warning badge
  var errorCount = 0;
  if (agentErrors[name]) {
    errorCount = agentErrors[name].filter(function(e) { return !e.resolved; }).length;
  }
  if (errorCount > 0) {
    var errorBadge = document.createElement("span");
    errorBadge.className = "error-badge";
    errorBadge.textContent = errorCount + (errorCount === 1 ? " error" : " errors");
    errorBadge.title = "Click to view error details";
    errorBadge.addEventListener("click", function(e) {
      e.stopPropagation();
      showErrorModal(name, agentErrors[name]);
    });
    card.appendChild(errorBadge);
  }

  // Click handler for busy cards
  if (status === "busy") {
    card.style.cursor = "pointer";
    card.addEventListener("click", function() {
      showRunningModal(name, agentData);
    });
  }

  // Jobs list
  var jobs = agentData.jobs || [];
  var activeJobs = [];
  jobs.forEach(function (job) {
    if (job.status === "running" || job.status === "queued" || job.status === "pending" ||
        job.status === "completed" || job.status === "done" ||
        job.status === "failed" || job.status === "error") {
      activeJobs.push(job);
    }
  });

  if (activeJobs.length > 0) {
    var ul = document.createElement("ul");
    ul.className = "job-list";
    activeJobs.forEach(function (job) {
      var li = document.createElement("li");
      li.className = "job-item";

      var statusIcon = document.createElement("span");
      statusIcon.className = "job-status-icon";
      var statusLabel = document.createElement("span");
      statusLabel.className = "job-status-label";

      if (job.status === "running") {
        statusIcon.textContent = "\u25B6";
        statusIcon.classList.add("running");
        statusLabel.textContent = "RUNNING";
        statusLabel.classList.add("running");
        li.classList.add("running");
      } else if (job.status === "completed" || job.status === "done") {
        statusIcon.textContent = "\u2713";
        statusIcon.classList.add("completed");
        statusLabel.textContent = "DONE";
        statusLabel.classList.add("completed");
      } else if (job.status === "failed" || job.status === "error") {
        statusIcon.textContent = "\u2717";
        statusIcon.classList.add("error");
        statusLabel.textContent = "FAILED";
        statusLabel.classList.add("error");
      } else if (job.status === "queued" || job.status === "pending") {
        statusIcon.textContent = "\u25CB";
        statusIcon.classList.add("queued");
        statusLabel.textContent = "QUEUED";
        statusLabel.classList.add("queued");
      }
      li.appendChild(statusIcon);

      var jobName = document.createElement("span");
      jobName.className = "job-name";
      jobName.textContent = job.name || job.job || "unknown";
      li.appendChild(jobName);

      li.appendChild(statusLabel);

      if (job.status === "running") {
        li.style.cursor = "pointer";
        li.addEventListener("click", function(e) {
          e.stopPropagation();
          showRunningModal(name, agentData);
        });
      }

      if (job.lastOutput) {
        var reportLink = document.createElement("a");
        reportLink.className = "report-link";
        reportLink.href = getReportHref(job.lastOutput);
        reportLink.target = "_blank";
        reportLink.textContent = "View";
        reportLink.title = "View latest report" + (job.lastOutputTime ? " (" + formatTimeAgo(job.lastOutputTime) + ")" : "");
        reportLink.addEventListener("click", function(e) { e.stopPropagation(); });
        li.appendChild(reportLink);
      }

      ul.appendChild(li);
    });
    card.appendChild(ul);
  }

  // Capabilities tooltip
  var capabilities = jobs;
  if (capabilities.length > 0) {
    var capCount = document.createElement("div");
    capCount.className = "capabilities-hint";
    capCount.textContent = capabilities.length + (capabilities.length === 1 ? " capability" : " capabilities");

    var tooltip = document.createElement("div");
    tooltip.className = "capabilities-tooltip";

    var tooltipTitle = document.createElement("div");
    tooltipTitle.className = "tooltip-title";
    tooltipTitle.textContent = "Capabilities";
    tooltip.appendChild(tooltipTitle);

    capabilities.forEach(function (job) {
      var item = document.createElement("div");
      item.className = "tooltip-item";

      var jn = document.createElement("span");
      jn.className = "tooltip-job-name";
      jn.textContent = job.name || job.job || "unknown";
      item.appendChild(jn);

      if (job.description) {
        var desc = document.createElement("span");
        desc.className = "tooltip-job-desc";
        desc.textContent = job.description;
        item.appendChild(desc);
      }

      if (job.lastOutput) {
        var capReport = document.createElement("span");
        capReport.className = "tooltip-job-report";
        capReport.textContent = "Last report: " + formatTimeAgo(job.lastOutputTime);
        item.appendChild(capReport);
      }

      tooltip.appendChild(item);
    });

    var capWrapper = document.createElement("div");
    capWrapper.className = "capabilities-wrapper";
    capWrapper.appendChild(capCount);
    capWrapper.appendChild(tooltip);
    card.appendChild(capWrapper);
  }

  // Portal link
  var portalUrl = agentData.portalUrl || null;
  if (!portalUrl && agentConfig && agentConfig.agents) {
    var cfgAgent = agentConfig.agents[name];
    if (cfgAgent) portalUrl = cfgAgent.portalUrl;
  }
  if (portalUrl) {
    var portalLink = document.createElement("a");
    portalLink.className = "card-portal-link";
    portalLink.href = portalUrl;
    portalLink.target = "_blank";
    portalLink.textContent = "Open Portal";
    card.appendChild(portalLink);
  }

  // Card footer - latest report
  var latestOutput = null;
  var latestOutputTime = null;
  jobs.forEach(function(job) {
    if (job.lastOutputTime && (!latestOutputTime || job.lastOutputTime > latestOutputTime)) {
      latestOutputTime = job.lastOutputTime;
      latestOutput = job.lastOutput;
    }
  });
  if (latestOutput) {
    var footer = document.createElement("div");
    footer.className = "card-footer";
    var footerText = document.createElement("span");
    footerText.textContent = "Latest report: " + formatTimeAgo(latestOutputTime);
    footer.appendChild(footerText);
    var footerLink = document.createElement("a");
    footerLink.className = "footer-report-link";
    footerLink.href = getReportHref(latestOutput);
    footerLink.target = "_blank";
    footerLink.textContent = "Open";
    footerLink.addEventListener("click", function(e) { e.stopPropagation(); });
    footer.appendChild(footerLink);
    card.appendChild(footer);
  }

  return card;
}

function mergeConfigAndDashboard(config, dashboard) {
  var merged = {};
  var AGENT_META_KEYS = ["status", "activeJob", "errorCount", "lastError", "updated"];

  if (config && config.agents) {
    Object.keys(config.agents).forEach(function (name) {
      var cfg = config.agents[name];
      merged[name] = {
        display_name: cfg.displayName || name,
        icon: cfg.icon || null,
        description: cfg.description || "",
        portalUrl: cfg.portalUrl || null,
        status: "idle",
        running_job: null,
        last_completed: null,
        queue_depth: 0,
        errorCount: 0,
        lastError: null,
        jobs: []
      };
      if (cfg.jobs) {
        Object.keys(cfg.jobs).forEach(function (jobName) {
          merged[name].jobs.push({
            name: jobName,
            status: cfg.jobs[jobName].enabled === false ? "disabled" : "idle",
            description: cfg.jobs[jobName].description || "",
            enabled: cfg.jobs[jobName].enabled !== false,
            started: null,
            runId: null,
            runsCompleted: 0,
            lastCompleted: null,
            lastOutput: null,
            lastOutputTime: null,
            queueDepth: 0
          });
        });
      }
    });
  }

  if (dashboard && dashboard.agents) {
    Object.keys(dashboard.agents).forEach(function (name) {
      var state = dashboard.agents[name];
      if (!merged[name]) {
        merged[name] = {
          display_name: name,
          status: "idle",
          running_job: null,
          last_completed: null,
          queue_depth: 0,
          errorCount: 0,
          lastError: null,
          jobs: []
        };
      }

      if (typeof state.errorCount === "number") merged[name].errorCount = state.errorCount;
      if (state.lastError) merged[name].lastError = state.lastError;
      if (state.status) merged[name].status = state.status;
      if (state.activeJob) merged[name].running_job = { job: state.activeJob };

      var jobsSource = {};
      if (state.jobs && typeof state.jobs === "object") {
        jobsSource = state.jobs;
      } else {
        Object.keys(state).forEach(function (key) {
          if (AGENT_META_KEYS.indexOf(key) === -1 &&
              typeof state[key] === "object" && state[key] !== null &&
              state[key].status) {
            jobsSource[key] = state[key];
          }
        });
      }

      Object.keys(jobsSource).forEach(function (jobName) {
        var normalized = normalizeJobState(jobsSource[jobName]);

        if (normalized.status === "running") {
          merged[name].status = "busy";
          merged[name].running_job = { job: jobName, run: normalized.runId };
        }

        var found = false;
        merged[name].jobs.forEach(function (j, i) {
          if (j.name === jobName) {
            merged[name].jobs[i].status = normalized.status;
            merged[name].jobs[i].started = normalized.started;
            merged[name].jobs[i].runId = normalized.runId;
            merged[name].jobs[i].runsCompleted = normalized.runsCompleted;
            merged[name].jobs[i].lastCompleted = normalized.lastCompleted;
            merged[name].jobs[i].lastOutput = normalized.lastOutput;
            merged[name].jobs[i].lastOutputTime = normalized.lastOutputTime;
            merged[name].jobs[i].queueDepth = normalized.queueDepth;
            found = true;
          }
        });
        if (!found) {
          merged[name].jobs.push({
            name: jobName,
            status: normalized.status,
            description: "",
            enabled: true,
            started: normalized.started,
            runId: normalized.runId,
            runsCompleted: normalized.runsCompleted,
            lastCompleted: normalized.lastCompleted,
            lastOutput: normalized.lastOutput,
            lastOutputTime: normalized.lastOutputTime,
            queueDepth: normalized.queueDepth
          });
        }

        if (normalized.lastCompleted &&
            (!merged[name].last_completed || normalized.lastCompleted > merged[name].last_completed)) {
          merged[name].last_completed = normalized.lastCompleted;
        }
        if (normalized.queueDepth) {
          merged[name].queue_depth = (merged[name].queue_depth || 0) + normalized.queueDepth;
        }
      });
    });
  }
  return merged;
}

// --- Running Modal ---

function showRunningModal(agentName, agentData) {
  var existing = document.getElementById("running-modal-overlay");
  if (existing) existing.remove();

  var overlay = document.createElement("div");
  overlay.id = "running-modal-overlay";
  overlay.className = "modal-overlay";

  var durationInterval = null;

  function closeModal() {
    if (durationInterval) clearInterval(durationInterval);
    overlay.remove();
  }

  overlay.addEventListener("click", function(e) {
    if (e.target === overlay) closeModal();
  });

  var modal = document.createElement("div");
  modal.className = "running-modal";

  var header = document.createElement("div");
  header.className = "modal-header";
  var title = document.createElement("span");
  title.className = "modal-title";
  var displayName = agentData.display_name || agentName;
  var runningJobName = "unknown";
  if (agentData.running_job) {
    runningJobName = agentData.running_job.job || agentData.running_job.name || "unknown";
  }
  title.textContent = displayName + " - Running: " + runningJobName;
  header.appendChild(title);
  var closeBtn = document.createElement("button");
  closeBtn.className = "modal-close";
  closeBtn.textContent = "X";
  closeBtn.addEventListener("click", closeModal);
  header.appendChild(closeBtn);
  modal.appendChild(header);

  var body = document.createElement("div");
  body.style.overflowY = "auto";
  body.style.flex = "1";

  // Status section
  var statusSection = document.createElement("div");
  statusSection.className = "running-section";
  var statusTitle = document.createElement("div");
  statusTitle.className = "running-section-title";
  statusTitle.textContent = "Status";
  statusSection.appendChild(statusTitle);

  var runId = "";
  var startedTime = null;
  if (agentData.running_job) {
    runId = agentData.running_job.run || "";
  }
  var jobs = agentData.jobs || [];
  jobs.forEach(function(j) {
    if (j.status === "running") {
      if (j.runId) runId = j.runId;
      if (j.started) startedTime = j.started;
    }
  });

  var statusFields = [
    { label: "Status", value: "RUNNING", cls: "status-running" },
    { label: "Run ID", value: runId || "N/A", cls: "" },
    { label: "Started", value: startedTime ? formatTimestamp(startedTime) + " (" + formatTimeAgo(startedTime) + ")" : "N/A", cls: "" }
  ];

  statusFields.forEach(function(f) {
    var row = document.createElement("div");
    row.className = "running-field";
    var label = document.createElement("span");
    label.className = "running-field-label";
    label.textContent = f.label;
    row.appendChild(label);
    var val = document.createElement("span");
    val.className = "running-field-value" + (f.cls ? " " + f.cls : "");
    val.textContent = f.value;
    row.appendChild(val);
    statusSection.appendChild(row);
  });

  // Duration counter
  var durationRow = document.createElement("div");
  durationRow.className = "running-duration";
  function updateDuration() {
    if (startedTime) {
      var elapsed = Math.max(0, Math.floor((Date.now() - new Date(startedTime).getTime()) / 1000));
      var m = Math.floor(elapsed / 60);
      var s = elapsed % 60;
      durationRow.textContent = m + "m " + (s < 10 ? "0" : "") + s + "s";
    } else {
      durationRow.textContent = "--:--";
    }
  }
  updateDuration();
  durationInterval = setInterval(updateDuration, 1000);
  statusSection.appendChild(durationRow);
  body.appendChild(statusSection);

  // Stats section
  var statsSection = document.createElement("div");
  statsSection.className = "running-section";
  var statsTitle = document.createElement("div");
  statsTitle.className = "running-section-title";
  statsTitle.textContent = "Stats";
  statsSection.appendChild(statsTitle);

  var queueDepth = 0;
  if (agentData.queue && Array.isArray(agentData.queue)) {
    queueDepth = agentData.queue.length;
  } else if (typeof agentData.queue_depth === "number") {
    queueDepth = agentData.queue_depth;
  }

  var totalRuns = 0;
  var lastCompleted = null;
  var lastOutputFile = null;
  var lastOutputTime = null;
  jobs.forEach(function(j) {
    if (j.runsCompleted) {
      totalRuns += (typeof j.runsCompleted === "number" ? j.runsCompleted : 0);
    }
    if (j.lastCompleted && (!lastCompleted || j.lastCompleted > lastCompleted)) {
      lastCompleted = j.lastCompleted;
    }
    if (j.lastOutputTime && (!lastOutputTime || j.lastOutputTime > lastOutputTime)) {
      lastOutputTime = j.lastOutputTime;
      lastOutputFile = j.lastOutput;
    }
  });

  var statsFields = [
    { label: "Queue Depth", value: String(queueDepth) },
    { label: "Total Runs", value: String(totalRuns) },
    { label: "Last Completed", value: lastCompleted ? formatTimeAgo(lastCompleted) : "never" }
  ];

  statsFields.forEach(function(f) {
    var row = document.createElement("div");
    row.className = "running-field";
    var label = document.createElement("span");
    label.className = "running-field-label";
    label.textContent = f.label;
    row.appendChild(label);
    var val = document.createElement("span");
    val.className = "running-field-value";
    val.textContent = f.value;
    row.appendChild(val);
    statsSection.appendChild(row);
  });

  // Last Output row
  var outputRow = document.createElement("div");
  outputRow.className = "running-field";
  var outputLabel = document.createElement("span");
  outputLabel.className = "running-field-label";
  outputLabel.textContent = "Last Output";
  outputRow.appendChild(outputLabel);
  if (lastOutputFile) {
    var outputLink = document.createElement("a");
    outputLink.href = getReportHref(lastOutputFile);
    outputLink.target = "_blank";
    outputLink.textContent = "View Report";
    outputLink.style.color = "#2563eb";
    outputLink.style.fontWeight = "600";
    outputLink.style.fontSize = "0.82rem";
    outputLink.style.textDecoration = "none";
    outputRow.appendChild(outputLink);
  } else {
    var outputDash = document.createElement("span");
    outputDash.className = "running-field-value";
    outputDash.textContent = "\u2014";
    outputRow.appendChild(outputDash);
  }
  statsSection.appendChild(outputRow);
  body.appendChild(statsSection);

  // Recent Events section
  var eventsSection = document.createElement("div");
  eventsSection.className = "running-section";
  var eventsTitle = document.createElement("div");
  eventsTitle.className = "running-section-title";
  eventsTitle.textContent = "Recent Events";
  eventsSection.appendChild(eventsTitle);

  var eventsContainer = document.createElement("div");
  eventsContainer.className = "running-events";

  var agentEvents = latestEvents.filter(function(evt) {
    return evt.agent === agentName;
  });

  var recentEvents = agentEvents.slice(-10);
  if (recentEvents.length === 0) {
    var noEvt = document.createElement("div");
    noEvt.style.color = "#9ca3af";
    noEvt.style.fontStyle = "italic";
    noEvt.style.padding = "0.4rem";
    noEvt.textContent = "No recent events for this agent";
    eventsContainer.appendChild(noEvt);
  } else {
    recentEvents.forEach(function(evt) {
      var row = document.createElement("div");
      row.className = "running-event-row";

      var time = document.createElement("span");
      time.className = "running-event-time";
      time.textContent = formatTimestamp(evt.timestamp || evt.ts || evt.time);
      row.appendChild(time);

      var type = document.createElement("span");
      type.className = "running-event-type";
      type.textContent = evt.type || evt.event || "info";
      row.appendChild(type);

      var detail = document.createElement("span");
      detail.className = "running-event-detail";
      var detailText = evt.job || "";
      if (evt.message) detailText = evt.message;
      else if (evt.detail) detailText = evt.detail;
      else if (evt.msg) detailText = evt.msg;
      detail.textContent = detailText;
      detail.title = detailText;
      row.appendChild(detail);

      eventsContainer.appendChild(row);
    });
  }

  eventsSection.appendChild(eventsContainer);
  body.appendChild(eventsSection);

  modal.appendChild(body);
  overlay.appendChild(modal);
  document.body.appendChild(overlay);
}

// --- Error Modal ---

function showErrorModal(agentName, errors) {
  var existing = document.getElementById("error-modal-overlay");
  if (existing) existing.remove();

  var overlay = document.createElement("div");
  overlay.id = "error-modal-overlay";
  overlay.className = "modal-overlay";
  overlay.addEventListener("click", function(e) {
    if (e.target === overlay) overlay.remove();
  });

  var modal = document.createElement("div");
  modal.className = "error-modal";

  var header = document.createElement("div");
  header.className = "modal-header";
  var title = document.createElement("span");
  title.className = "modal-title";
  title.textContent = (agentName) + " - Error Log";
  header.appendChild(title);
  var closeBtn = document.createElement("button");
  closeBtn.className = "modal-close";
  closeBtn.textContent = "X";
  closeBtn.addEventListener("click", function() { overlay.remove(); });
  header.appendChild(closeBtn);
  modal.appendChild(header);

  var list = document.createElement("div");
  list.className = "error-list";

  errors.forEach(function(err) {
    var row = document.createElement("div");
    row.className = "error-row" + (err.resolved ? " resolved" : "");

    var summary = document.createElement("div");
    summary.className = "error-summary";
    summary.addEventListener("click", function() {
      var detail = row.querySelector(".error-detail");
      detail.style.display = detail.style.display === "none" ? "block" : "none";
    });

    var levelBadge = document.createElement("span");
    levelBadge.className = "error-level " + (err.level || "error");
    levelBadge.textContent = (err.level || "ERROR").toUpperCase();
    summary.appendChild(levelBadge);

    var jobSpan = document.createElement("span");
    jobSpan.className = "error-job";
    jobSpan.textContent = err.job || "unknown";
    summary.appendChild(jobSpan);

    var timeSpan = document.createElement("span");
    timeSpan.className = "error-time";
    timeSpan.textContent = formatTimeAgo(err.ts);
    summary.appendChild(timeSpan);

    var summaryText = document.createElement("span");
    summaryText.className = "error-summary-text";
    summaryText.textContent = err.summary || "";
    summary.appendChild(summaryText);

    row.appendChild(summary);

    var detail = document.createElement("div");
    detail.className = "error-detail";
    detail.style.display = "none";

    var detailItems = [
      { label: "Detail", value: err.detail || "No additional details" },
      { label: "Log", value: err.logPath || "N/A" },
      { label: "Duration", value: err.duration || "N/A" },
      { label: "Exit Code", value: (err.exitCode !== undefined ? err.exitCode : "N/A") },
      { label: "Run ID", value: err.runId || "N/A" },
      { label: "Time", value: err.ts || "N/A" }
    ];

    detailItems.forEach(function(item) {
      var line = document.createElement("div");
      line.className = "detail-line";
      var label = document.createElement("span");
      label.className = "detail-label";
      label.textContent = item.label + ": ";
      line.appendChild(label);
      var value = document.createElement("span");
      value.className = "detail-value";
      value.textContent = String(item.value);
      line.appendChild(value);
      detail.appendChild(line);
    });

    if (!err.resolved) {
      var resolveBtn = document.createElement("button");
      resolveBtn.className = "resolve-btn";
      resolveBtn.textContent = "Mark Resolved";
      resolveBtn.addEventListener("click", function() {
        row.classList.add("resolved");
        err.resolved = true;
        var badge2 = document.querySelector("[data-agent='" + agentName + "'] .error-badge");
        if (badge2) {
          var remaining = errors.filter(function(e) { return !e.resolved; }).length;
          if (remaining === 0) { badge2.remove(); }
          else { badge2.textContent = remaining + (remaining === 1 ? " error" : " errors"); }
        }
      });
      detail.appendChild(resolveBtn);
    }

    row.appendChild(detail);
    list.appendChild(row);
  });

  modal.appendChild(list);
  overlay.appendChild(modal);
  document.body.appendChild(overlay);
}

// --- Agent group tabs ---

function getAgentGroup(name) {
  if (agentConfig && agentConfig.agents && agentConfig.agents[name] && agentConfig.agents[name].group) {
    return agentConfig.agents[name].group;
  }
  return "Agents";
}

function renderAgentTabs(agents) {
  var tabsEl = document.getElementById("agent-tabs");
  if (!tabsEl) return [];

  var groups = {};
  var groupOrder = [];
  Object.keys(agents).forEach(function(name) {
    var group = getAgentGroup(name);
    if (!groups[group]) {
      groups[group] = [];
      groupOrder.push(group);
    }
    groups[group].push(name);
  });

  if (!activeGroup || !groups[activeGroup]) activeGroup = groupOrder[0];

  tabsEl.innerHTML = "";
  groupOrder.forEach(function(groupName) {
    var tab = document.createElement("button");
    tab.className = "agent-tab" + (groupName === activeGroup ? " active" : "");
    tab.textContent = groupName + " (" + groups[groupName].length + ")";
    tab.addEventListener("click", function() {
      activeGroup = groupName;
      var url = new URL(window.location);
      url.searchParams.set("tab", groupName);
      window.history.replaceState({}, "", url);
      renderAgents(lastDashboard);
    });
    tabsEl.appendChild(tab);
  });

  return groups[activeGroup] || [];
}

// --- Mission Control: Stats ---

function computeStats(events, agents) {
  var now = new Date();
  var todayMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();

  // Get Monday of current week at midnight
  var dayOfWeek = now.getDay();
  var daysSinceMonday = (dayOfWeek === 0) ? 6 : (dayOfWeek - 1);
  var mondayMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysSinceMonday).getTime();

  var completedToday = 0;
  var completedWeek = 0;
  var failedToday = 0;
  var failedWeek = 0;

  var completedOrFailedRunIds = {};
  var startedEvents = [];
  var twoHoursAgo = now.getTime() - (2 * 60 * 60 * 1000);

  if (Array.isArray(events)) {
    events.forEach(function(evt) {
      var evtType = evt.event || evt.type || "";
      var evtTime = new Date(evt.timestamp || evt.ts || evt.time).getTime();
      if (isNaN(evtTime)) return;

      var runId = (evt.details && evt.details.run_id) ? evt.details.run_id : null;

      if (evtType === "completed") {
        if (evtTime >= todayMidnight) completedToday++;
        if (evtTime >= mondayMidnight) completedWeek++;
        if (runId) completedOrFailedRunIds[runId] = true;
      } else if (evtType === "failed") {
        if (evtTime >= todayMidnight) failedToday++;
        if (evtTime >= mondayMidnight) failedWeek++;
        if (runId) completedOrFailedRunIds[runId] = true;
      } else if (evtType === "started") {
        startedEvents.push({ runId: runId, time: evtTime });
      }
    });
  }

  // Count stalled jobs: started with no matching completed/failed and older than 2 hours
  var stalledToday = 0;
  var stalledWeek = 0;
  startedEvents.forEach(function(se) {
    if (se.runId && !completedOrFailedRunIds[se.runId] && se.time < twoHoursAgo) {
      if (se.time >= todayMidnight) stalledToday++;
      if (se.time >= mondayMidnight) stalledWeek++;
    }
  });

  // Include stalled in failed totals
  var explicitFailedToday = failedToday;
  var explicitFailedWeek = failedWeek;
  failedToday += stalledToday;
  failedWeek += stalledWeek;

  var agentsActive = 0;
  var agentsTotal = 0;
  if (agents && typeof agents === "object") {
    var agentNames = Object.keys(agents);
    agentsTotal = agentNames.length;
    agentNames.forEach(function(name) {
      if (agents[name].status === "busy") agentsActive++;
    });
  }

  var elCompletedToday = document.getElementById("stat-completed-today");
  var elCompletedWeek = document.getElementById("stat-completed-week");
  var elFailedToday = document.getElementById("stat-failed-today");
  var elFailedWeek = document.getElementById("stat-failed-week");
  var elAgentsActive = document.getElementById("stat-agents-active");
  var elAgentsTotal = document.getElementById("stat-agents-total");
  var elHeartbeat = document.getElementById("stat-heartbeat");
  var elHeartbeatTime = document.getElementById("stat-heartbeat-time");

  if (elCompletedToday) elCompletedToday.textContent = completedToday + " today";
  if (elCompletedWeek) elCompletedWeek.textContent = completedWeek + " this week";
  if (elFailedToday) elFailedToday.textContent = failedToday + " today" + (stalledToday > 0 ? " (" + explicitFailedToday + " failed + " + stalledToday + " stalled)" : "");
  if (elFailedWeek) elFailedWeek.textContent = failedWeek + " this week" + (stalledWeek > 0 ? " (" + explicitFailedWeek + " failed + " + stalledWeek + " stalled)" : "");
  if (elAgentsActive) elAgentsActive.textContent = String(agentsActive);
  if (elAgentsTotal) elAgentsTotal.textContent = agentsTotal + " total";
  if (elHeartbeat) elHeartbeat.textContent = isConnected ? "Operational" : "Disconnected";
  if (elHeartbeatTime) elHeartbeatTime.textContent = isConnected ? new Date().toLocaleTimeString() : "--";
}

// --- Mission Control: Agent List (left column) ---

function renderAgentList(agents) {
  var listEl = document.getElementById("agent-list");
  if (!listEl) return;
  listEl.innerHTML = "";

  var busyCount = 0;
  var agentNames = Object.keys(agents);

  agentNames.forEach(function(name) {
    var agentData = agents[name];
    var status = getAgentStatus(agentData);
    if (status === "busy") busyCount++;

    var card = document.createElement("div");
    card.className = "agent-list-card " + status;
    card.dataset.agent = name;

    // Top row: name + status badge
    var topRow = document.createElement("div");
    topRow.className = "agent-list-top";

    var nameEl = document.createElement("span");
    nameEl.className = "agent-list-name";
    nameEl.textContent = agentData.display_name || name;
    nameEl.style.color = getAgentColor(name);
    topRow.appendChild(nameEl);

    var statusBadge = document.createElement("span");
    if (status === "busy") {
      statusBadge.className = "agent-list-status working";
      statusBadge.textContent = "Working";
    } else if (status === "disabled") {
      statusBadge.className = "agent-list-status disabled-status";
      statusBadge.textContent = "Disabled";
    } else {
      statusBadge.className = "agent-list-status idle-status";
      statusBadge.textContent = "Idle";
    }
    topRow.appendChild(statusBadge);
    card.appendChild(topRow);

    // Activity line
    var activityLine = document.createElement("div");
    activityLine.className = "agent-list-activity";

    if (status === "busy" && agentData.running_job) {
      var runJobName = agentData.running_job.job || agentData.running_job.name || "unknown";
      var actText = "Running: " + runJobName;
      // Calculate elapsed time
      var startedTime = null;
      var agentJobs = agentData.jobs || [];
      agentJobs.forEach(function(j) {
        if (j.status === "running" && j.started) {
          startedTime = j.started;
        }
      });
      if (startedTime) {
        var elapsed = Math.max(0, Math.floor((Date.now() - new Date(startedTime).getTime()) / 1000));
        var em = Math.floor(elapsed / 60);
        var es = elapsed % 60;
        actText += " (" + em + "m " + (es < 10 ? "0" : "") + es + "s)";
      }
      activityLine.textContent = actText;
    } else if (agentData.last_completed) {
      // Find the last completed job's description
      var lastJobDesc = "";
      var agentJobs2 = agentData.jobs || [];
      agentJobs2.forEach(function(j) {
        if (j.lastCompleted && j.lastCompleted === agentData.last_completed && j.description) {
          lastJobDesc = j.description;
        }
      });
      if (lastJobDesc) {
        activityLine.textContent = lastJobDesc + " \u2022 " + formatTimeAgo(agentData.last_completed);
      } else {
        activityLine.textContent = "Last completed " + formatTimeAgo(agentData.last_completed);
      }
    } else {
      activityLine.textContent = agentData.description || "No recent activity";
    }
    card.appendChild(activityLine);

    // Timestamp line
    var tsLine = document.createElement("div");
    tsLine.className = "agent-list-timestamp";
    if (agentData.last_completed) {
      tsLine.textContent = formatTimestamp(agentData.last_completed);
    } else {
      tsLine.textContent = "";
    }
    card.appendChild(tsLine);

    // Click handler
    if (status === "busy") {
      card.style.cursor = "pointer";
      card.addEventListener("click", function() {
        showRunningModal(name, agentData);
      });
    }

    listEl.appendChild(card);
  });

  var badgeEl = document.getElementById("active-agents-badge");
  if (badgeEl) badgeEl.textContent = busyCount + " busy";
}

// --- Mission Control: Activity Feed (right column) ---

function renderActivityFeed(events) {
  var feedEl = document.getElementById("activity-feed");
  if (!feedEl) return;
  feedEl.innerHTML = "";

  if (!Array.isArray(events) || events.length === 0) {
    var empty = document.createElement("div");
    empty.className = "placeholder-message";
    empty.textContent = "No recent events";
    feedEl.appendChild(empty);
    return;
  }

  // Take last 15, newest first
  var recent = events.slice(-15).reverse();

  recent.forEach(function(evt) {
    var entry = document.createElement("div");
    entry.className = "activity-entry";

    var ts = document.createElement("span");
    ts.className = "activity-timestamp";
    ts.textContent = formatTimeAgo(evt.timestamp || evt.ts || evt.time);
    entry.appendChild(ts);

    var evtType = evt.event || evt.type || "info";
    var typeBadge = document.createElement("span");
    typeBadge.className = "activity-type-badge " + eventTypeClass(evtType);
    typeBadge.textContent = evtType;
    entry.appendChild(typeBadge);

    var desc = document.createElement("span");
    desc.className = "activity-description";
    var agentName = evt.agent || "unknown";
    var jobName = evt.job || "unknown";
    var details = evt.details || {};

    var agentSpan = document.createElement("span");
    agentSpan.style.color = getAgentColor(agentName);
    agentSpan.style.fontWeight = "600";
    agentSpan.textContent = agentName;

    var restText = "";
    if (evtType === "completed") {
      var durationStr = details.duration ? details.duration : "";
      var exitStr = details.exit_code !== undefined ? "exit:" + details.exit_code : "";
      var parts = [durationStr, exitStr].filter(function(p) { return p; });
      restText = " completed " + jobName + (parts.length ? " (" + parts.join(", ") + ")" : "");
    } else if (evtType === "started") {
      var runStr = details.run_id ? "run:" + details.run_id : "";
      restText = " started " + jobName + (runStr ? " (" + runStr + ")" : "");
    } else if (evtType === "failed") {
      var fParts = [];
      if (details.exit_code !== undefined) fParts.push("exit:" + details.exit_code);
      if (details.duration) fParts.push(details.duration);
      restText = " failed " + jobName + (fParts.length ? " (" + fParts.join(", ") + ")" : "");
    } else if (evtType === "queued") {
      var qStr = details.queue_depth !== undefined ? "queue:" + details.queue_depth : "";
      restText = " queued " + jobName + (qStr ? " (" + qStr + ")" : "");
    } else if (evtType === "stale_lock_cleared") {
      desc.appendChild(document.createTextNode("Stale lock cleared for "));
      desc.appendChild(agentSpan);
      desc.appendChild(document.createTextNode("/" + jobName));
      entry.appendChild(desc);
      feedEl.appendChild(entry);
      return;
    } else if (evtType === "schedule_registered") {
      desc.appendChild(document.createTextNode("Schedule registered for "));
      desc.appendChild(agentSpan);
      desc.appendChild(document.createTextNode("/" + jobName));
      entry.appendChild(desc);
      feedEl.appendChild(entry);
      return;
    } else if (evtType === "schedule_removed") {
      desc.appendChild(document.createTextNode("Schedule removed for "));
      desc.appendChild(agentSpan);
      desc.appendChild(document.createTextNode("/" + jobName));
      entry.appendChild(desc);
      feedEl.appendChild(entry);
      return;
    } else {
      restText = " " + evtType + " " + jobName;
    }

    desc.appendChild(agentSpan);
    desc.appendChild(document.createTextNode(restText));

    entry.appendChild(desc);
    feedEl.appendChild(entry);
  });
}

// --- Render agents (main view) ---

function renderAgents(dashboard) {
  lastDashboard = dashboard;
  var agents = mergeConfigAndDashboard(agentConfig, dashboard);
  var agentNames = Object.keys(agents);

  if (agentNames.length === 0) {
    var listEl = document.getElementById("agent-list");
    if (listEl) listEl.innerHTML = '<div class="placeholder-message">No agents configured</div>';
    return;
  }

  var visibleNames = renderAgentTabs(agents);

  // Build filtered agents object for the active group
  var filteredAgents = {};
  visibleNames.forEach(function(name) {
    filteredAgents[name] = agents[name];
  });

  // Render Mission Control left column
  renderAgentList(filteredAgents);

  // Render Mission Control right column — filtered to active group's agents
  var groupAgentNames = visibleNames;
  var groupEvents = latestEvents.filter(function(evt) {
    var evtAgent = evt.agent || "";
    return groupAgentNames.indexOf(evtAgent) !== -1;
  });
  renderActivityFeed(groupEvents);

  // Compute stats using all agents (not just filtered)
  computeStats(latestEvents, agents);
}

// --- Event Log (full page) ---

async function loadAllEvents() {
  try {
    allEvents = await fetchAllEvents();
    populateAgentFilter();
    renderFilteredEvents();
  } catch (e) {
    console.warn("Failed to load all events:", e.message);
  }
}

function populateAgentFilter() {
  var select = document.getElementById("filter-agent");
  if (!select) return;
  var agents = {};
  allEvents.forEach(function(evt) {
    if (evt.agent) agents[evt.agent] = true;
  });
  // Preserve current selection
  var current = select.value;
  // Clear options after "All Agents"
  while (select.options.length > 1) select.remove(1);
  Object.keys(agents).sort().forEach(function(name) {
    var opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    select.appendChild(opt);
  });
  select.value = current;
}

function getFilteredEvents() {
  var agentFilter = document.getElementById("filter-agent").value;
  var typeFilter = document.getElementById("filter-event-type").value;
  var timeFilter = document.getElementById("filter-time").value;

  var now = Date.now();
  var timeMs = 0;
  if (timeFilter === "1h") timeMs = 3600000;
  else if (timeFilter === "6h") timeMs = 21600000;
  else if (timeFilter === "24h") timeMs = 86400000;
  else if (timeFilter === "7d") timeMs = 604800000;

  return allEvents.filter(function(evt) {
    if (agentFilter && evt.agent !== agentFilter) return false;
    var evtType = evt.type || evt.event || "";
    if (typeFilter && evtType !== typeFilter) return false;
    if (timeMs) {
      var evtTime = new Date(evt.timestamp || evt.ts || evt.time).getTime();
      if (now - evtTime > timeMs) return false;
    }
    return true;
  });
}

function renderFilteredEvents() {
  var filtered = getFilteredEvents();
  var log = document.getElementById("event-log-full");
  var countEl = document.getElementById("event-count");

  if (countEl) {
    countEl.textContent = filtered.length + " event" + (filtered.length !== 1 ? "s" : "");
  }

  if (!filtered || filtered.length === 0) {
    log.innerHTML = '<div class="placeholder-message">No events match filters</div>';
    return;
  }

  log.innerHTML = "";

  // Show newest first
  var reversed = filtered.slice().reverse();
  reversed.forEach(function (evt) {
    var row = document.createElement("div");
    row.className = "event-row";

    var time = document.createElement("span");
    time.className = "event-time";
    time.textContent = formatTimestamp(evt.timestamp || evt.ts || evt.time);
    row.appendChild(time);

    var evtType = evt.type || evt.event || "info";
    var type = document.createElement("span");
    type.className = "event-type " + eventTypeClass(evtType);
    type.textContent = evtType;
    row.appendChild(type);

    var agent = document.createElement("span");
    agent.className = "event-agent";
    agent.textContent = evt.agent || "";
    row.appendChild(agent);

    var job = document.createElement("span");
    job.className = "event-job-name";
    job.textContent = evt.job || "";
    row.appendChild(job);

    var detail = document.createElement("span");
    detail.className = "event-detail";
    var detailParts = [];
    if (evt.details) {
      if (evt.details.run_id) detailParts.push("run:" + evt.details.run_id);
      if (evt.details.duration) detailParts.push(evt.details.duration);
      if (evt.details.exit_code !== undefined) detailParts.push("exit:" + evt.details.exit_code);
      if (evt.details.queue_depth !== undefined) detailParts.push("queue:" + evt.details.queue_depth);
    }
    detail.textContent = detailParts.join(" | ");
    detail.title = JSON.stringify(evt.details || {});
    row.appendChild(detail);

    log.appendChild(row);
  });
}

function eventTypeClass(type) {
  if (!type) return "";
  return type.replace(/_/g, "-").toLowerCase();
}

// --- Connection indicator ---

function setConnected(connected) {
  isConnected = connected;
  var indicator = document.getElementById("connection-indicator");
  var text = document.getElementById("connection-text");
  if (connected) {
    indicator.className = "connection-indicator connected";
    text.textContent = "Connected";
  } else {
    indicator.className = "connection-indicator disconnected";
    text.textContent = "Disconnected";
  }
}

function updateTimestamp() {
  var el = document.getElementById("last-updated");
  el.textContent = "Updated " + new Date().toLocaleTimeString();
}

// --- Polling ---

async function poll() {
  // Fetch events FIRST so latestEvents is populated before renderAgents
  try {
    var events = await fetchEvents();
    latestEvents = events;
    var evtJSON = JSON.stringify(events);
    if (evtJSON !== lastEventsJSON) {
      lastEventsJSON = evtJSON;
      if (activeTopTab === "events") {
        allEvents = await fetchAllEvents();
        populateAgentFilter();
        renderFilteredEvents();
      }
    }
  } catch (e) {
    console.warn("Events fetch failed:", e.message);
  }

  try {
    var dashboard = await fetchDashboard();
    var dashJSON = JSON.stringify(dashboard);
    if (dashJSON !== lastDashboardJSON) {
      lastDashboardJSON = dashJSON;
      renderAgents(dashboard);
    } else if (activeTopTab === "agents" && lastDashboard) {
      // Even if dashboard unchanged, refresh activity feed with latest events
      var mergedAgents = mergeConfigAndDashboard(agentConfig, lastDashboard);
      // Filter events to active group
      var visNames = [];
      if (agentConfig && agentConfig.agents) {
        Object.keys(agentConfig.agents).forEach(function(n) {
          if (getAgentGroup(n) === activeGroup) visNames.push(n);
        });
      }
      var grpEvts = latestEvents.filter(function(evt) {
        return visNames.indexOf(evt.agent || "") !== -1;
      });
      renderActivityFeed(grpEvts);
      computeStats(latestEvents, mergedAgents);
    }
    setConnected(true);
    updateTimestamp();
  } catch (e) {
    setConnected(false);
    console.warn("Dashboard fetch failed:", e.message);
  }

  try {
    var errors = await fetchErrors();
    agentErrors = {};
    if (Array.isArray(errors)) {
      errors.forEach(function(err) {
        if (!err.resolved) {
          var agent = err.agent || "unknown";
          if (!agentErrors[agent]) agentErrors[agent] = [];
          agentErrors[agent].push(err);
        }
      });
    }
  } catch (e) {
    console.warn("Errors fetch failed:", e.message);
  }
}

async function startPolling() {
  // Restore state from URL
  var urlParams = new URLSearchParams(window.location.search);
  var viewParam = urlParams.get("view");
  var tabParam = urlParams.get("tab");
  if (tabParam) {
    activeGroup = tabParam;
  }
  if (viewParam && (viewParam === "agents" || viewParam === "events")) {
    activeTopTab = viewParam;
    switchTopTab(viewParam);
  }

  // Load config
  try {
    agentConfig = await fetchConfig();
  } catch (e) {
    console.warn("Config fetch failed, will retry on next poll:", e.message);
  }

  // Initial fetch
  poll();
  setInterval(poll, CONFIG.POLL_INTERVAL);
}

// --- Init ---
document.addEventListener("DOMContentLoaded", function () {
  // Top tab click handlers
  document.querySelectorAll(".top-tab").forEach(function(btn) {
    btn.addEventListener("click", function() {
      switchTopTab(btn.dataset.tab);
    });
  });

  // Event filter change handlers
  ["filter-agent", "filter-event-type", "filter-time"].forEach(function(id) {
    var el = document.getElementById(id);
    if (el) {
      el.addEventListener("change", function() {
        renderFilteredEvents();
      });
    }
  });

  startPolling();
});
