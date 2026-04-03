/* Virtual Office - Live Dashboard */

var CONFIG = {
  POLL_INTERVAL: 120000,
  MAX_EVENTS: 50,
  API_BASE: ""
};

// --- Agent color map (single source of truth for all agent colors) ---
var AGENT_COLORS = {
  "scrum-master": "#3b82f6",   // blue
  "bug-killer": "#ef4444",     // red
  "emailer": "#22c55e",        // green
  "auditor": "#a855f7",        // purple
  "poster": "#f59e0b",         // amber
  "hang-scout": "#06b6d4"      // cyan
};

// --- Legacy agent name mapping ---
// Maps old/renamed agent names to their current canonical names
var LEGACY_AGENT_NAMES = {
  "memo-checker": "auditor",
  "checker": "auditor"
};

function canonicalAgentName(name) {
  return LEGACY_AGENT_NAMES[name] || name;
}
function getAgentColor(name) {
  var canonical = canonicalAgentName(name);
  if (AGENT_COLORS[canonical]) return AGENT_COLORS[canonical];
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
var scheduleData = null;
var MAX_SCHEDULE_ROWS = 20;
var selectedAgentFilter = null;
var isDragging = false;

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

async function fetchSchedules() {
  var response = await fetch(CONFIG.API_BASE + "/api/schedules", { cache: "no-store" });
  if (!response.ok) throw new Error("HTTP " + response.status);
  return await response.json();
}

async function fetchReports() {
  var response = await fetch(CONFIG.API_BASE + "/api/reports", { cache: "no-store" });
  if (!response.ok) throw new Error("HTTP " + response.status);
  return await response.json();
}

// --- Cron helpers ---

function cronToHuman(cronExpr) {
  if (!cronExpr || typeof cronExpr !== "string") return String(cronExpr);
  var parts = cronExpr.trim().split(/\s+/);
  if (parts.length !== 5) return cronExpr;

  var min = parts[0];
  var hour = parts[1];
  var dom = parts[2];
  var month = parts[3];
  var dow = parts[4];

  function formatHour12(h, m) {
    var hi = parseInt(h, 10);
    var mi = parseInt(m, 10);
    var ampm = hi >= 12 ? "PM" : "AM";
    var h12 = hi % 12;
    if (h12 === 0) h12 = 12;
    return h12 + ":" + (mi < 10 ? "0" : "") + mi + " " + ampm;
  }

  // Every N minutes
  if (min.indexOf("*/") === 0) {
    var interval = min.substring(2);
    return "Every " + interval + " minutes";
  }

  // Every Nh at :MM
  if (hour.indexOf("*/") === 0 && /^\d+$/.test(min)) {
    var hInterval = hour.substring(2);
    var mi2 = parseInt(min, 10);
    return "Every " + hInterval + "h at :" + (mi2 < 10 ? "0" : "") + mi2;
  }

  // Hourly at :MM
  if (/^\d+$/.test(min) && hour === "*" && dom === "*" && month === "*" && dow === "*") {
    var mi3 = parseInt(min, 10);
    return "Hourly at :" + (mi3 < 10 ? "0" : "") + mi3;
  }

  // Daily / Weekdays / Weekends at specific time
  if (/^\d+$/.test(min) && /^\d+$/.test(hour) && dom === "*" && month === "*") {
    var timeStr = formatHour12(hour, min);
    if (dow === "*") return "Daily at " + timeStr;
    if (dow === "1-5") return "Weekdays at " + timeStr;
    if (dow === "0,6") return "Weekends at " + timeStr;
  }

  return cronExpr;
}

function getNextCronFires(cronExpr, afterDate, count) {
  if (!cronExpr || typeof cronExpr !== "string") return [];
  var parts = cronExpr.trim().split(/\s+/);
  if (parts.length !== 5) return [];

  var minField = parts[0];
  var hourField = parts[1];
  var domField = parts[2];
  var monthField = parts[3];
  var dowField = parts[4];

  function matchesCronField(value, field) {
    if (field === "*") return true;
    // */N
    if (field.indexOf("*/") === 0) {
      var step = parseInt(field.substring(2), 10);
      return step > 0 && value % step === 0;
    }
    // Comma-separated list (may include ranges)
    var segments = field.split(",");
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i].trim();
      if (seg.indexOf("-") !== -1) {
        var rangeParts = seg.split("-");
        var lo = parseInt(rangeParts[0], 10);
        var hi = parseInt(rangeParts[1], 10);
        if (value >= lo && value <= hi) return true;
      } else {
        if (parseInt(seg, 10) === value) return true;
      }
    }
    return false;
  }

  var results = [];
  // Start from afterDate, round up to next minute
  var cursor = new Date(afterDate.getTime());
  cursor.setSeconds(0, 0);
  cursor = new Date(cursor.getTime() + 60000); // next whole minute

  var maxIterations = 14 * 24 * 60; // 14 days in minutes
  for (var iter = 0; iter < maxIterations && results.length < count; iter++) {
    var cMin = cursor.getMinutes();
    var cHour = cursor.getHours();
    var cDom = cursor.getDate();
    var cMonth = cursor.getMonth() + 1; // cron months are 1-12
    var cDow = cursor.getDay(); // 0=Sun

    if (matchesCronField(cMin, minField) &&
        matchesCronField(cHour, hourField) &&
        matchesCronField(cDom, domField) &&
        matchesCronField(cMonth, monthField) &&
        matchesCronField(cDow, dowField)) {
      results.push(new Date(cursor.getTime()));
    }

    cursor = new Date(cursor.getTime() + 60000);
  }

  return results;
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

// --- Click-to-copy helper ---

