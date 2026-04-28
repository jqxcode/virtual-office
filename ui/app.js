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
var activeTopTab = "team";
var lastDashboard = null;
var scheduleData = null;
var MAX_SCHEDULE_ROWS = 20;
var selectedAgentFilter = null;
var isDragging = false;

// --- Schedules V2 state ---
var v2UpcomingPage = 0;
var v2UpcomingPageSize = 20;
var v2PastPage = 0;
var v2PastPageSize = 20;
var v2PastEvents = [];

// --- Office tab state ---
var officeClockInterval = null;
var officeElapsedIntervals = [];

// --- History tab state ---
var historyRuns = [];
var historyPage = 0;
var historyPageSize = 20;
var historySortCol = "start";
var historySortAsc = false;

// --- Schedule tab state ---
var scheduleV2Page = 0;
var scheduleV2PageSize = 20;

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
  if (!path) return path;
  // Normalize to forward slashes first
  var normalized = path.replace(/\\/g, "/");
  // Handle full Windows paths (e.g. Q:/src/.../virtual-office/output/...)
  var outputIdx = normalized.indexOf("/output/");
  if (outputIdx >= 0) {
    return normalized.substring(outputIdx + "/output/".length);
  }
  // Handle relative output/ prefix
  if (normalized.startsWith("output/")) {
    return normalized.substring("output/".length);
  }
  return normalized;
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

  // Load data when switching to team tab
  if (tabName === "team") {
    renderTeamTab();
  }

  // Load data when switching to office tab
  if (tabName === "office") {
    renderOfficeTab();
    startOfficeClock();
  } else {
    stopOfficeClock();
  }

  // Load data when switching to history tab
  if (tabName === "history") {
    loadScheduleData().then(function() {});
    fetchAllEvents().then(function(evts) {
      allEvents = evts;
      buildHistoryRuns();
      renderHistoryHealthCards();
      populateHistoryFilters();
      renderHistoryTable();
    }).catch(function(e) { console.warn("History events fetch failed:", e.message); });
  }

  // Load data when switching to schedule tab
  if (tabName === "schedule") {
    loadScheduleData().then(function() {
      if (allEvents.length === 0) {
        loadAllEvents().then(function() {
          populateScheduleV2AgentFilter();
          renderScheduleV2Tab();
        });
      } else {
        populateScheduleV2AgentFilter();
        renderScheduleV2Tab();
      }
    });
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

      var runId = evt.run_id || (evt.details && evt.details.run_id) || null;

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

// --- Agents V2: Queue Cards ---

function renderV2QueueCards() {
  if (!scheduleData) return;
  var queues = scheduleData.queues || {};
  var config = scheduleData.config || agentConfig;
  var mergedAgents = scheduleData.merged || {};
  var schedules = scheduleData.schedules || [];
  var container = document.getElementById("v2-queue-cards");
  if (!container) return;
  container.innerHTML = "";

  var totalQueueDepth = 0;
  var agentNames = [];
  if (config && config.agents) {
    agentNames = Object.keys(config.agents);
  }
  agentNames.sort(function(a, b) {
    return a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0;
  });

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

    // Header
    var header = document.createElement("div");
    header.className = "queue-card-header";
    var nameSpan = document.createElement("span");
    nameSpan.className = "queue-card-name";
    nameSpan.textContent = agentData.display_name || agentCfg.displayName || agentName;
    nameSpan.style.color = agentColor;
    makeClickToCopy(nameSpan);
    header.appendChild(nameSpan);

    var statusDot = document.createElement("span");
    statusDot.className = "queue-card-dot " + agentStatus;
    header.appendChild(statusDot);
    card.appendChild(header);

    card.dataset.agent = agentName;

    // Running job info
    var runningJobName = null;
    if (agentData.running_job) {
      runningJobName = agentData.running_job.job || agentData.running_job.name || null;
    }

    if (runningJobName) {
      var lockDiv = document.createElement("div");
      lockDiv.className = "queue-card-lock";
      var lockDot = document.createElement("span");
      lockDot.className = "lock-indicator locked";
      var lockText = document.createElement("span");
      lockText.textContent = "Locked by " + runningJobName;
      lockDiv.appendChild(lockDot);
      lockDiv.appendChild(lockText);

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
      card.appendChild(runInfoDiv);
      card.appendChild(lockDiv);
    }

    // Job queue list
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

      var depth = job.queueDepth || 0;
      totalQueueDepth += depth;

      if (depth > 0) {
        var depthBadge = document.createElement("span");
        depthBadge.className = "queue-depth";
        depthBadge.textContent = depth + " queued";
        jobRow.appendChild(depthBadge);
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

  var totalBadge = document.getElementById("v2-queue-total-badge");
  if (totalBadge) totalBadge.textContent = totalQueueDepth;
}

// --- Agents V2: Reports ---

var v2ReportsRows = [];
var v2ReportsSortCol = 2;
var v2ReportsSortAsc = false;

function populateV2ReportsFilters(rows) {
  var agentSel = document.getElementById("v2-reports-agent-filter");
  var jobSel = document.getElementById("v2-reports-job-filter");
  if (!agentSel || !jobSel) return;

  var agents = {};
  var jobs = {};
  rows.forEach(function(r) {
    agents[r.agent] = true;
    jobs[r.job] = true;
  });

  var currentAgent = agentSel.value;
  agentSel.innerHTML = '<option value="">All Agents</option>';
  Object.keys(agents).sort().forEach(function(a) {
    var opt = document.createElement("option");
    opt.value = a;
    opt.textContent = a;
    agentSel.appendChild(opt);
  });
  agentSel.value = currentAgent;

  var currentJob = jobSel.value;
  jobSel.innerHTML = '<option value="">All Jobs</option>';
  Object.keys(jobs).sort().forEach(function(j) {
    var opt = document.createElement("option");
    opt.value = j;
    opt.textContent = j;
    jobSel.appendChild(opt);
  });
  jobSel.value = currentJob;
}

function getV2FilteredSortedReports() {
  var search = (document.getElementById("v2-reports-search") || {}).value || "";
  search = search.toLowerCase();
  var agentFilter = (document.getElementById("v2-reports-agent-filter") || {}).value || "";
  var jobFilter = (document.getElementById("v2-reports-job-filter") || {}).value || "";
  var dateFilter = (document.getElementById("v2-reports-date-filter") || {}).value || "";

  var filtered = v2ReportsRows.filter(function(r) {
    if (agentFilter && r.agent !== agentFilter) return false;
    if (jobFilter && r.job !== jobFilter) return false;
    if (dateFilter && r.date && r.date.indexOf(dateFilter) !== 0) return false;
    if (search && r.name.toLowerCase().indexOf(search) === -1 &&
        r.job.toLowerCase().indexOf(search) === -1 &&
        r.agent.toLowerCase().indexOf(search) === -1) return false;
    return true;
  });

  var col = v2ReportsSortCol;
  var asc = v2ReportsSortAsc;
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

function renderV2ReportsTable() {
  var container = document.getElementById("v2-reports-tree");
  if (!container) return;

  var filtered = getV2FilteredSortedReports();
  var badge = document.getElementById("v2-reports-badge");
  if (badge) badge.textContent = filtered.length + "/" + v2ReportsRows.length;

  if (filtered.length === 0) {
    container.innerHTML = '<div class="placeholder-message">No reports found</div>';
    return;
  }

  var cols = ["Agent", "Job", "Date", "Report", "Size"];
  var html = '<table id="v2-reports-table"><thead><tr>';
  cols.forEach(function(c, i) {
    var cls = "";
    if (i === v2ReportsSortCol) cls = v2ReportsSortAsc ? " class=\"sort-asc\"" : " class=\"sort-desc\"";
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
  var ths = container.querySelectorAll("#v2-reports-table th");
  ths.forEach(function(th) {
    th.addEventListener("click", function() {
      var col = parseInt(th.getAttribute("data-col"));
      if (col === v2ReportsSortCol) {
        v2ReportsSortAsc = !v2ReportsSortAsc;
      } else {
        v2ReportsSortCol = col;
        v2ReportsSortAsc = col === 4 ? false : true;
      }
      renderV2ReportsTable();
    });
  });
}

function renderV2ReportsTree(data) {
  v2ReportsRows = flattenReports(data);
  populateV2ReportsFilters(v2ReportsRows);
  renderV2ReportsTable();
}

// --- Schedules V2 renderers ---

function getV2UpcomingItems() {
  if (!scheduleData) return [];
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
      allItems.push({
        fireTime: null, agent: agent, job: job, cron: cron,
        cronHuman: cronHuman, description: description,
        enabled: false, status: "disabled"
      });
      return;
    }

    fires.forEach(function(fireTime) {
      allItems.push({
        fireTime: fireTime, agent: agent, job: job, cron: cron,
        cronHuman: cronHuman, description: description,
        enabled: true, status: "scheduled"
      });
    });
  });

  // Cross-reference with merged agent state
  var mergedAgents = scheduleData.merged || {};
  var runningMarked = {};
  var queuedMarked = {};

  allItems.forEach(function(item) {
    if (!item.enabled) return;
    var key = item.agent + "/" + item.job;
    var agentData = mergedAgents[item.agent];
    if (!agentData) return;
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

  return allItems;
}

function renderV2UpcomingSchedule() {
  var allItems = getV2UpcomingItems();
  var totalCount = allItems.length;
  var showCount = v2UpcomingPageSize * (v2UpcomingPage + 1);
  var displayItems = allItems.slice(0, showCount);

  var tbody = document.getElementById("v2-upcoming-tbody");
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
            loadScheduleData().then(function() { renderV2UpcomingSchedule(); });
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
          loadScheduleData().then(function() { renderV2UpcomingSchedule(); });
        });
      });
      tdAction.appendChild(cancelBtn);
    }
    tr.appendChild(tdAction);

    tbody.appendChild(tr);
  });

  // Update count badge
  var countEl = document.getElementById("v2-upcoming-count");
  if (countEl) countEl.textContent = totalCount;

  // Show/hide "Show more" button
  var showMoreEl = document.getElementById("v2-upcoming-show-more");
  if (showMoreEl) {
    showMoreEl.style.display = (showCount < totalCount) ? "" : "none";
  }
}