function makeClickToCopy(element) {
  element.classList.add("click-to-copy");
  element.title = "Click to copy";
  element.addEventListener("click", function(e) {
    e.stopPropagation();
    var text = element.textContent.trim();
    navigator.clipboard.writeText(text).then(function() {
      element.classList.add("copied");
      var toast = document.createElement("span");
      toast.className = "copy-toast";
      toast.textContent = "Copied!";
      element.appendChild(toast);
      setTimeout(function() {
        element.classList.remove("copied");
        if (toast.parentNode) toast.remove();
      }, 1000);
    });
  });
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
  if (tabName === "events") {
    // Sync selectedAgentFilter to the Event Log dropdown
    var agentDropdown = document.getElementById("filter-agent");
    if (agentDropdown && selectedAgentFilter) {
      agentDropdown.value = selectedAgentFilter;
    } else if (agentDropdown && !selectedAgentFilter) {
      agentDropdown.value = "";
    }
    if (allEvents.length === 0) {
      loadAllEvents();
    } else {
      renderFilteredEvents();
    }
  }

  // Load schedules when switching to queue tab
  if (tabName === "queue" && !scheduleData) {
    loadScheduleData();
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

  // Status dot (top-right corner)
  var dot = document.createElement("span");
  dot.className = "status-dot " + status;
  card.appendChild(dot);

  // Header
  var header = document.createElement("div");
  header.className = "card-header";

  var iconSpan = document.createElement("span");
  iconSpan.className = "agent-icon";
  iconSpan.textContent = icon;
  header.appendChild(iconSpan);

  var nameSpan = document.createElement("span");
  nameSpan.className = "agent-name";
  nameSpan.textContent = agentData.display_name || name;
  header.appendChild(nameSpan);

  card.appendChild(header);

  // Status line (only shown when there's meaningful info)
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
    statusLine.textContent = "";
  }
  if (statusLine.textContent) card.appendChild(statusLine);

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

  // Jobs list (sorted alphabetically by name)
  var jobs = (agentData.jobs || []).slice().sort(function(a, b) {
    var na = (a.name || a.job || "").toLowerCase();
    var nb = (b.name || b.job || "").toLowerCase();
    return na < nb ? -1 : na > nb ? 1 : 0;
  });
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

  if (elCompletedToday) {
    elCompletedToday.textContent = completedToday + " today";
    elCompletedToday.style.cursor = "pointer";
    elCompletedToday.title = "Click to view completed events";
    elCompletedToday.onclick = function() {
      document.getElementById("filter-event-type").value = "completed";
      document.getElementById("filter-time").value = "24h";
      document.getElementById("filter-agent").value = "";
      selectedAgentFilter = null;
      switchTopTab("events");
      if (allEvents.length > 0) renderFilteredEvents();
    };
  }
  if (elCompletedWeek) elCompletedWeek.textContent = completedWeek + " this week";
  if (elFailedToday) {
    elFailedToday.textContent = failedToday + " today" + (stalledToday > 0 ? " (" + explicitFailedToday + " failed + " + stalledToday + " stalled)" : "");
    elFailedToday.style.cursor = "pointer";
    elFailedToday.title = "Click to view failed events";
    elFailedToday.onclick = function() {
      document.getElementById("filter-event-type").value = "failed";
      document.getElementById("filter-time").value = "24h";
      document.getElementById("filter-agent").value = "";
      selectedAgentFilter = null;
      switchTopTab("events");
      if (allEvents.length > 0) renderFilteredEvents();
    };
  }
  if (elFailedWeek) elFailedWeek.textContent = failedWeek + " this week" + (stalledWeek > 0 ? " (" + explicitFailedWeek + " failed + " + stalledWeek + " stalled)" : "");
  if (elAgentsActive) elAgentsActive.textContent = String(agentsActive);
  if (elAgentsTotal) elAgentsTotal.textContent = agentsTotal + " total";
}

// --- Mission Control: Agent List (left column) ---

function initAgentListDragDrop() {
  // Container-level drag delegation (set up ONCE, survives re-renders)
  var listEl = document.getElementById("agent-list");
  if (!listEl || listEl._dragInitialized) return;
  listEl._dragInitialized = true;

  listEl.addEventListener("dragover", function(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    // Find the card being dragged over
    var targetCard = e.target.closest(".agent-list-card");
    // Clear all drag-over indicators
    listEl.querySelectorAll(".agent-list-card").forEach(function(c) {
      c.classList.remove("drag-over");
    });
    if (targetCard && !targetCard.classList.contains("dragging")) {
      targetCard.classList.add("drag-over");
    }
  });

  listEl.addEventListener("dragleave", function(e) {
    var targetCard = e.target.closest(".agent-list-card");
    if (targetCard) targetCard.classList.remove("drag-over");
  });

  listEl.addEventListener("drop", function(e) {
    e.preventDefault();
    // Clear all drag-over indicators
    listEl.querySelectorAll(".agent-list-card").forEach(function(c) {
      c.classList.remove("drag-over");
    });
    var draggedName = e.dataTransfer.getData("text/plain");
    if (!draggedName) return;
    var draggedCard = listEl.querySelector('[data-agent="' + draggedName + '"]');
    if (!draggedCard) return;
    // Find the drop target card
    var targetCard = e.target.closest(".agent-list-card");
    if (!targetCard || targetCard === draggedCard) return;
    // Determine position: insert before or after target based on mouse Y
    var rect = targetCard.getBoundingClientRect();
    var midY = rect.top + rect.height / 2;
    if (e.clientY < midY) {
      listEl.insertBefore(draggedCard, targetCard);
    } else {
      listEl.insertBefore(draggedCard, targetCard.nextSibling);
    }
    // Persist new order to localStorage
    var newOrder = [];
    listEl.querySelectorAll(".agent-list-card").forEach(function(c) {
      if (c.dataset.agent) newOrder.push(c.dataset.agent);
    });
    try { localStorage.setItem("vo-agent-order", JSON.stringify(newOrder)); } catch (e2) { /* ignore */ }
  });
}

function renderAgentList(agents) {
  var listEl = document.getElementById("agent-list");
  if (!listEl) return;
  // Skip re-render while user is actively dragging to avoid destroying drag state
  if (isDragging) return;

  // Set up container-level drag handlers once
  initAgentListDragDrop();

  listEl.innerHTML = "";

  var busyCount = 0;
  var agentNames = Object.keys(agents);

  // Apply saved drag-and-drop order from localStorage (fallback to config order)
  var savedOrder = null;
  try {
    var raw = localStorage.getItem("vo-agent-order");
    if (raw) savedOrder = JSON.parse(raw);
  } catch (e) { /* ignore */ }
  if (Array.isArray(savedOrder) && savedOrder.length > 0) {
    agentNames.sort(function(a, b) {
      var ia = savedOrder.indexOf(a);
      var ib = savedOrder.indexOf(b);
      if (ia === -1) ia = 9999;
      if (ib === -1) ib = 9999;
      return ia - ib;
    });
  }

  agentNames.forEach(function(name) {
    var agentData = agents[name];
    var status = getAgentStatus(agentData);
    if (status === "busy") busyCount++;

    var card = document.createElement("div");
    card.className = "agent-list-card " + status;
    card.dataset.agent = name;
    card.setAttribute("draggable", "true");

    // Track drag state for this card (suppresses click after drag)
    var wasDragged = false;

    // Drag handle — only this element initiates the drag
    var dragHandle = document.createElement("span");
    dragHandle.className = "drag-handle";
    dragHandle.textContent = "\u2630"; // hamburger/grip icon
    dragHandle.title = "Drag to reorder";
    dragHandle.setAttribute("draggable", "false");
    card.appendChild(dragHandle);

    // Card-level drag handlers: dragstart + dragend only
    // Prevent drag unless it starts from the drag handle
    card.addEventListener("dragstart", function(e) {
      // Only allow drag if the mousedown originated on the drag handle
      if (!card._handleMouseDown) {
        e.preventDefault();
        return;
      }
      isDragging = true;
      wasDragged = true;
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", name);
      card.classList.add("dragging");
    });
    card.addEventListener("dragend", function() {
      isDragging = false;
      card._handleMouseDown = false;
      card.classList.remove("dragging");
      // Clean up all drag-over indicators
      listEl.querySelectorAll(".agent-list-card").forEach(function(c) {
        c.classList.remove("drag-over");
      });
      setTimeout(function() { wasDragged = false; }, 200);
    });
    // Track mousedown on handle to gate dragstart
    dragHandle.addEventListener("mousedown", function() {
      card._handleMouseDown = true;
    });
    document.addEventListener("mouseup", function() {
      card._handleMouseDown = false;
    });

    // Top row: name + status badge
    var topRow = document.createElement("div");
    topRow.className = "agent-list-top";
    topRow.setAttribute("draggable", "false");

    var nameEl = document.createElement("span");
    nameEl.className = "agent-list-name";
    nameEl.textContent = agentData.display_name || name;
    nameEl.style.color = getAgentColor(name);
    nameEl.setAttribute("draggable", "false");
    topRow.appendChild(nameEl);

    var filterBtn = document.createElement("button");
    filterBtn.className = "agent-filter-btn" + (selectedAgentFilter === name ? " active" : "");
    filterBtn.title = "Filter schedule for " + (agentData.display_name || name);
    filterBtn.innerHTML = "&#x1F50D;";
    filterBtn.setAttribute("draggable", "false");
    filterBtn.addEventListener("click", function(e) {
      e.stopPropagation();
      if (selectedAgentFilter === name) {
        selectedAgentFilter = null;
      } else {
        selectedAgentFilter = name;
      }
      // Update all filter button states
      document.querySelectorAll(".agent-filter-btn").forEach(function(btn) {
        btn.classList.remove("active");
      });
      if (selectedAgentFilter) {
        document.querySelectorAll('.agent-filter-btn').forEach(function(btn) {
          if (btn.closest('[data-agent="' + selectedAgentFilter + '"]')) {
            btn.classList.add("active");
          }
        });
      }
      // Update card selected states
      document.querySelectorAll(".agent-list-card").forEach(function(c) {
        c.classList.remove("schedule-filter-active");
      });
      if (selectedAgentFilter) {
        var activeCard = document.querySelector('.agent-list-card[data-agent="' + selectedAgentFilter + '"]');
        if (activeCard) activeCard.classList.add("schedule-filter-active");
      }
      renderScheduleFilterIndicator();
      renderScheduleTable();
      // Switch to Event Log tab filtered to this agent
      if (selectedAgentFilter) {
        switchTopTab("events");
      }
    });
    topRow.appendChild(filterBtn);

    var statusDot = document.createElement("span");
    statusDot.className = "agent-list-dot " + status;
    statusDot.setAttribute("draggable", "false");
    topRow.appendChild(statusDot);
    card.appendChild(topRow);

    if (selectedAgentFilter === name) {
      card.classList.add("schedule-filter-active");
    }

    // Activity line
    var activityLine = document.createElement("div");
    activityLine.className = "agent-list-activity";
    activityLine.setAttribute("draggable", "false");

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
    tsLine.setAttribute("draggable", "false");
    if (agentData.last_completed) {
      tsLine.textContent = formatTimestamp(agentData.last_completed);
    } else {
      tsLine.textContent = "";
    }
    card.appendChild(tsLine);

    // Click handler (suppress after drag to avoid accidental modal open)
    if (status === "busy") {
      card.classList.add("clickable");
      card.addEventListener("click", function() {
        if (wasDragged) return;
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

  // Render agent list
  renderAgentList(filteredAgents);

  // Compute stats using all agents (not just filtered)
  computeStats(latestEvents, agents);
}

// --- Event Log (full page) ---

async function loadAllEvents() {
  try {
    allEvents = await fetchAllEvents();
    populateAgentFilter();
    // Sync agent filter dropdown after options are populated
    // (switchTopTab may have set it before options existed)
    var agentDropdown = document.getElementById("filter-agent");
    if (agentDropdown && selectedAgentFilter) {
      agentDropdown.value = selectedAgentFilter;
    }
    renderFilteredEvents();
  } catch (e) {
    console.warn("Failed to load all events:", e.message);
  }
}

function populateAgentFilter() {
  var select = document.getElementById("filter-agent");
  if (!select) return;
  var agents = {};
  // Include agents that have events (map legacy names to canonical)
  allEvents.forEach(function(evt) {
    if (evt.agent) agents[canonicalAgentName(evt.agent)] = true;
  });
  // Include agents from config (currently configured agents)
  if (agentConfig && agentConfig.agents) {
    Object.keys(agentConfig.agents).forEach(function(name) {
      agents[name] = true;
    });
  }
  // Preserve current selection (also canonicalize)
  var current = canonicalAgentName(select.value);
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
    if (agentFilter && canonicalAgentName(evt.agent) !== agentFilter) return false;
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
    var evtAgentName = canonicalAgentName(evt.agent || "");
    agent.textContent = evtAgentName;
    agent.style.color = getAgentColor(evtAgentName);
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

// --- Schedule / Queue rendering ---

async function loadScheduleData() {
  try {
    var results = await Promise.all([fetchSchedules(), fetchDashboard(), fetchConfig()]);
    scheduleData = results[0];
    scheduleData.dashboard = results[1];
    scheduleData.config = results[2];
    // Use mergeConfigAndDashboard to get properly normalized agent/job state
    // This handles the flat dashboard format exactly like the Agents tab does
    scheduleData.merged = mergeConfigAndDashboard(results[2], results[1]);
    renderScheduleTable();
    renderQueueCards();
  } catch (e) {
    console.warn("Failed to load schedule data:", e.message);
  }
}

function renderScheduleFilterIndicator() {
  // Remove existing indicator if present
  var existing = document.getElementById("schedule-filter-indicator");
  if (existing) existing.remove();

  if (!selectedAgentFilter) return;

  var wrapper = document.getElementById("schedule-table-wrapper");
  if (!wrapper) return;

  var indicator = document.createElement("div");
  indicator.id = "schedule-filter-indicator";
  indicator.className = "schedule-filter-indicator";

  var label = document.createElement("span");
  var displayName = selectedAgentFilter;
  // Try to get display_name from scheduleData or lastDashboard
  if (scheduleData && scheduleData.merged && scheduleData.merged[selectedAgentFilter]) {
    displayName = scheduleData.merged[selectedAgentFilter].display_name || selectedAgentFilter;
  } else if (lastDashboard && lastDashboard[selectedAgentFilter]) {
    displayName = lastDashboard[selectedAgentFilter].display_name || selectedAgentFilter;
  }
  label.textContent = "Showing schedule for: " + displayName;
  label.style.color = getAgentColor(selectedAgentFilter);
  indicator.appendChild(label);

  var clearBtn = document.createElement("button");
  clearBtn.className = "schedule-filter-clear";
  clearBtn.innerHTML = "&#x2715;";
  clearBtn.title = "Clear filter";
  clearBtn.addEventListener("click", function() {
    selectedAgentFilter = null;
    document.querySelectorAll(".agent-filter-btn").forEach(function(btn) {
      btn.classList.remove("active");
    });
    document.querySelectorAll(".agent-list-card").forEach(function(c) {
      c.classList.remove("schedule-filter-active");
    });
    document.querySelectorAll(".queue-card").forEach(function(c) {
      c.classList.remove("schedule-filter-active");
    });
    renderScheduleFilterIndicator();
    renderScheduleTable();
  });
  indicator.appendChild(clearBtn);

  wrapper.parentNode.insertBefore(indicator, wrapper);
}

function renderScheduleTable() {
  renderScheduleFilterIndicator();
  if (!scheduleData) return;
  var schedules = scheduleData.schedules || [];
  var now = new Date();
  var allItems = [];

  schedules.forEach(function(sched) {
    var agent = sched.agent || "";
    var job = sched.job || "";
    var cron = sched.cron || "";
    var enabled = sched.enabled !== false;
    var description = sched.description || "";
    var cronHuman = cronToHuman(cron);
    var fires = enabled ? getNextCronFires(cron, now, 10) : [];

    if (!enabled) {
      // Show one row for disabled schedules
      allItems.push({
        fireTime: null,
        agent: agent,
        job: job,
        cron: cron,
        cronHuman: cronHuman,
        description: description,
        enabled: false,
        status: "disabled"
      });
      return;
    }

    fires.forEach(function(fireTime) {
      allItems.push({
        fireTime: fireTime,
        agent: agent,
        job: job,
        cron: cron,
        cronHuman: cronHuman,
        description: description,
        enabled: true,
        status: "scheduled"
      });
    });
  });

  // Cross-reference with merged agent state (same source as Agents tab)
  var mergedAgents = scheduleData.merged || {};
  var runningMarked = {};
  var queuedMarked = {};

  allItems.forEach(function(item) {
    if (!item.enabled) return;
    var key = item.agent + "/" + item.job;
    var agentData = mergedAgents[item.agent];
    if (!agentData) return;

    // Find the matching job in the merged jobs array
    var matchedJob = null;
    (agentData.jobs || []).forEach(function(j) {
      if (j.name === item.job) matchedJob = j;
    });
    if (!matchedJob) return;

    if (matchedJob.status === "running" && !runningMarked[key]) {
      item.status = "running";
      runningMarked[key] = true;
    } else if (matchedJob.queueDepth > 0 && !queuedMarked[key]) {
      var queuedCount = queuedMarked[key + "_count"] || 0;
      if (queuedCount < matchedJob.queueDepth) {
        item.status = "queued";
        queuedMarked[key + "_count"] = queuedCount + 1;
      }
    }
  });

  // Sort: disabled at end, then by fireTime ascending
  allItems.sort(function(a, b) {
    if (!a.fireTime && !b.fireTime) return 0;
    if (!a.fireTime) return 1;
    if (!b.fireTime) return -1;
    return a.fireTime.getTime() - b.fireTime.getTime();
  });

  // Apply agent filter if active
  if (selectedAgentFilter) {
    allItems = allItems.filter(function(item) {
      return item.agent === selectedAgentFilter;
    });
  }

  var totalCount = allItems.length;
  var displayItems = allItems.slice(0, MAX_SCHEDULE_ROWS);

  var tbody = document.getElementById("schedule-tbody");
  if (!tbody) return;
  tbody.innerHTML = "";

  displayItems.forEach(function(item) {
    var tr = document.createElement("tr");
    if (item.status === "running") tr.className = "running-row";
    else if (item.status === "queued") tr.className = "queued-row";
    else if (item.status === "disabled") tr.className = "disabled-row";

    // Next Run
    var tdTime = document.createElement("td");
    if (item.fireTime) {
      tdTime.textContent = item.fireTime.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" }) + ", " + item.fireTime.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", hour12: true });
    } else {
      tdTime.textContent = "--";
    }
    tr.appendChild(tdTime);

    // Agent
    var tdAgent = document.createElement("td");
    tdAgent.style.color = getAgentColor(item.agent);
    tdAgent.style.fontWeight = "bold";
    tdAgent.textContent = item.agent;
    tr.appendChild(tdAgent);

    // Job
    var tdJob = document.createElement("td");
    var tdJobSpan = document.createElement("span");
    tdJobSpan.textContent = item.job;
    tdJobSpan.style.color = "#9ca3af";
    makeClickToCopy(tdJobSpan);
    tdJob.appendChild(tdJobSpan);
    tr.appendChild(tdJob);

    // Schedule
    var tdSchedule = document.createElement("td");
    tdSchedule.textContent = item.cronHuman;
    tdSchedule.title = item.cron;
    tr.appendChild(tdSchedule);

    // Status
    var tdStatus = document.createElement("td");
    var badge = document.createElement("span");
    badge.className = "schedule-status-badge " + item.status;
    badge.textContent = item.status;
    tdStatus.appendChild(badge);
    tr.appendChild(tdStatus);

    // Action
    var tdAction = document.createElement("td");
    if (item.status === "running") {
      var stopBtn = document.createElement("button");
      stopBtn.className = "force-stop-btn";
      stopBtn.textContent = "Force Stop";
      stopBtn.addEventListener("click", function() {
        if (stopBtn.classList.contains("confirming")) {
          fetch(CONFIG.API_BASE + "/api/job/stop", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ agent: item.agent, job: item.job })
          }).then(function() {
            scheduleData = null;
            loadScheduleData();
          });
        } else {
          stopBtn.classList.add("confirming");
          stopBtn.textContent = "Click again to stop";
          setTimeout(function() {
            stopBtn.classList.remove("confirming");
            stopBtn.textContent = "Force Stop";
          }, 3000);
        }
      });
      tdAction.appendChild(stopBtn);
    } else if (item.status === "queued") {
      var cancelBtn = document.createElement("button");
      cancelBtn.className = "cancel-btn";
      cancelBtn.textContent = "Cancel";
      cancelBtn.addEventListener("click", function() {
        fetch(CONFIG.API_BASE + "/api/queue/cancel", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ agent: item.agent, job: item.job })
        }).then(function() {
          scheduleData = null;
          loadScheduleData();
        });
      });
      tdAction.appendChild(cancelBtn);
    }
    tr.appendChild(tdAction);

    tbody.appendChild(tr);
  });

  // Update count badge
  var countEl = document.getElementById("schedule-count");
  if (countEl) countEl.textContent = totalCount;

  // Overflow message
  var overflowEl = document.getElementById("schedule-overflow");
  if (overflowEl) {
    if (totalCount > MAX_SCHEDULE_ROWS) {
      overflowEl.style.display = "";
      overflowEl.textContent = "Showing " + MAX_SCHEDULE_ROWS + " of " + totalCount + " upcoming tasks";
    } else {
      overflowEl.style.display = "none";
    }
  }
}