function getV2PastFilteredEvents() {
  var agentFilter = document.getElementById("v2-past-agent-filter");
  var typeFilter = document.getElementById("v2-past-type-filter");
  var timeFilter = document.getElementById("v2-past-time-filter");

  var agentVal = agentFilter ? agentFilter.value : "";
  var typeVal = typeFilter ? typeFilter.value : "";
  var timeVal = timeFilter ? timeFilter.value : "";

  var now = Date.now();
  var timeMs = 0;
  if (timeVal === "1h") timeMs = 3600000;
  else if (timeVal === "6h") timeMs = 21600000;
  else if (timeVal === "24h") timeMs = 86400000;
  else if (timeVal === "7d") timeMs = 604800000;

  return allEvents.filter(function(evt) {
    if (agentVal && canonicalAgentName(evt.agent) !== agentVal) return false;
    var evtType = evt.type || evt.event || "";
    if (typeVal && evtType !== typeVal) return false;
    if (timeMs) {
      var evtTime = new Date(evt.timestamp || evt.ts || evt.time).getTime();
      if (now - evtTime > timeMs) return false;
    }
    return true;
  });
}

function buildJobOutputLookup() {
  // Build a map: "agent/job" -> lastOutput path from merged dashboard state
  // This uses the same normalized job data the Agents tab uses
  var lookup = {};
  var merged = null;
  if (scheduleData && scheduleData.merged) {
    merged = scheduleData.merged;
  } else if (lastDashboard && agentConfig) {
    merged = mergeConfigAndDashboard(agentConfig, lastDashboard);
  }
  if (!merged) return lookup;

  Object.keys(merged).forEach(function(agentName) {
    var agentData = merged[agentName];
    var agentLower = agentName.toLowerCase();
    (agentData.jobs || []).forEach(function(job) {
      if (job.lastOutput) {
        var normalizedOut = job.lastOutput.replace(/\\/g, "/").toLowerCase();
        var fileName = normalizedOut.split("/").pop() || "";
        var jobLower = (job.name || "").toLowerCase().replace(/^todo-/, "");
        // Valid: in agent subdir, or root file matching job/agent name (not -latest)
        var inAgentDir = normalizedOut.indexOf("/" + agentLower + "/") >= 0;
        var rootMatch = (fileName.indexOf(jobLower) === 0 || fileName.indexOf(agentLower + "-") === 0) && fileName.indexOf("-latest") < 0;
        if (inAgentDir || rootMatch) {
          var key = agentName + "/" + job.name;
          lookup[key] = job.lastOutput;
        }
      }
    });
  });
  return lookup;
}

function renderV2PastSchedule() {
  var filtered = getV2PastFilteredEvents();
  var totalCount = filtered.length;
  var showCount = v2PastPageSize * (v2PastPage + 1);
  var log = document.getElementById("v2-past-log");

  // Update count badge
  var countEl = document.getElementById("v2-past-count");
  if (countEl) {
    countEl.textContent = totalCount + " event" + (totalCount !== 1 ? "s" : "");
  }

  if (!filtered || filtered.length === 0) {
    if (log) log.innerHTML = '<div class="placeholder-message">No events match filters</div>';
    var showMoreEl = document.getElementById("v2-past-show-more");
    if (showMoreEl) showMoreEl.style.display = "none";
    return;
  }

  if (log) log.innerHTML = "";

  // Build job->output lookup from merged dashboard state
  var jobOutputLookup = buildJobOutputLookup();

  // Show newest first, paginated
  var reversed = filtered.slice().reverse();
  var displayItems = reversed.slice(0, showCount);

  displayItems.forEach(function(evt) {
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

    // Report link for completed events - use lastOutput from dashboard state
    if (evtType === "completed") {
      var outputKey = evtAgentName + "/" + (evt.job || "");
      var lastOutput = jobOutputLookup[outputKey];
      if (lastOutput) {
        var reportLink = document.createElement("a");
        reportLink.className = "report-link";
        reportLink.href = getReportHref(lastOutput);
        reportLink.target = "_blank";
        reportLink.textContent = "Report";
        reportLink.title = lastOutput;
        reportLink.addEventListener("click", function(e) { e.stopPropagation(); });
        row.appendChild(reportLink);
      }
    }

    log.appendChild(row);
  });

  // Show/hide "Show more" button
  var showMoreEl = document.getElementById("v2-past-show-more");
  if (showMoreEl) {
    showMoreEl.style.display = (showCount < totalCount) ? "" : "none";
  }
}

function populateV2PastAgentFilter() {
  var select = document.getElementById("v2-past-agent-filter");
  if (!select) return;
  var agents = {};
  allEvents.forEach(function(evt) {
    if (evt.agent) agents[canonicalAgentName(evt.agent)] = true;
  });
  if (agentConfig && agentConfig.agents) {
    Object.keys(agentConfig.agents).forEach(function(name) {
      agents[name] = true;
    });
  }
  var current = canonicalAgentName(select.value);
  while (select.options.length > 1) select.remove(1);
  Object.keys(agents).sort().forEach(function(name) {
    var opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    select.appendChild(opt);
  });
  select.value = current;
}