function renderQueueCards() {
  if (!scheduleData) return;
  var queues = scheduleData.queues || {};
  var config = scheduleData.config || agentConfig;
  var mergedAgents = scheduleData.merged || {};
  var schedules = scheduleData.schedules || [];
  var container = document.getElementById("queue-cards");
  if (!container) return;
  container.innerHTML = "";

  var totalQueueDepth = 0;
  var agentNames = [];
  if (config && config.agents) {
    agentNames = Object.keys(config.agents);
  }

  // Apply saved drag-and-drop order from localStorage (fallback to config order)
  var savedQueueOrder = null;
  try {
    var rawQ = localStorage.getItem("vo-queue-card-order");
    if (rawQ) savedQueueOrder = JSON.parse(rawQ);
  } catch (e) { /* ignore */ }
  if (Array.isArray(savedQueueOrder) && savedQueueOrder.length > 0) {
    agentNames.sort(function(a, b) {
      var ia = savedQueueOrder.indexOf(a);
      var ib = savedQueueOrder.indexOf(b);
      if (ia === -1) ia = 9999;
      if (ib === -1) ib = 9999;
      return ia - ib;
    });
  } else {
    // Default: alphabetical
    agentNames.sort(function(a, b) {
      return a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0;
    });
  }

  // Set up container-level drag handlers once
  if (!container._dragInitialized) {
    container._dragInitialized = true;
    container.addEventListener("dragover", function(e) {
      e.preventDefault();
      e.dataTransfer.dropEffect = "move";
      var targetCard = e.target.closest(".queue-card");
      container.querySelectorAll(".queue-card").forEach(function(c) { c.classList.remove("drag-over"); });
      if (targetCard && !targetCard.classList.contains("dragging")) {
        targetCard.classList.add("drag-over");
      }
    });
    container.addEventListener("dragleave", function(e) {
      var targetCard = e.target.closest(".queue-card");
      if (targetCard) targetCard.classList.remove("drag-over");
    });
    container.addEventListener("drop", function(e) {
      e.preventDefault();
      container.querySelectorAll(".queue-card").forEach(function(c) { c.classList.remove("drag-over"); });
      var draggedName = e.dataTransfer.getData("text/plain");
      if (!draggedName) return;
      var draggedCard = container.querySelector('.queue-card[data-agent="' + draggedName + '"]');
      if (!draggedCard) return;
      var targetCard = e.target.closest(".queue-card");
      if (!targetCard || targetCard === draggedCard) return;
      var rect = targetCard.getBoundingClientRect();
      var midY = rect.top + rect.height / 2;
      if (e.clientY < midY) {
        container.insertBefore(draggedCard, targetCard);
      } else {
        container.insertBefore(draggedCard, targetCard.nextSibling);
      }
      var newOrder = [];
      container.querySelectorAll(".queue-card").forEach(function(c) {
        if (c.dataset.agent) newOrder.push(c.dataset.agent);
      });
      try { localStorage.setItem("vo-queue-card-order", JSON.stringify(newOrder)); } catch (e2) { /* ignore */ }
    });
  }

  agentNames.forEach(function(agentName) {
    var agentCfg = config.agents[agentName];
    var agentColor = getAgentColor(agentName);
    var agentData = mergedAgents[agentName] || {};
    var agentQueue = queues[agentName] || {};
    var mergedJobs = (agentData.jobs || []).slice().sort(function(a, b) {
      var na = (a.name || "").toLowerCase();
      var nb = (b.name || "").toLowerCase();
      return na < nb ? -1 : na > nb ? 1 : 0;
    });
    var agentStatus = getAgentStatus(agentData);

    var card = document.createElement("div");
    card.className = "queue-card";
    card.style.borderLeftColor = agentColor;
    card.setAttribute("draggable", "true");

    // Drag handle
    var qDragHandle = document.createElement("span");
    qDragHandle.className = "drag-handle";
    qDragHandle.textContent = "\u2630";
    qDragHandle.title = "Drag to reorder";
    qDragHandle.setAttribute("draggable", "false");

    card.addEventListener("dragstart", function(e) {
      if (!card._handleMouseDown) { e.preventDefault(); return; }
      isDragging = true;
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", agentName);
      card.classList.add("dragging");
    });
    card.addEventListener("dragend", function() {
      isDragging = false;
      card._handleMouseDown = false;
      card.classList.remove("dragging");
      container.querySelectorAll(".queue-card").forEach(function(c) { c.classList.remove("drag-over"); });
    });
    qDragHandle.addEventListener("mousedown", function() { card._handleMouseDown = true; });
    document.addEventListener("mouseup", function() { card._handleMouseDown = false; });

    // Header
    var header = document.createElement("div");
    header.className = "queue-card-header";
    header.prepend(qDragHandle);
    var nameSpan = document.createElement("span");
    nameSpan.className = "queue-card-name";
    nameSpan.textContent = agentData.display_name || agentCfg.displayName || agentName;
    nameSpan.style.color = agentColor;
    makeClickToCopy(nameSpan);
    header.appendChild(nameSpan);

    var qFilterBtn = document.createElement("button");
    qFilterBtn.className = "agent-filter-btn" + (selectedAgentFilter === agentName ? " active" : "");
    qFilterBtn.title = "Filter schedule for " + (agentData.display_name || agentCfg.displayName || agentName);
    qFilterBtn.innerHTML = "&#x1F50D;";
    qFilterBtn.addEventListener("click", function(e) {
      e.stopPropagation();
      if (selectedAgentFilter === agentName) {
        selectedAgentFilter = null;
      } else {
        selectedAgentFilter = agentName;
      }
      document.querySelectorAll(".agent-filter-btn").forEach(function(btn) {
        btn.classList.remove("active");
      });
      document.querySelectorAll(".agent-list-card, .queue-card").forEach(function(c) {
        c.classList.remove("schedule-filter-active");
      });
      if (selectedAgentFilter) {
        document.querySelectorAll('.agent-filter-btn').forEach(function(btn) {
          var parentCard = btn.closest('[data-agent="' + selectedAgentFilter + '"]') || btn.closest('.queue-card');
          if (parentCard && parentCard.dataset.agent === selectedAgentFilter) {
            btn.classList.add("active");
          }
        });
        document.querySelectorAll('.agent-list-card[data-agent="' + selectedAgentFilter + '"], .queue-card[data-agent="' + selectedAgentFilter + '"]').forEach(function(c) {
          c.classList.add("schedule-filter-active");
        });
      }
      renderScheduleFilterIndicator();
      renderScheduleTable();
    });
    header.appendChild(qFilterBtn);

    var statusDot = document.createElement("span");
    statusDot.className = "queue-card-dot " + agentStatus;
    header.appendChild(statusDot);
    card.appendChild(header);

    card.dataset.agent = agentName;
    if (selectedAgentFilter === agentName) {
      card.classList.add("schedule-filter-active");
    }

    // Running job info (from merged data, same as Agents tab)
    var runningJobName = null;
    if (agentData.running_job) {
      runningJobName = agentData.running_job.job || agentData.running_job.name || null;
    }

    // Lock status
    var lockDiv = document.createElement("div");
    lockDiv.className = "queue-card-lock";
    var lockDot = document.createElement("span");
    var lockText = document.createElement("span");
    if (runningJobName) {
      lockDot.className = "lock-indicator locked";
      lockText.textContent = "Locked by " + runningJobName;

      // Show running job info with elapsed
      var runInfoDiv = document.createElement("div");
      runInfoDiv.className = "queue-card-running";
      var runText = "Running: " + runningJobName;
      var startedTime = null;
      mergedJobs.forEach(function(j) {
        if (j.status === "running" && j.started) {
          startedTime = j.started;
        }
      });
      if (startedTime) {
        var elapsed = Math.max(0, Math.floor((Date.now() - new Date(startedTime).getTime()) / 1000));
        var em = Math.floor(elapsed / 60);
        var es = elapsed % 60;
        runText += " (" + em + "m " + (es < 10 ? "0" : "") + es + "s)";
      }
      runInfoDiv.textContent = runText;

      var stopBtn = document.createElement("button");
      stopBtn.className = "force-stop-btn";
      stopBtn.textContent = "Force Stop";
      stopBtn.addEventListener("click", function() {
        if (stopBtn.classList.contains("confirming")) {
          fetch(CONFIG.API_BASE + "/api/job/stop", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ agent: agentName, job: runningJobName })
          }).then(function() {
            scheduleData = null;
            loadScheduleData();
          });
        } else {
          stopBtn.classList.add("confirming");
          stopBtn.textContent = "Click again to stop";
          setTimeout(function() {
            stopBtn.classList.remove("confirming");
            stopBtn.textContent = "Force Stop";
          }, 3000);
        }
      });
      runInfoDiv.appendChild(stopBtn);
      card.appendChild(runInfoDiv);
    }
    if (runningJobName) {
      lockDiv.appendChild(lockDot);
      lockDiv.appendChild(lockText);
      card.appendChild(lockDiv);
    }

    // Job queue list (from merged jobs array)
    var jobList = document.createElement("div");
    jobList.className = "queue-card-jobs";
    mergedJobs.forEach(function(job) {
      var jobName = job.name || "unknown";
      var jobRow = document.createElement("div");
      jobRow.className = "queue-card-job";

      var jName = document.createElement("span");
      jName.className = "queue-card-job-name";
      jName.textContent = jobName;
      makeClickToCopy(jName);
      jobRow.appendChild(jName);

      // Get queue depth from merged job data
      var depth = job.queueDepth || 0;
      totalQueueDepth += depth;

      if (depth > 0) {
        var depthBadge = document.createElement("span");
        depthBadge.className = "queue-depth";
        depthBadge.textContent = depth + " queued";
        jobRow.appendChild(depthBadge);

        var cancelBtn = document.createElement("button");
        cancelBtn.className = "cancel-btn";
        cancelBtn.textContent = "Cancel";
        cancelBtn.addEventListener("click", function() {
          fetch(CONFIG.API_BASE + "/api/queue/cancel", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ agent: agentName, job: jobName })
          }).then(function() {
            scheduleData = null;
            loadScheduleData();
          });
        });
        jobRow.appendChild(cancelBtn);
      }

      jobList.appendChild(jobRow);
    });
    card.appendChild(jobList);

    // Next scheduled
    var agentSchedules = schedules.filter(function(s) {
      return s.agent === agentName && s.enabled !== false;
    });
    if (agentSchedules.length > 0) {
      var nextFireDiv = document.createElement("div");
      nextFireDiv.className = "queue-card-next";
      var earliest = null;
      var earliestJob = "";
      agentSchedules.forEach(function(s) {
        var fires = getNextCronFires(s.cron || "", new Date(), 1);
        if (fires.length > 0 && (!earliest || fires[0].getTime() < earliest.getTime())) {
          earliest = fires[0];
          earliestJob = s.job || "";
        }
      });
      if (earliest) {
        nextFireDiv.textContent = "Next: " + earliestJob + " at " + earliest.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", hour12: true });
      }
      card.appendChild(nextFireDiv);
    }

    container.appendChild(card);
  });

  // Update total badge
  var totalBadge = document.getElementById("queue-total-badge");
  if (totalBadge) totalBadge.textContent = totalQueueDepth;
}

// --- Recent Reports ---

var reportsData = null;
var reportsRows = [];
var reportsSortCol = 2; // default sort by date
var reportsSortAsc = false; // newest first

function formatFileSize(bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / 1048576).toFixed(1) + " MB";
}

function flattenReports(data) {
  var rows = [];
  if (!data || !data.agents) return rows;
  Object.keys(data.agents).forEach(function(agentName) {
    var jobs = data.agents[agentName];
    Object.keys(jobs).forEach(function(jobName) {
      jobs[jobName].forEach(function(file) {
        rows.push({
          agent: agentName,
          job: jobName,
          name: file.name,
          date: file.date,
          size: file.size,
          url: file.url || file.path
        });
      });
    });
  });
  return rows;
}

function populateReportsAgentFilter(rows) {
  var sel = document.getElementById("reports-agent-filter");
  if (!sel) return;
  var agents = {};
  rows.forEach(function(r) { agents[r.agent] = true; });
  var current = sel.value;
  sel.innerHTML = '<option value="">All Agents</option>';
  Object.keys(agents).sort().forEach(function(a) {
    var opt = document.createElement("option");
    opt.value = a;
    opt.textContent = a;
    sel.appendChild(opt);
  });
  sel.value = current;
}

function getFilteredSortedReports() {
  var search = (document.getElementById("reports-search") || {}).value || "";
  search = search.toLowerCase();
  var agentFilter = (document.getElementById("reports-agent-filter") || {}).value || "";

  var filtered = reportsRows.filter(function(r) {
    if (agentFilter && r.agent !== agentFilter) return false;
    if (search && r.name.toLowerCase().indexOf(search) === -1 &&
        r.job.toLowerCase().indexOf(search) === -1 &&
        r.agent.toLowerCase().indexOf(search) === -1) return false;
    return true;
  });

  var col = reportsSortCol;
  var asc = reportsSortAsc;
  var dir = asc ? 1 : -1;
  filtered.sort(function(a, b) {
    var av, bv;
    if (col === 0) { av = a.agent; bv = b.agent; }
    else if (col === 1) { av = a.job; bv = b.job; }
    else if (col === 2) { av = a.date; bv = b.date; }
    else if (col === 3) { av = a.name; bv = b.name; }
    else if (col === 4) { av = a.size; bv = b.size; return (av - bv) * dir; }
    else { av = a.agent; bv = b.agent; }
    return av < bv ? -dir : av > bv ? dir : 0;
  });

  return filtered;
}