// --- TEAM Tab ---
function cronToShortHuman(cronExpr) {
  if (!cronExpr || typeof cronExpr !== "string") return String(cronExpr);
  var parts = cronExpr.trim().split(/\s+/);
  if (parts.length !== 5) return cronExpr;
  var min = parts[0], hour = parts[1], dom = parts[2], month = parts[3], dow = parts[4];
  function fmt12(h, m) {
    var hi = parseInt(h, 10), mi = parseInt(m, 10);
    var ampm = hi >= 12 ? "pm" : "am";
    var h12 = hi % 12; if (h12 === 0) h12 = 12;
    if (mi === 0) return h12 + ampm;
    return h12 + ":" + (mi < 10 ? "0" : "") + mi + ampm;
  }
  if (/^\d+$/.test(min) && hour === "*" && dom === "*" && month === "*" && dow === "*") {
    var mi3 = parseInt(min, 10);
    return "hourly at :" + (mi3 < 10 ? "0" : "") + mi3;
  }
  if (/^\d+$/.test(min) && /^\d+$/.test(hour) && dom === "*" && month === "*") {
    var timeStr = fmt12(hour, min);
    if (dow === "*") return "daily " + timeStr;
    if (dow === "1-5") return "weekdays " + timeStr;
    if (dow === "0,6") return "weekends " + timeStr;
    var dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    if (/^\d$/.test(dow)) return dayNames[parseInt(dow, 10)] + " " + timeStr;
    if (dow === "1") return "Mon " + timeStr;
  }
  if (/^\d+$/.test(min) && /^\d+$/.test(hour) && dom === "L") {
    return "monthly (last day) " + fmt12(hour, min);
  }
  return cronToHuman(cronExpr);
}
function initTeamDragDrop() {
  var listEl = document.getElementById("team-agent-list");
  if (!listEl || listEl._dragInitialized) return;
  listEl._dragInitialized = true;
  listEl.addEventListener("dragover", function(e) {
    e.preventDefault(); e.dataTransfer.dropEffect = "move";
    var tc = e.target.closest(".team-agent-card");
    listEl.querySelectorAll(".team-agent-card").forEach(function(c) { c.classList.remove("drag-over"); });
    if (tc && !tc.classList.contains("dragging")) tc.classList.add("drag-over");
  });
  listEl.addEventListener("dragleave", function(e) {
    var tc = e.target.closest(".team-agent-card"); if (tc) tc.classList.remove("drag-over");
  });
  listEl.addEventListener("drop", function(e) {
    e.preventDefault();
    listEl.querySelectorAll(".team-agent-card").forEach(function(c) { c.classList.remove("drag-over"); });
    var dn = e.dataTransfer.getData("text/plain"); if (!dn) return;
    var dc = listEl.querySelector('[data-agent="' + dn + '"]'); if (!dc) return;
    var tc = e.target.closest(".team-agent-card"); if (!tc || tc === dc) return;
    var r = tc.getBoundingClientRect();
    if (e.clientY < r.top + r.height / 2) listEl.insertBefore(dc, tc);
    else listEl.insertBefore(dc, tc.nextSibling);
    var no = []; listEl.querySelectorAll(".team-agent-card").forEach(function(c) { if (c.dataset.agent) no.push(c.dataset.agent); });
    try { localStorage.setItem("vo-team-order", JSON.stringify(no)); } catch (e2) {}
  });
}
function renderTeamTab() {
  if (!agentConfig || !agentConfig.agents) return;
  var config = agentConfig;
  var schedules = (scheduleData && scheduleData.schedules) ? scheduleData.schedules : [];
  if (schedules.length === 0) {
    fetchConfig().then(function(cfg) { agentConfig = cfg; return fetchSchedules(); })
      .then(function(sData) { scheduleData = sData; renderTeamTab(); })
      .catch(function(e) { console.warn("Team tab: schedule fetch failed:", e.message); });
  }
  var agentNames = Object.keys(config.agents);
  var savedOrder = null;
  try { var raw = localStorage.getItem("vo-team-order"); if (raw) savedOrder = JSON.parse(raw); } catch (e) {}
  if (Array.isArray(savedOrder) && savedOrder.length > 0) {
    agentNames.sort(function(a, b) {
      var ia = savedOrder.indexOf(a), ib = savedOrder.indexOf(b);
      if (ia === -1) ia = 9999; if (ib === -1) ib = 9999; return ia - ib;
    });
  }
  var scheduleLookup = {};
  schedules.forEach(function(s) {
    if (!scheduleLookup[s.agent]) scheduleLookup[s.agent] = {};
    if (!scheduleLookup[s.agent][s.job]) scheduleLookup[s.agent][s.job] = [];
    scheduleLookup[s.agent][s.job].push({ cron: s.cron, description: s.description || "", enabled: s.enabled !== false });
  });
  var overviewEl = document.getElementById("team-overview");
  var hooksCount = 0;
  if (config.hooks) { Object.keys(config.hooks).forEach(function(k) { if (Array.isArray(config.hooks[k])) hooksCount += config.hooks[k].length; }); }
  var enabledSchedules = schedules.filter(function(s) { return s.enabled !== false; });
  var overviewText = agentNames.length + " agents \u2022 " + enabledSchedules.length + " scheduled jobs";
  if (hooksCount > 0) overviewText += " \u2022 " + hooksCount + " hook" + (hooksCount > 1 ? "s" : "");
  if (overviewEl) overviewEl.textContent = overviewText;
  var listEl = document.getElementById("team-agent-list");
  if (!listEl || isDragging) return;
  initTeamDragDrop();
  listEl.innerHTML = "";
  agentNames.forEach(function(name) {
    var agentCfg = config.agents[name]; var color = getAgentColor(name);
    var card = document.createElement("div"); card.className = "team-agent-card";
    card.dataset.agent = name; card.style.borderLeftColor = color; card.setAttribute("draggable", "true");
    var dh = document.createElement("span"); dh.className = "drag-handle"; dh.textContent = "\u2630";
    dh.title = "Drag to reorder"; dh.setAttribute("draggable", "false");
    card.addEventListener("dragstart", function(e) {
      if (!card._handleMouseDown) { e.preventDefault(); return; }
      isDragging = true; e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", name); card.classList.add("dragging");
    });
    card.addEventListener("dragend", function() {
      isDragging = false; card._handleMouseDown = false; card.classList.remove("dragging");
      listEl.querySelectorAll(".team-agent-card").forEach(function(c) { c.classList.remove("drag-over"); });
    });
    dh.addEventListener("mousedown", function() { card._handleMouseDown = true; });
    document.addEventListener("mouseup", function() { card._handleMouseDown = false; });
    var hdr = document.createElement("div"); hdr.className = "team-card-header";
    hdr.appendChild(dh);
    var ne = document.createElement("span"); ne.className = "team-card-name";
    ne.textContent = agentCfg.displayName || name; ne.style.color = color;
    hdr.appendChild(ne); card.appendChild(hdr);
    if (agentCfg.description) {
      var de = document.createElement("div"); de.className = "team-card-description";
      de.textContent = agentCfg.description; card.appendChild(de);
    }
    var agentJobs = scheduleLookup[name] || {}; var jobNames = Object.keys(agentJobs);
    if (agentCfg.jobs) { Object.keys(agentCfg.jobs).forEach(function(jn) { if (jobNames.indexOf(jn) === -1) jobNames.push(jn); }); }
    if (jobNames.length > 0) {
      var sl = document.createElement("div"); sl.className = "team-skills-label";
      sl.textContent = "Skills"; card.appendChild(sl);
      var tbl = document.createElement("table"); tbl.className = "team-skills-table";
      var thd = document.createElement("thead"); var thr = document.createElement("tr");
      ["Job", "Schedule", "Description"].forEach(function(h) { var th = document.createElement("th"); th.textContent = h; thr.appendChild(th); });
      thd.appendChild(thr); tbl.appendChild(thd);
      var tbd = document.createElement("tbody");
      jobNames.forEach(function(jobName) {
        var se = agentJobs[jobName] || [];
        var jc = (agentCfg.jobs && agentCfg.jobs[jobName]) ? agentCfg.jobs[jobName] : null;
        var desc = (se.length > 0 && se[0].description) ? se[0].description : (jc && jc.description ? jc.description : "");
        function mkNameCell(jn) {
          var td = document.createElement("td");
          var sp = document.createElement("span"); sp.className = "team-skill-name"; sp.textContent = jn;
          var ci = document.createElement("span"); ci.className = "copy-icon"; ci.textContent = "\u2398"; sp.appendChild(ci);
          sp.addEventListener("click", function() {
            navigator.clipboard.writeText(jn).then(function() {
              sp.classList.add("team-skill-copied");
              setTimeout(function() { sp.classList.remove("team-skill-copied"); }, 600);
            });
          });
          td.appendChild(sp); return td;
        }
        if (se.length === 0) {
          var tr = document.createElement("tr"); tr.appendChild(mkNameCell(jobName));
          var ts = document.createElement("td"); ts.className = "team-skill-schedule"; ts.textContent = "manual"; tr.appendChild(ts);
          var td = document.createElement("td"); td.className = "team-skill-desc"; td.textContent = desc; td.title = desc; tr.appendChild(td);
          tbd.appendChild(tr);
        } else {
          se.forEach(function(sched, idx) {
            var tr = document.createElement("tr");
            if (idx === 0) tr.appendChild(mkNameCell(jobName)); else tr.appendChild(document.createElement("td"));
            var ts = document.createElement("td"); ts.className = "team-skill-schedule";
            if (sched.enabled === false) { ts.textContent = "disabled"; ts.style.color = "#484f58"; ts.style.fontStyle = "italic"; }
            else { ts.textContent = cronToShortHuman(sched.cron); ts.title = sched.cron; }
            tr.appendChild(ts);
            var td = document.createElement("td"); td.className = "team-skill-desc";
            if (idx === 0) { td.textContent = desc; td.title = desc; } tr.appendChild(td); tbd.appendChild(tr);
          });
        }
      });
      tbl.appendChild(tbd); card.appendChild(tbl);
    }
    var ft = document.createElement("div"); ft.className = "team-card-footer";
    ft.textContent = "Stale timeout: " + (agentCfg.staleLockTimeoutMinutes || "N/A") + " min  \u2022  Group: " + (agentCfg.group || "Agents");
    card.appendChild(ft); listEl.appendChild(card);
  });

  // Render hooks section below agent cards
  var hooks = config.hooks;
  if (hooks) {
    var hookTypes = Object.keys(hooks);
    if (hookTypes.length > 0) {
      var hooksCard = document.createElement("div"); hooksCard.className = "team-hooks-card";
      hooksCard.style.gridColumn = "1 / -1"; // span full width
      var hooksHdr = document.createElement("div"); hooksHdr.className = "team-card-header";
      var hookIcon = document.createElement("span"); hookIcon.textContent = "\u26A1"; hookIcon.style.marginRight = "0.5rem";
      hooksHdr.appendChild(hookIcon);
      var hookTitle = document.createElement("span"); hookTitle.className = "team-card-name";
      hookTitle.textContent = "Hooks"; hookTitle.style.color = "#f0883e";
      hooksHdr.appendChild(hookTitle); hooksCard.appendChild(hooksHdr);
      hookTypes.forEach(function(hookType) {
        var hookList = hooks[hookType];
        if (!Array.isArray(hookList) || hookList.length === 0) return;
        var typeLabel = document.createElement("div"); typeLabel.className = "team-hooks-type";
        typeLabel.textContent = hookType; hooksCard.appendChild(typeLabel);
        var tbl = document.createElement("table"); tbl.className = "team-skills-table";
        var thd = document.createElement("thead"); var thr = document.createElement("tr");
        ["Hook", "Trigger", "Description"].forEach(function(h) { var th = document.createElement("th"); th.textContent = h; thr.appendChild(th); });
        thd.appendChild(thr); tbl.appendChild(thd);
        var tbd = document.createElement("tbody");
        hookList.forEach(function(hook) {
          var tr = document.createElement("tr");
          var tdName = document.createElement("td");
          var nameSpan = document.createElement("span"); nameSpan.className = "team-skill-name"; nameSpan.textContent = hook.name;
          tdName.appendChild(nameSpan); tr.appendChild(tdName);
          var tdTrigger = document.createElement("td"); tdTrigger.className = "team-skill-schedule"; tdTrigger.textContent = hook.trigger || ""; tr.appendChild(tdTrigger);
          var tdDesc = document.createElement("td"); tdDesc.className = "team-skill-desc"; tdDesc.textContent = hook.description || ""; tdDesc.title = hook.description || ""; tr.appendChild(tdDesc);
          tbd.appendChild(tr);
        });
        tbl.appendChild(tbd); hooksCard.appendChild(tbl);
      });
      listEl.appendChild(hooksCard);
    }
  }
}