function renderReportsTable() {
  var container = document.getElementById("reports-tree");
  if (!container) return;

  var filtered = getFilteredSortedReports();
  var badge = document.getElementById("reports-badge");
  if (badge) badge.textContent = filtered.length + "/" + reportsRows.length;

  if (filtered.length === 0) {
    container.innerHTML = '<div class="placeholder-message">No reports found</div>';
    return;
  }

  var cols = ["Agent", "Job", "Date", "Report", "Size"];
  var html = '<table id="reports-table"><thead><tr>';
  cols.forEach(function(c, i) {
    var cls = "";
    if (i === reportsSortCol) cls = reportsSortAsc ? " class=\"sort-asc\"" : " class=\"sort-desc\"";
    html += "<th data-col=\"" + i + "\"" + cls + ">" + c + "</th>";
  });
  html += "</tr></thead><tbody>";

  filtered.forEach(function(r) {
    var color = getAgentColor(r.agent);
    html += "<tr>";
    html += '<td><span class="report-agent-pill" style="background:' + color + '">' + r.agent + "</span></td>";
    html += "<td>" + r.job + "</td>";
    html += "<td>" + r.date + "</td>";
    html += '<td><a class="report-file-link" href="' + r.url + '" target="_blank">' + r.name + "</a></td>";
    html += '<td class="num">' + formatFileSize(r.size) + "</td>";
    html += "</tr>";
  });

  html += "</tbody></table>";
  container.innerHTML = html;

  // Attach sort handlers
  var ths = container.querySelectorAll("#reports-table th");
  ths.forEach(function(th) {
    th.addEventListener("click", function() {
      var col = parseInt(th.getAttribute("data-col"));
      if (col === reportsSortCol) {
        reportsSortAsc = !reportsSortAsc;
      } else {
        reportsSortCol = col;
        reportsSortAsc = col === 4 ? false : true; // size defaults desc
      }
      renderReportsTable();
    });
  });
}