// --- OFFICE Tab ---
function startOfficeClock() {
  stopOfficeClock(); updateOfficeClock();
  officeClockInterval = setInterval(function() { updateOfficeClock(); updateOfficeElapsed(); }, 1000);
}
function stopOfficeClock() {
  if (officeClockInterval) { clearInterval(officeClockInterval); officeClockInterval = null; }
  officeElapsedIntervals = [];
}
function updateOfficeClock() {
  var el = document.getElementById("office-clock"); if (!el) return;
  el.textContent = new Date().toLocaleString("en-US", { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", second: "2-digit", hour12: true, timeZone: "America/Los_Angeles" }) + " PST";
}
function updateOfficeElapsed() {
  document.querySelectorAll(".office-desk.working .office-desk-elapsed").forEach(function(el) {
    var sa = el.dataset.startedAt; if (!sa) return;
    var elapsed = Math.max(0, Math.floor((Date.now() - new Date(sa).getTime()) / 1000));
    el.textContent = Math.floor(elapsed / 60) + ":" + (elapsed % 60 < 10 ? "0" : "") + (elapsed % 60);
  });
}
function formatRelativeTime(timestamp) {
  if (!timestamp) return "";
  var diff = Math.max(0, Math.floor((Date.now() - new Date(timestamp).getTime()) / 1000));
  if (diff < 60) return "done " + diff + "s ago";
  if (diff < 3600) return "done " + Math.floor(diff / 60) + "m ago";
  if (diff < 86400) return "done " + Math.floor(diff / 3600) + "h ago";
  return "done " + Math.floor(diff / 86400) + "d ago";
}
function getRobotSvg(state, color) {
  // Vivid robot scenes: working (at desk with monitor), idle (coffee break), sleeping (in bed)
  var c = color || "#8b949e";
  if (state === "working") {
    // Robot sitting at desk, typing on keyboard, monitor glowing
    return '<svg viewBox="0 0 120 100" xmlns="http://www.w3.org/2000/svg" class="office-robot">' +
      // Desk
      '<rect x="10" y="68" width="100" height="5" rx="2" fill="#484f58"/>' +
      '<rect x="18" y="73" width="4" height="20" fill="#30363d"/><rect x="98" y="73" width="4" height="20" fill="#30363d"/>' +
      // Monitor
      '<rect x="30" y="32" width="40" height="30" rx="3" fill="#1a1a2e" stroke="#58a6ff" stroke-width="1.5"/>' +
      '<rect x="34" y="36" width="32" height="22" rx="1" fill="#0d1117"/>' +
      // Code lines on screen (animated)
      '<rect x="37" y="39" width="18" height="2" rx="1" fill="#22c55e" opacity="0.8"><animate attributeName="width" values="18;12;22;18" dur="1.5s" repeatCount="indefinite"/></rect>' +
      '<rect x="37" y="43" width="12" height="2" rx="1" fill="#58a6ff" opacity="0.6"><animate attributeName="width" values="12;20;8;12" dur="2s" repeatCount="indefinite"/></rect>' +
      '<rect x="37" y="47" width="24" height="2" rx="1" fill="#22c55e" opacity="0.5"><animate attributeName="width" values="24;16;24" dur="1.8s" repeatCount="indefinite"/></rect>' +
      '<rect x="37" y="51" width="8" height="2" rx="1" fill="#f0883e" opacity="0.7"/>' +
      // Monitor stand
      '<rect x="47" y="62" width="6" height="6" fill="#30363d"/>' +
      '<rect x="42" y="66" width="16" height="3" rx="1" fill="#30363d"/>' +
      // Keyboard
      '<rect x="32" y="64" width="10" height="4" rx="1" fill="#21262d" stroke="#484f58" stroke-width="0.5"/>' +
      '<rect x="58" y="64" width="10" height="4" rx="1" fill="#21262d" stroke="#484f58" stroke-width="0.5"/>' +
      // Robot body (sitting in chair)
      // Chair
      '<rect x="70" y="52" width="30" height="3" rx="1" fill="#21262d"/>' +
      '<rect x="97" y="35" width="3" height="20" rx="1" fill="#21262d"/>' +
      '<rect x="84" y="73" width="3" height="18" fill="#21262d"/>' +
      // Robot torso
      '<rect x="74" y="38" width="20" height="16" rx="4" fill="' + c + '" opacity="0.8"/>' +
      // Robot head
      '<rect x="76" y="18" width="16" height="18" rx="5" fill="' + c + '"/>' +
      // Antenna
      '<line x1="84" y1="12" x2="84" y2="18" stroke="' + c + '" stroke-width="2"/>' +
      '<circle cx="84" cy="10" r="3" fill="' + c + '"><animate attributeName="r" values="3;4;3" dur="1s" repeatCount="indefinite"/></circle>' +
      // Eyes (focused on screen, looking left)
      '<circle cx="80" cy="27" r="3" fill="#fff"/><circle cx="88" cy="27" r="3" fill="#fff"/>' +
      '<circle cx="79" cy="27" r="1.5" fill="#1a1a2e"/><circle cx="87" cy="27" r="1.5" fill="#1a1a2e"/>' +
      // Smile
      '<path d="M80 32 Q84 36 88 32" stroke="#22c55e" stroke-width="1.5" fill="none"/>' +
      // Arms reaching to keyboard (animated)
      '<rect x="68" y="44" width="8" height="5" rx="2" fill="' + c + '" opacity="0.7">' +
        '<animateTransform attributeName="transform" type="rotate" values="-3,72,46;3,72,46;-3,72,46" dur="0.5s" repeatCount="indefinite"/></rect>' +
      '<rect x="92" y="44" width="8" height="5" rx="2" fill="' + c + '" opacity="0.7">' +
        '<animateTransform attributeName="transform" type="rotate" values="3,96,46;-3,96,46;3,96,46" dur="0.5s" repeatCount="indefinite"/></rect>' +
      // Legs on chair
      '<rect x="76" y="54" width="7" height="12" rx="2" fill="' + c + '" opacity="0.6"/>' +
      '<rect x="86" y="54" width="7" height="12" rx="2" fill="' + c + '" opacity="0.6"/>' +
      // Screen glow effect
      '<rect x="30" y="32" width="40" height="30" rx="3" fill="' + c + '" opacity="0.05"><animate attributeName="opacity" values="0.03;0.08;0.03" dur="2s" repeatCount="indefinite"/></rect>' +
      '</svg>';
  } else if (state === "sleeping") {
    // Robot in bed with blanket, pillow, ZZZ
    return '<svg viewBox="0 0 120 100" xmlns="http://www.w3.org/2000/svg" class="office-robot">' +
      // Bed frame
      '<rect x="10" y="55" width="100" height="35" rx="4" fill="#21262d" stroke="#30363d" stroke-width="1"/>' +
      // Headboard
      '<rect x="8" y="40" width="8" height="50" rx="3" fill="#30363d"/>' +
      '<rect x="104" y="55" width="8" height="35" rx="3" fill="#30363d"/>' +
      // Mattress
      '<rect x="14" y="58" width="92" height="28" rx="3" fill="#161b22"/>' +
      // Pillow
      '<rect x="16" y="52" width="28" height="14" rx="6" fill="#484f58"/>' +
      '<rect x="18" y="54" width="24" height="10" rx="5" fill="#586069"/>' +
      // Blanket (covers most of body)
      '<rect x="14" y="62" width="92" height="22" rx="3" fill="' + c + '" opacity="0.35"/>' +
      '<path d="M14 65 Q60 58 106 65" fill="' + c + '" opacity="0.25"/>' +
      // Robot head on pillow (sideways)
      '<rect x="22" y="48" width="18" height="16" rx="6" fill="' + c + '" opacity="0.9"/>' +
      // Antenna (droopy, relaxed)
      '<path d="M31 44 Q28 38 24 40" stroke="' + c + '" stroke-width="2" fill="none" stroke-linecap="round"/>' +
      '<circle cx="24" cy="40" r="2.5" fill="' + c + '" opacity="0.6"/>' +
      // Closed eyes (happy sleeping)
      '<path d="M26 54 Q28 52 30 54" stroke="#fff" stroke-width="1.5" fill="none" opacity="0.6"/>' +
      '<path d="M33 54 Q35 52 37 54" stroke="#fff" stroke-width="1.5" fill="none" opacity="0.6"/>' +
      // Peaceful smile
      '<path d="M28 58 Q31 60 34 58" stroke="#484f58" stroke-width="1" fill="none"/>' +
      // Feet poking out of blanket
      '<rect x="92" y="70" width="8" height="6" rx="3" fill="' + c + '" opacity="0.5"/>' +
      '<rect x="92" y="78" width="8" height="6" rx="3" fill="' + c + '" opacity="0.5"/>' +
      // ZZZ (floating, animated)
      '<text x="48" y="42" font-size="14" fill="' + c + '" opacity="0.7" font-weight="bold" font-family="monospace">' +
        'Z<animate attributeName="y" values="42;38;42" dur="2s" repeatCount="indefinite"/>' +
        '<animate attributeName="opacity" values="0.7;0.3;0.7" dur="2s" repeatCount="indefinite"/></text>' +
      '<text x="60" y="32" font-size="11" fill="' + c + '" opacity="0.5" font-weight="bold" font-family="monospace">' +
        'Z<animate attributeName="y" values="32;28;32" dur="2.5s" repeatCount="indefinite"/>' +
        '<animate attributeName="opacity" values="0.5;0.2;0.5" dur="2.5s" repeatCount="indefinite"/></text>' +
      '<text x="70" y="24" font-size="8" fill="' + c + '" opacity="0.3" font-weight="bold" font-family="monospace">' +
        'Z<animate attributeName="y" values="24;20;24" dur="3s" repeatCount="indefinite"/>' +
        '<animate attributeName="opacity" values="0.3;0.1;0.3" dur="3s" repeatCount="indefinite"/></text>' +
      // Moon and star (nighttime ambiance)
      '<circle cx="100" cy="20" r="8" fill="#f0c040" opacity="0.15"/>' +
      '<circle cx="96" cy="18" r="7" fill="#0d1117"/>' +
      '<polygon points="85,15 86,18 89,18 87,20 88,23 85,21 82,23 83,20 81,18 84,18" fill="#f0c040" opacity="0.12"/>' +
      '</svg>';
  } else {
    // Idle: Robot having coffee break, leaning on counter
    return '<svg viewBox="0 0 120 100" xmlns="http://www.w3.org/2000/svg" class="office-robot">' +
      // Floor
      '<rect x="0" y="88" width="120" height="12" fill="#161b22"/>' +
      // Counter/table
      '<rect x="5" y="60" width="50" height="5" rx="2" fill="#484f58"/>' +
      '<rect x="10" y="65" width="4" height="23" fill="#30363d"/><rect x="46" y="65" width="4" height="23" fill="#30363d"/>' +
      // Coffee mug on counter
      '<rect x="18" y="48" width="14" height="12" rx="2" fill="#f0883e" opacity="0.8"/>' +
      '<rect x="14" y="48" width="22" height="3" rx="1" fill="#f0883e" opacity="0.9"/>' +
      '<path d="M32 52 Q38 52 38 56 Q38 60 32 58" stroke="#f0883e" stroke-width="2" fill="none" opacity="0.6"/>' +
      // Steam from coffee (animated)
      '<path d="M22 44 Q24 38 22 32" stroke="#8b949e" stroke-width="1.5" fill="none" opacity="0.3">' +
        '<animate attributeName="d" values="M22 44 Q24 38 22 32;M22 44 Q20 38 22 32;M22 44 Q24 38 22 32" dur="2s" repeatCount="indefinite"/>' +
        '<animate attributeName="opacity" values="0.3;0.1;0.3" dur="2s" repeatCount="indefinite"/></path>' +
      '<path d="M27 44 Q25 36 27 30" stroke="#8b949e" stroke-width="1" fill="none" opacity="0.2">' +
        '<animate attributeName="d" values="M27 44 Q25 36 27 30;M27 44 Q29 36 27 30;M27 44 Q25 36 27 30" dur="2.5s" repeatCount="indefinite"/>' +
        '<animate attributeName="opacity" values="0.2;0.05;0.2" dur="2.5s" repeatCount="indefinite"/></path>' +
      // Robot standing/leaning, one arm on counter
      // Legs
      '<rect x="72" y="72" width="8" height="16" rx="3" fill="' + c + '" opacity="0.6"/>' +
      '<rect x="84" y="72" width="8" height="16" rx="3" fill="' + c + '" opacity="0.6"/>' +
      // Feet
      '<rect x="70" y="86" width="12" height="4" rx="2" fill="' + c + '" opacity="0.5"/>' +
      '<rect x="82" y="86" width="12" height="4" rx="2" fill="' + c + '" opacity="0.5"/>' +
      // Body (slightly leaning)
      '<rect x="70" y="44" width="24" height="30" rx="5" fill="' + c + '" opacity="0.75"/>' +
      // Head
      '<rect x="72" y="20" width="20" height="22" rx="6" fill="' + c + '"/>' +
      // Antenna (relaxed tilt)
      '<line x1="82" y1="14" x2="82" y2="20" stroke="' + c + '" stroke-width="2"/>' +
      '<circle cx="82" cy="12" r="3" fill="' + c + '"/>' +
      // Eyes (relaxed, half-lid)
      '<circle cx="78" cy="30" r="3" fill="#fff"/><circle cx="86" cy="30" r="3" fill="#fff"/>' +
      '<circle cx="78" cy="30.5" r="1.5" fill="#1a1a2e"/><circle cx="86" cy="30.5" r="1.5" fill="#1a1a2e"/>' +
      '<line x1="75" y1="28" x2="81" y2="28" stroke="' + c + '" stroke-width="1.5" opacity="0.4"/>' +
      '<line x1="83" y1="28" x2="89" y2="28" stroke="' + c + '" stroke-width="1.5" opacity="0.4"/>' +
      // Relaxed smile
      '<path d="M78 35 Q82 38 86 35" stroke="#8b949e" stroke-width="1.5" fill="none"/>' +
      // Left arm reaching to mug
      '<rect x="56" y="50" width="16" height="5" rx="2" fill="' + c + '" opacity="0.7"/>' +
      '<rect x="48" y="48" width="10" height="6" rx="3" fill="' + c + '" opacity="0.7"/>' +
      // Right arm hanging
      '<rect x="92" y="50" width="6" height="14" rx="3" fill="' + c + '" opacity="0.6"/>' +
      // Thought bubble (optional ambient detail)
      '<circle cx="100" cy="22" r="2" fill="#30363d" opacity="0.4"/>' +
      '<circle cx="105" cy="16" r="3" fill="#30363d" opacity="0.3"/>' +
      '<ellipse cx="108" cy="8" rx="8" ry="5" fill="#30363d" opacity="0.2"/>' +
      '</svg>';
  }
}

function renderOfficeTab() {
  if (!agentConfig || !agentConfig.agents) return;
  var config = agentConfig;
  var merged = lastDashboard ? mergeConfigAndDashboard(config, lastDashboard) : {};
  var schedules = (scheduleData && scheduleData.schedules) ? scheduleData.schedules : [];
  var agentHasSchedule = {};
  schedules.forEach(function(s) { agentHasSchedule[s.agent] = true; });
  var agentNames = Object.keys(config.agents);
  var floorEl = document.getElementById("office-floor"); if (!floorEl) return;
  floorEl.innerHTML = "";
  // Group agents by their group field
  var groups = {};
  agentNames.forEach(function(name) {
    var g = config.agents[name].group || "Other Agents";
    if (!groups[g]) groups[g] = [];
    groups[g].push(name);
  });
  // Render Work Agents first, then Other Agents
  var groupOrder = ["Work Agents", "Other Agents"];
  Object.keys(groups).forEach(function(g) { if (groupOrder.indexOf(g) === -1) groupOrder.push(g); });
  groupOrder.forEach(function(groupName) {
    var members = groups[groupName];
    if (!members || members.length === 0) return;
    var header = document.createElement("div"); header.className = "office-group-header";
    header.textContent = groupName; floorEl.appendChild(header);
    var grid = document.createElement("div"); grid.className = "office-group-grid";
    floorEl.appendChild(grid);
    members.forEach(function(name) {
      var _floorTarget = grid;
    var agentCfg = config.agents[name], agentData = merged[name] || {};
    var color = getAgentColor(name), status = getAgentStatus(agentData), hasSchedule = agentHasSchedule[name];
    var desk = document.createElement("div"); desk.className = "office-desk"; desk.style.borderLeftColor = color;
    var deskStatus, statusDotClass, statusText;
    if (status === "busy") { desk.classList.add("working"); deskStatus = "working"; statusDotClass = "working"; statusText = "WORKING"; }
    else if (!hasSchedule) { desk.classList.add("sleeping"); deskStatus = "sleeping"; statusDotClass = "sleeping"; statusText = "SLEEPING"; }
    else { desk.classList.add("idle"); deskStatus = "idle"; statusDotClass = "idle"; statusText = "IDLE"; }
    var sd = document.createElement("div"); sd.className = "office-desk-status";
    var dt = document.createElement("span"); dt.className = "office-status-dot " + statusDotClass; sd.appendChild(dt);
    var sl = document.createElement("span"); sl.textContent = statusText;
    sl.style.color = deskStatus === "working" ? "#ef4444" : "#8b949e"; sd.appendChild(sl); desk.appendChild(sd);
    // Robot avatar
    var robotDiv = document.createElement("div"); robotDiv.className = "office-robot-container";
    robotDiv.innerHTML = getRobotSvg(deskStatus, color); desk.appendChild(robotDiv);
    var nd = document.createElement("div"); nd.className = "office-desk-name";
    nd.textContent = agentCfg.displayName || name; nd.style.color = color; desk.appendChild(nd);
    var jd = document.createElement("div"); jd.className = "office-desk-job";
    if (deskStatus === "working" && agentData.running_job) {
      jd.textContent = agentData.running_job.job || agentData.running_job.name || "unknown"; desk.appendChild(jd);
      var ed = document.createElement("div"); ed.className = "office-desk-elapsed";
      var st = null; (agentData.jobs || []).forEach(function(j) { if (j.status === "running" && j.started) st = j.started; });
      if (st) { ed.dataset.startedAt = st; var el = Math.max(0, Math.floor((Date.now() - new Date(st).getTime()) / 1000)); ed.textContent = Math.floor(el / 60) + ":" + (el % 60 < 10 ? "0" : "") + (el % 60); }
      else { ed.textContent = "--:--"; } desk.appendChild(ed);
    } else if (deskStatus === "sleeping") { jd.textContent = "manual only"; desk.appendChild(jd); }
    else {
      var ljn = "", ljt = null, ljr = null;
      (agentData.jobs || []).forEach(function(j) {
        if (j.lastCompleted && (!ljt || j.lastCompleted > ljt)) { ljt = j.lastCompleted; ljn = j.name || ""; ljr = (j.status === "failed" || j.status === "error") ? "failure" : "success"; }
      });
      if (ljn) {
        jd.textContent = ljn; desk.appendChild(jd);
        var rd = document.createElement("div"); rd.className = "office-desk-result";
        var is = document.createElement("span"); is.className = ljr === "success" ? "success" : "failure";
        is.textContent = ljr === "success" ? "\u2713 " : "\u2717 "; rd.appendChild(is);
        rd.appendChild(document.createTextNode(formatRelativeTime(ljt))); desk.appendChild(rd);
      } else { jd.textContent = "no runs yet"; desk.appendChild(jd); }
    }
    _floorTarget.appendChild(desk);
    });
  });
  var queueEl = document.getElementById("office-queue"), queueBadge = document.getElementById("office-queue-badge");
  if (queueEl) {
    queueEl.innerHTML = ""; var tq = 0;
    agentNames.forEach(function(name) {
      var ad = merged[name] || {}; (ad.jobs || []).forEach(function(j) {
        if (j.queueDepth && j.queueDepth > 0) {
          tq += j.queueDepth; var it = document.createElement("div"); it.className = "office-queue-item";
          var as = document.createElement("span"); as.style.color = getAgentColor(name); as.style.fontWeight = "600";
          as.textContent = config.agents[name].displayName || name; it.appendChild(as);
          it.appendChild(document.createTextNode(" / " + (j.name || "unknown") + " (" + j.queueDepth + " queued)")); queueEl.appendChild(it);
        }
      });
    });
    if (tq === 0) queueEl.textContent = "No jobs queued.";
    if (queueBadge) queueBadge.textContent = tq;
  }
  var feedEl = document.getElementById("office-feed");
  if (feedEl) {
    feedEl.innerHTML = ""; var re = (latestEvents || []).slice(-5).reverse();
    if (re.length === 0) {
      var em = document.createElement("div"); em.className = "office-feed-entry";
      em.style.cssText = "color:#484f58;font-style:italic;padding:0.5rem 0.75rem";
      em.textContent = "No recent events"; feedEl.appendChild(em);
    } else {
      re.forEach(function(evt) {
        var en = document.createElement("div"); en.className = "office-feed-entry";
        var tm = document.createElement("span"); tm.className = "office-feed-time";
        tm.textContent = new Date(evt.timestamp || evt.ts || evt.time).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", hour12: true, timeZone: "America/Los_Angeles" });
        en.appendChild(tm);
        var tx = document.createElement("span"); tx.className = "office-feed-text";
        var et = evt.event || evt.type || "info", ea = canonicalAgentName(evt.agent || "unknown"), ej = evt.job || "", ed = evt.details || {};
        var ft = ea + " " + et + " " + ej;
        if (et === "completed" && ed.duration) ft = ea + " completed " + ej + " (" + ((ed.exit_code === 0 || ed.exit_code === undefined) ? "\u2713" : "\u2717") + " " + ed.duration + ")";
        else if (et === "started") ft = ea + " started " + ej;
        else if (et === "failed") ft = ea + " failed " + ej + (ed.duration ? " (" + ed.duration + ")" : "");
        tx.textContent = ft; en.appendChild(tx); feedEl.appendChild(en);
      });
    }
  }
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

  // Refresh team tab
  if (activeTopTab === "team") {
    try {
      agentConfig = await fetchConfig();
      scheduleData = await fetchSchedules();
      scheduleData.dashboard = lastDashboard;
      scheduleData.config = agentConfig;
      scheduleData.merged = mergeConfigAndDashboard(agentConfig, lastDashboard);
      renderTeamTab();
    } catch (e) {
      console.warn("Team tab fetch failed:", e.message);
    }
  }

  // Refresh office tab
  if (activeTopTab === "office") {
    try {
      agentConfig = await fetchConfig();
      scheduleData = await fetchSchedules();
      scheduleData.dashboard = lastDashboard;
      scheduleData.config = agentConfig;
      scheduleData.merged = mergeConfigAndDashboard(agentConfig, lastDashboard);
      renderOfficeTab();
    } catch (e) {
      console.warn("Office tab fetch failed:", e.message);
    }
  }

  // Refresh agents-v2 tab
  if (activeTopTab === "agents-v2") {
    try {
      scheduleData = await fetchSchedules();
      scheduleData.dashboard = lastDashboard;
      scheduleData.config = agentConfig;
      scheduleData.merged = mergeConfigAndDashboard(agentConfig, lastDashboard);
      renderV2QueueCards();
    } catch (e) {
      console.warn("V2 schedules fetch failed:", e.message);
    }
    try {
      var v2reports = await fetchReports();
      renderV2ReportsTree(v2reports);
    } catch (e) {
      console.warn("V2 reports fetch failed:", e.message);
    }
  }

  // Refresh schedules-v2 tab
  if (activeTopTab === "schedules-v2") {
    try {
      scheduleData = await fetchSchedules();
      scheduleData.dashboard = lastDashboard;
      scheduleData.config = agentConfig;
      scheduleData.merged = mergeConfigAndDashboard(agentConfig, lastDashboard);
      renderV2UpcomingSchedule();
    } catch (e) {
      console.warn("V2 upcoming schedules fetch failed:", e.message);
    }
    try {
      allEvents = await fetchAllEvents();
      populateV2PastAgentFilter();
      renderV2PastSchedule();
    } catch (e) {
      console.warn("V2 past events fetch failed:", e.message);
    }
  }

  // Refresh history tab
  if (activeTopTab === "history") {
    try {
      allEvents = await fetchAllEvents();
      buildHistoryRuns();
      renderHistoryHealthCards();
      renderHistoryTable();
    } catch (e) {
      console.warn("History events fetch failed:", e.message);
    }
  }

  // Refresh schedule tab
  if (activeTopTab === "schedule") {
    try {
      scheduleData = await fetchSchedules();
      scheduleData.dashboard = lastDashboard;
      scheduleData.config = agentConfig;
      scheduleData.merged = mergeConfigAndDashboard(agentConfig, lastDashboard);
      allEvents = await fetchAllEvents();
      renderScheduleV2Tab();
    } catch (e) {
      console.warn("Schedule tab fetch failed:", e.message);
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
  if (viewParam && (viewParam === "agents" || viewParam === "events" || viewParam === "queue" || viewParam === "agents-v2" || viewParam === "schedules-v2" || viewParam === "team" || viewParam === "office" || viewParam === "history" || viewParam === "schedule")) {
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

// --- History Tab ---

function buildHistoryRuns() {
  // Match started -> completed/failed events by run_id
  var startedMap = {}; // run_id -> event
  var runs = [];

  allEvents.forEach(function(evt) {
    var evtType = evt.event || evt.type || "";
    var runId = evt.run_id || (evt.details && evt.details.run_id) || null;
    var agent = canonicalAgentName(evt.agent || "");
    var job = evt.job || "";
    var ts = evt.timestamp || evt.ts || evt.time;

    if (evtType === "started" && runId) {
      startedMap[runId] = { agent: agent, job: job, ts: ts, runId: runId };
    } else if ((evtType === "completed" || evtType === "failed") && runId) {
      var startEvt = startedMap[runId];
      var startTs = startEvt ? startEvt.ts : null;
      var endTs = ts;
      var durationMs = 0;
      if (startTs && endTs) {
        durationMs = new Date(endTs).getTime() - new Date(startTs).getTime();
      }
      // Parse duration from details if available
      var durationStr = (evt.details && evt.details.duration) ? evt.details.duration : "";
      if (!durationMs && durationStr) {
        // Try to parse "4m 12s" or "1h 2m 3s" patterns
        var hMatch = durationStr.match(/(\d+)h/);
        var mMatch = durationStr.match(/(\d+)m/);
        var sMatch = durationStr.match(/(\d+)s/);
        durationMs = ((hMatch ? parseInt(hMatch[1]) * 3600 : 0) +
                       (mMatch ? parseInt(mMatch[1]) * 60 : 0) +
                       (sMatch ? parseInt(sMatch[1]) : 0)) * 1000;
      }
      var result = evtType === "completed" ? "success" : "failure";
      // Check for timeout (exit code or very long duration)
      if (evt.details && evt.details.exit_code !== undefined && evt.details.exit_code !== 0) {
        if (durationMs > 30 * 60 * 1000) {
          result = "timeout";
        }
      }
      // Extract per-run output file from audit event details
      // Validate: path must belong to the agent (in agent subdir, or root file matching job/agent name)
      // Reject: paths from other agents, -latest.html, or generic root files
      var rawOutputFile = (evt.details && evt.details.output_file) ? evt.details.output_file : null;
      var runAgent = (startEvt ? startEvt.agent : agent).toLowerCase();
      var runJob = (startEvt ? startEvt.job : job).toLowerCase().replace(/^todo-/, "");
      var outputFile = null;
      if (rawOutputFile && rawOutputFile !== "(not saved)") {
        var normalizedOut = rawOutputFile.replace(/\\/g, "/").toLowerCase();
        var fileName = normalizedOut.split("/").pop() || "";
        // Case 1: in agent's own subdir
        if (normalizedOut.indexOf("/" + runAgent + "/") >= 0) {
          outputFile = rawOutputFile;
        }
        // Case 2: root-level file matching job or agent name (not -latest)
        else if ((fileName.indexOf(runJob) === 0 || fileName.indexOf(runAgent + "-") === 0) && fileName.indexOf("-latest") < 0) {
          outputFile = rawOutputFile;
        }
        // else: bogus path -- discard
      }
      runs.push({
        agent: startEvt ? startEvt.agent : agent,
        job: startEvt ? startEvt.job : job,
        start: startTs || endTs,
        end: endTs,
        durationMs: durationMs,
        result: result,
        runId: runId,
        outputFile: outputFile
      });
      delete startedMap[runId];
    }
  });

  // Also add started events with no matching end (stalled/in-progress)
  // Only include if older than 5 minutes
  var fiveMinAgo = Date.now() - 5 * 60 * 1000;
  Object.keys(startedMap).forEach(function(runId) {
    var se = startedMap[runId];
    var startTime = new Date(se.ts).getTime();
    if (startTime < fiveMinAgo) {
      runs.push({
        agent: se.agent,
        job: se.job,
        start: se.ts,
        end: null,
        durationMs: Date.now() - startTime,
        result: "timeout",
        runId: runId
      });
    }
  });

  historyRuns = runs;
}

function renderHistoryHealthCards() {
  var container = document.getElementById("history-health-cards");
  if (!container) return;
  container.innerHTML = "";

  // Compute per-job success rate over last 7 days
  var sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
  var jobStats = {}; // "agent/job" -> { total, success }

  historyRuns.forEach(function(run) {
    var startTime = new Date(run.start).getTime();
    if (isNaN(startTime) || startTime < sevenDaysAgo) return;

    var key = run.agent + "/" + run.job;
    if (!jobStats[key]) {
      jobStats[key] = { agent: run.agent, job: run.job, total: 0, success: 0 };
    }
    jobStats[key].total++;
    if (run.result === "success") jobStats[key].success++;
  });

  var keys = Object.keys(jobStats).sort();
  if (keys.length === 0) {
    container.innerHTML = '<div class="placeholder-message">No runs in the last 7 days</div>';
    return;
  }

  keys.forEach(function(key) {
    var stat = jobStats[key];
    var pct = stat.total > 0 ? Math.round(stat.success / stat.total * 100) : 0;
    var cls = pct > 90 ? "good" : (pct >= 70 ? "warning" : "bad");

    var card = document.createElement("div");
    card.className = "health-card " + cls;

    var jobEl = document.createElement("div");
    jobEl.className = "health-job";
    jobEl.textContent = stat.job;
    jobEl.title = stat.agent + "/" + stat.job;
    jobEl.style.color = getAgentColor(stat.agent);
    card.appendChild(jobEl);

    var pctEl = document.createElement("div");
    pctEl.className = "health-pct";
    pctEl.textContent = pct + "%";
    card.appendChild(pctEl);

    var fracEl = document.createElement("div");
    fracEl.className = "health-fraction";
    fracEl.textContent = stat.success + "/" + stat.total;
    card.appendChild(fracEl);

    container.appendChild(card);
  });
}

function populateHistoryFilters() {
  var agentSel = document.getElementById("history-agent-filter");
  var jobSel = document.getElementById("history-job-filter");
  if (!agentSel || !jobSel) return;

  var agents = {};
  var jobs = {};
  historyRuns.forEach(function(run) {
    agents[run.agent] = true;
    jobs[run.job] = true;
  });

  var currentAgent = agentSel.value;
  agentSel.innerHTML = '<option value="">All Agents</option>';
  Object.keys(agents).sort().forEach(function(a) {
    var opt = document.createElement("option");
    opt.value = a;
    opt.textContent = a;
    agentSel.appendChild(opt);
  });
  agentSel.value = currentAgent;

  updateHistoryJobFilter();
}

function updateHistoryJobFilter() {
  var agentSel = document.getElementById("history-agent-filter");
  var jobSel = document.getElementById("history-job-filter");
  if (!jobSel) return;

  var agentFilter = agentSel ? agentSel.value : "";
  var jobs = {};
  historyRuns.forEach(function(run) {
    if (agentFilter && run.agent !== agentFilter) return;
    jobs[run.job] = true;
  });

  var currentJob = jobSel.value;
  jobSel.innerHTML = '<option value="">All Jobs</option>';
  Object.keys(jobs).sort().forEach(function(j) {
    var opt = document.createElement("option");
    opt.value = j;
    opt.textContent = j;
    jobSel.appendChild(opt);
  });
  // Restore selection if still valid
  if (jobs[currentJob]) {
    jobSel.value = currentJob;
  } else {
    jobSel.value = "";
  }
}

function getFilteredHistoryRuns() {
  var agentFilter = (document.getElementById("history-agent-filter") || {}).value || "";
  var jobFilter = (document.getElementById("history-job-filter") || {}).value || "";
  var resultFilter = (document.getElementById("history-result-filter") || {}).value || "";
  var timeFilter = (document.getElementById("history-time-filter") || {}).value || "";

  var now = Date.now();
  var timeMs = 0;
  if (timeFilter === "24h") timeMs = 86400000;
  else if (timeFilter === "7d") timeMs = 604800000;
  else if (timeFilter === "30d") timeMs = 30 * 86400000;

  return historyRuns.filter(function(run) {
    if (agentFilter && run.agent !== agentFilter) return false;
    if (jobFilter && run.job !== jobFilter) return false;
    if (resultFilter && run.result !== resultFilter) return false;
    if (timeMs) {
      var startTime = new Date(run.start).getTime();
      if (now - startTime > timeMs) return false;
    }
    return true;
  });
}

function formatDuration(ms) {
  if (!ms || ms <= 0) return "--";
  var totalSec = Math.floor(ms / 1000);
  if (totalSec < 60) return totalSec + "s";
  var m = Math.floor(totalSec / 60);
  var s = totalSec % 60;
  if (m < 60) return m + "m " + (s < 10 ? "0" : "") + s + "s";
  var h = Math.floor(m / 60);
  m = m % 60;
  return h + "h " + m + "m";
}

function sortHistoryRuns(runs) {
  var col = historySortCol;
  var asc = historySortAsc;
  var dir = asc ? 1 : -1;

  runs.sort(function(a, b) {
    var av, bv;
    if (col === "agent") { av = a.agent; bv = b.agent; }
    else if (col === "job") { av = a.job; bv = b.job; }
    else if (col === "start") { av = a.start || ""; bv = b.start || ""; }
    else if (col === "duration") { return (a.durationMs - b.durationMs) * dir; }
    else if (col === "result") { av = a.result; bv = b.result; }
    else { av = a.start || ""; bv = b.start || ""; }
    return av < bv ? -dir : av > bv ? dir : 0;
  });

  return runs;
}

function renderHistoryTable() {
  var filtered = getFilteredHistoryRuns();
  filtered = sortHistoryRuns(filtered);

  var countEl = document.getElementById("history-count");
  if (countEl) countEl.textContent = filtered.length;

  var showCount = historyPageSize * (historyPage + 1);
  var displayItems = filtered.slice(0, showCount);

  var tbody = document.getElementById("history-tbody");
  if (!tbody) return;
  tbody.innerHTML = "";

  // Build job->output lookup for report links
  var jobOutputLookup = buildJobOutputLookup();

  displayItems.forEach(function(run) {
    var tr = document.createElement("tr");

    // Agent
    var tdAgent = document.createElement("td");
    tdAgent.style.color = getAgentColor(run.agent);
    tdAgent.style.fontWeight = "600";
    tdAgent.textContent = run.agent;
    tr.appendChild(tdAgent);

    // Job
    var tdJob = document.createElement("td");
    tdJob.textContent = run.job;
    tdJob.style.color = "#9ca3af";
    tr.appendChild(tdJob);

    // Start
    var tdStart = document.createElement("td");
    tdStart.textContent = run.start ? formatTimeAgo(run.start) : "--";
    tdStart.style.whiteSpace = "nowrap";
    tr.appendChild(tdStart);

    // Duration
    var tdDur = document.createElement("td");
    tdDur.textContent = formatDuration(run.durationMs);
    tdDur.style.fontFamily = '"Cascadia Code", "Fira Code", "Consolas", monospace';
    tdDur.style.fontSize = "0.78rem";
    tr.appendChild(tdDur);

    // Result
    var tdResult = document.createElement("td");
    var badge = document.createElement("span");
    badge.className = "result-badge " + run.result;
    if (run.result === "success") {
      badge.textContent = "\u2713 success";
    } else if (run.result === "failure") {
      badge.textContent = "\u2717 failed";
    } else if (run.result === "timeout") {
      badge.textContent = "\u23F1 timeout";
    }
    tdResult.appendChild(badge);
    tr.appendChild(tdResult);

    // Report — use per-run output file, fall back to job-level latest
    var tdReport = document.createElement("td");
    var runOutput = run.outputFile;
    if (!runOutput || runOutput === "(not saved)") {
      var outputKey = run.agent + "/" + run.job;
      runOutput = jobOutputLookup[outputKey];
    }
    if (runOutput && runOutput !== "(not saved)" && run.result === "success") {
      var reportLink = document.createElement("a");
      reportLink.className = "report-link";
      reportLink.href = getReportHref(runOutput);
      reportLink.target = "_blank";
      reportLink.textContent = "Report";
      reportLink.title = runOutput;
      tdReport.appendChild(reportLink);
    }
    tr.appendChild(tdReport);

    tbody.appendChild(tr);
  });

  // Update sort indicators on headers
  var ths = document.querySelectorAll("#history-table th[data-sort]");
  ths.forEach(function(th) {
    th.classList.remove("sort-asc", "sort-desc");
    if (th.getAttribute("data-sort") === historySortCol) {
      th.classList.add(historySortAsc ? "sort-asc" : "sort-desc");
    }
  });

  // Show/hide "Show more" button
  var showMoreEl = document.getElementById("history-show-more");
  if (showMoreEl) {
    showMoreEl.style.display = (showCount < filtered.length) ? "" : "none";
  }
}

// --- Schedule Tab ---

function populateScheduleV2AgentFilter() {
  var select = document.getElementById("schedule-v2-agent-filter");
  if (!select) return;
  var agents = {};
  if (scheduleData && scheduleData.schedules) {
    scheduleData.schedules.forEach(function(sched) {
      if (sched.agent) agents[sched.agent] = true;
    });
  }
  var current = select.value;
  select.innerHTML = '<option value="">All Agents</option>';
  Object.keys(agents).sort().forEach(function(name) {
    var opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    select.appendChild(opt);
  });
  select.value = current;
}

function getLastRunResult(agent, job) {
  // Find most recent completed/failed event for this agent+job from allEvents
  for (var i = allEvents.length - 1; i >= 0; i--) {
    var evt = allEvents[i];
    var evtType = evt.event || evt.type || "";
    if ((evtType === "completed" || evtType === "failed") &&
        canonicalAgentName(evt.agent || "") === agent &&
        (evt.job || "") === job) {
      return evtType === "completed" ? "success" : "failure";
    }
  }
  return null;
}

function renderScheduleV2Tab() {
  if (!scheduleData) return;
  var schedules = scheduleData.schedules || [];
  var now = new Date();
  var in24h = now.getTime() + 24 * 60 * 60 * 1000;
  var agentFilter = (document.getElementById("schedule-v2-agent-filter") || {}).value || "";
  var allItems = [];

  schedules.forEach(function(sched) {
    var agent = sched.agent || "";
    var job = sched.job || "";
    var cron = sched.cron || "";
    var enabled = sched.enabled !== false;
    var description = sched.description || "";
    var cronHuman = cronToHuman(cron);

    if (agentFilter && agent !== agentFilter) return;

    var fires = enabled ? getNextCronFires(cron, now, 10) : [];

    if (!enabled) {
      allItems.push({
        fireTime: null, agent: agent, job: job,
        cronHuman: cronHuman, description: description,
        enabled: false
      });
      return;
    }

    fires.forEach(function(fireTime) {
      allItems.push({
        fireTime: fireTime, agent: agent, job: job,
        cronHuman: cronHuman, description: description,
        enabled: true
      });
    });
  });

  // Sort: disabled at end, then by fireTime ascending
  allItems.sort(function(a, b) {
    if (!a.fireTime && !b.fireTime) return 0;
    if (!a.fireTime) return 1;
    if (!b.fireTime) return -1;
    return a.fireTime.getTime() - b.fireTime.getTime();
  });

  var totalCount = allItems.length;
  var showCount = scheduleV2PageSize * (scheduleV2Page + 1);
  var displayItems = allItems.slice(0, showCount);

  var tbody = document.getElementById("schedule-v2-tbody");
  if (!tbody) return;
  tbody.innerHTML = "";

  displayItems.forEach(function(item) {
    var tr = document.createElement("tr");
    tr.className = "schedule-row";

    // Highlight next-24h rows
    if (item.fireTime && item.fireTime.getTime() <= in24h) {
      tr.classList.add("next-24h");
    }
    if (!item.enabled) {
      tr.classList.add("disabled-row");
    }

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
    tdJob.textContent = item.job;
    tdJob.style.color = "#9ca3af";
    tr.appendChild(tdJob);

    // Schedule
    var tdSchedule = document.createElement("td");
    tdSchedule.textContent = item.cronHuman;
    tr.appendChild(tdSchedule);

    // Last Result
    var tdLastResult = document.createElement("td");
    if (item.enabled) {
      var lastResult = getLastRunResult(item.agent, item.job);
      if (lastResult) {
        var resultBadge = document.createElement("span");
        resultBadge.className = "result-badge " + lastResult;
        resultBadge.textContent = lastResult === "success" ? "\u2713" : "\u2717";
        tdLastResult.appendChild(resultBadge);
      } else {
        tdLastResult.textContent = "--";
        tdLastResult.style.color = "#484f58";
      }
    } else {
      tdLastResult.textContent = "disabled";
      tdLastResult.style.color = "#484f58";
    }
    tr.appendChild(tdLastResult);

    tbody.appendChild(tr);
  });

  // Update count badge
  var countEl = document.getElementById("schedule-v2-count");
  if (countEl) countEl.textContent = totalCount;

  // Show/hide "Show more" button
  var showMoreEl = document.getElementById("schedule-v2-show-more");
  if (showMoreEl) {
    showMoreEl.style.display = (showCount < totalCount) ? "" : "none";
  }
}

// --- Init ---
document.addEventListener("DOMContentLoaded", function () {
  // Top tab click handlers
  document.querySelectorAll(".top-tab").forEach(function(btn) {
    btn.addEventListener("click", function() {
      switchTopTab(btn.dataset.tab);
    });
  });

  // V2 filter event listeners
  var v2SearchEl = document.getElementById("v2-reports-search");
  var v2AgentFilterEl = document.getElementById("v2-reports-agent-filter");
  var v2JobFilterEl = document.getElementById("v2-reports-job-filter");
  var v2DateFilterEl = document.getElementById("v2-reports-date-filter");
  if (v2SearchEl) v2SearchEl.addEventListener("input", renderV2ReportsTable);
  if (v2AgentFilterEl) v2AgentFilterEl.addEventListener("change", renderV2ReportsTable);
  if (v2JobFilterEl) v2JobFilterEl.addEventListener("change", renderV2ReportsTable);
  if (v2DateFilterEl) v2DateFilterEl.addEventListener("change", renderV2ReportsTable);

  // Event filter change handlers
  ["filter-agent", "filter-event-type", "filter-time"].forEach(function(id) {
    var el = document.getElementById(id);
    if (el) {
      el.addEventListener("change", function() {
        renderFilteredEvents();
      });
    }
  });

  // Schedules V2: collapsible section handlers
  var v2UpcomingHeader = document.getElementById("v2-upcoming-header");
  if (v2UpcomingHeader) {
    v2UpcomingHeader.addEventListener("click", function() {
      var content = document.getElementById("v2-upcoming-content");
      var icon = this.querySelector(".v2-collapse-icon");
      if (content.style.display === "none") {
        content.style.display = "";
        icon.innerHTML = "\u25BC"; // down arrow
      } else {
        content.style.display = "none";
        icon.innerHTML = "\u25B6"; // right arrow
      }
    });
  }

  var v2PastHeader = document.getElementById("v2-past-header");
  if (v2PastHeader) {
    v2PastHeader.addEventListener("click", function() {
      var content = document.getElementById("v2-past-content");
      var icon = this.querySelector(".v2-collapse-icon");
      if (content.style.display === "none") {
        content.style.display = "";
        icon.innerHTML = "\u25BC"; // down arrow
      } else {
        content.style.display = "none";
        icon.innerHTML = "\u25B6"; // right arrow
      }
    });
  }

  // Schedules V2: "Show more" button handlers
  var v2UpcomingMoreBtn = document.getElementById("v2-upcoming-more-btn");
  if (v2UpcomingMoreBtn) {
    v2UpcomingMoreBtn.addEventListener("click", function() {
      v2UpcomingPage++;
      renderV2UpcomingSchedule();
    });
  }

  var v2PastMoreBtn = document.getElementById("v2-past-more-btn");
  if (v2PastMoreBtn) {
    v2PastMoreBtn.addEventListener("click", function() {
      v2PastPage++;
      renderV2PastSchedule();
    });
  }

  // Schedules V2: Past filter change handlers
  ["v2-past-agent-filter", "v2-past-type-filter", "v2-past-time-filter"].forEach(function(id) {
    var el = document.getElementById(id);
    if (el) {
      el.addEventListener("change", function() {
        v2PastPage = 0;
        renderV2PastSchedule();
      });
    }
  });

  // History tab: filter change handlers
  var historyAgentFilter = document.getElementById("history-agent-filter");
  if (historyAgentFilter) {
    historyAgentFilter.addEventListener("change", function() {
      historyPage = 0;
      updateHistoryJobFilter();
      renderHistoryTable();
    });
  }
  ["history-job-filter", "history-result-filter", "history-time-filter"].forEach(function(id) {
    var el = document.getElementById(id);
    if (el) {
      el.addEventListener("change", function() {
        historyPage = 0;
        renderHistoryTable();
      });
    }
  });

  // History tab: sort header click handlers
  document.querySelectorAll("#history-table th[data-sort]").forEach(function(th) {
    th.addEventListener("click", function() {
      var col = th.getAttribute("data-sort");
      if (col === historySortCol) {
        historySortAsc = !historySortAsc;
      } else {
        historySortCol = col;
        historySortAsc = col === "duration" ? false : true;
      }
      historyPage = 0;
      renderHistoryTable();
    });
  });

  // History tab: "Show more" button handler
  var historyMoreBtn = document.getElementById("history-more-btn");
  if (historyMoreBtn) {
    historyMoreBtn.addEventListener("click", function() {
      historyPage++;
      renderHistoryTable();
    });
  }

  // Schedule tab: filter change handler
  var scheduleV2AgentFilter = document.getElementById("schedule-v2-agent-filter");
  if (scheduleV2AgentFilter) {
    scheduleV2AgentFilter.addEventListener("change", function() {
      scheduleV2Page = 0;
      renderScheduleV2Tab();
    });
  }

  // Schedule tab: "Show more" button handler
  var scheduleV2MoreBtn = document.getElementById("schedule-v2-more-btn");
  if (scheduleV2MoreBtn) {
    scheduleV2MoreBtn.addEventListener("click", function() {
      scheduleV2Page++;
      renderScheduleV2Tab();
    });
  }

  startPolling();
});