function renderReportsTree(data) {
  reportsData = data;
  reportsRows = flattenReports(data);
  populateReportsAgentFilter(reportsRows);
  renderReportsTable();
}

// Attach filter event listeners once DOM is ready
document.addEventListener("DOMContentLoaded", function() {
  var searchEl = document.getElementById("reports-search");
  var filterEl = document.getElementById("reports-agent-filter");
  if (searchEl) searchEl.addEventListener("input", renderReportsTable);
  if (filterEl) filterEl.addEventListener("change", renderReportsTable);
});

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
      // Always re-render agent list to pick up localStorage order changes
      renderAgents(lastDashboard);
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

  // Refresh queue tab if active
  if (activeTopTab === "queue") {
    try {
      scheduleData = await fetchSchedules();
      scheduleData.dashboard = lastDashboard;
      scheduleData.config = agentConfig;
      scheduleData.merged = mergeConfigAndDashboard(agentConfig, lastDashboard);
      renderScheduleTable();
      renderQueueCards();
    } catch (e) {
      console.warn("Schedules fetch failed:", e.message);
    }
  }

  // Refresh reports on agents tab
  if (activeTopTab === "agents") {
    try {
      var reports = await fetchReports();
      renderReportsTree(reports);
    } catch (e) {
      console.warn("Reports fetch failed:", e.message);
    }
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
  if (viewParam && (viewParam === "agents" || viewParam === "events" || viewParam === "queue")) {
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
