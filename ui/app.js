/* Virtual Office - Live Dashboard */

var CONFIG = {
  POLL_INTERVAL: 120000,
  MAX_EVENTS: 50,
  API_BASE: ""
};

// --- State ---
var lastDashboardJSON = "";
var lastEventsJSON = "";
var isConnected = false;
var agentConfig = null; // loaded once from /api/config
var agentErrors = {};
var latestEvents = [];

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

// --- Time formatting ---

function formatTimeAgo(timestamp) {
  if (!timestamp) return "never";
  var now = Date.now();
  var then = new Date(timestamp).getTime();
  var diffMs = now - then;
  if (isNaN(diffMs) || diffMs < 0) return "just now";

  var seconds = Math.floor(diffMs / 1000);
  if (seconds < 60) return seconds + "s ago";
  var minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes + "m ago";
  var hours = Math.floor(minutes / 60);
  if (hours < 24) return hours + "h ago";
  var days = Math.floor(hours / 24);
  return days + "d ago";
}

function formatTimestamp(timestamp) {
  if (!timestamp) return "";
  var d = new Date(timestamp);
  return d.toLocaleTimeString();
}

// --- Render agents ---

function getAgentStatus(agentData) {
  if (agentData.enabled === false) return "disabled";
  if (agentData.running_job || agentData.status === "busy") return "busy";
  return "idle";
}

function getAgentIcon(agentData) {
  // Use icon from data or default based on name
  if (agentData.icon) return agentData.icon;
  return "\uD83E\uDD16"; // robot emoji
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

  // Capabilities = ALL jobs (count never changes); active jobs shown separately
  var jobs = agentData.jobs || [];
  var activeJobs = [];
  var capabilities = jobs; // always the full list
  jobs.forEach(function (job) {
    if (job.status === "running" || job.status === "queued" || job.status === "pending" ||
        job.status === "completed" || job.status === "done" ||
        job.status === "failed" || job.status === "error") {
      activeJobs.push(job);
    }
  });

  // Show active jobs directly on card
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
        reportLink.href = "/api/output/" + stripOutputPrefix(job.lastOutput);
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

  // Capabilities shown on hover via tooltip
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

      var jobName = document.createElement("span");
      jobName.className = "tooltip-job-name";
      jobName.textContent = job.name || job.job || "unknown";
      item.appendChild(jobName);

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
    footerLink.href = "/api/output/" + stripOutputPrefix(latestOutput);
    footerLink.target = "_blank";
    footerLink.textContent = "Open";
    footer.appendChild(footerLink);
    card.appendChild(footer);
  }

  return card;
}

function mergeConfigAndDashboard(config, dashboard) {
  // Start with all agents from config, overlay with dashboard state
  var merged = {};
  if (config && config.agents) {
    Object.keys(config.agents).forEach(function (name) {
      var cfg = config.agents[name];
      merged[name] = {
        display_name: cfg.displayName || name,
        icon: cfg.icon || null,
        description: cfg.description || "",
        status: "idle",
        running_job: null,
        last_completed: null,
        queue_depth: 0,
        jobs: []
      };
      // Add jobs from config as idle
      if (cfg.jobs) {
        var jobList = [];
        Object.keys(cfg.jobs).forEach(function (jobName) {
          jobList.push({
            name: jobName,
            status: cfg.jobs[jobName].enabled === false ? "disabled" : "idle",
            description: cfg.jobs[jobName].description || ""
          });
        });
        merged[name].jobs = jobList;
      }
    });
  }
  // Overlay with dashboard state
  if (dashboard && dashboard.agents) {
    Object.keys(dashboard.agents).forEach(function (name) {
      var state = dashboard.agents[name];
      if (!merged[name]) {
        merged[name] = { display_name: name, jobs: [] };
      }
      // Copy state fields over config defaults
      if (state.status) merged[name].status = state.status;
      if (state.activeJob) merged[name].running_job = { job: state.activeJob };
      // Runner may write job data directly on agent object (not nested under "jobs")
      // Detect this: if a key has an object value with a "status" field, treat it as a job
      var jobsSource = state.jobs || {};
      if (!state.jobs) {
        // Check for flat job keys on the agent object
        Object.keys(state).forEach(function (key) {
          if (key !== "status" && key !== "activeJob" && key !== "errorCount" &&
              key !== "lastError" && typeof state[key] === "object" && state[key] !== null &&
              state[key].status) {
            jobsSource[key] = state[key];
            // Bubble up agent status from job
            if (state[key].status === "running") {
              merged[name].status = "busy";
              merged[name].running_job = { job: key, run: state[key].run_id };
            }
          }
        });
      }
      if (Object.keys(jobsSource).length > 0) {
        // Update individual job statuses
        Object.keys(jobsSource).forEach(function (jobName) {
          var jobState = jobsSource[jobName];
          var found = false;
          merged[name].jobs.forEach(function (j, i) {
            if (j.name === jobName) {
              merged[name].jobs[i].status = jobState.status || "idle";
              merged[name].jobs[i].run = jobState.run || 0;
              merged[name].jobs[i].queueDepth = jobState.queueDepth || 0;
              merged[name].jobs[i].lastCompleted = jobState.lastCompleted || null;
              merged[name].jobs[i].lastOutput = jobState.lastOutput || null;
              merged[name].jobs[i].lastOutputTime = jobState.lastOutputTime || null;
              found = true;
            }
          });
          if (!found) {
            merged[name].jobs.push({
              name: jobName,
              status: jobState.status || "idle",
              run: jobState.run || 0,
              queueDepth: jobState.queueDepth || 0,
              lastCompleted: jobState.lastCompleted || null,
              lastOutput: jobState.lastOutput || null,
              lastOutputTime: jobState.lastOutputTime || null
            });
          }
          // Bubble up last_completed
          if (jobState.lastCompleted && (!merged[name].last_completed || jobState.lastCompleted > merged[name].last_completed)) {
            merged[name].last_completed = jobState.lastCompleted;
          }
          // Bubble up queue depth
          if (jobState.queueDepth) {
            merged[name].queue_depth = (merged[name].queue_depth || 0) + jobState.queueDepth;
          }
        });
      }
    });
  }
  return merged;
}

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

  // Header
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

  // --- Status section ---
  var statusSection = document.createElement("div");
  statusSection.className = "running-section";
  var statusTitle = document.createElement("div");
  statusTitle.className = "running-section-title";
  statusTitle.textContent = "Status";
  statusSection.appendChild(statusTitle);

  // Find the running job data
  var runId = "";
  var startedTime = null;
  var runningJobData = null;
  if (agentData.running_job) {
    runId = agentData.running_job.run || "";
  }
  // Look through jobs for the running one
  var jobs = agentData.jobs || [];
  jobs.forEach(function(j) {
    if (j.status === "running") {
      runningJobData = j;
      if (j.run) runId = j.run;
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

  // --- Stats section ---
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
    if (j.run) totalRuns += (typeof j.run === "number" ? j.run : 0);
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

  // Last Output row (with link if available)
  var outputRow = document.createElement("div");
  outputRow.className = "running-field";
  var outputLabel = document.createElement("span");
  outputLabel.className = "running-field-label";
  outputLabel.textContent = "Last Output";
  outputRow.appendChild(outputLabel);
  if (lastOutputFile) {
    var outputLink = document.createElement("a");
    outputLink.href = "/api/output/" + stripOutputPrefix(lastOutputFile);
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

  // --- Recent Events section ---
  var eventsSection = document.createElement("div");
  eventsSection.className = "running-section";
  var eventsTitle = document.createElement("div");
  eventsTitle.className = "running-section-title";
  eventsTitle.textContent = "Recent Events";
  eventsSection.appendChild(eventsTitle);

  var eventsContainer = document.createElement("div");
  eventsContainer.className = "running-events";

  var agentEvents = latestEvents.filter(function(evt) {
    var evtAgent = evt.agent || evt.message || evt.detail || evt.msg || "";
    return evtAgent.indexOf(agentName) !== -1 ||
           (evt.agent && evt.agent === agentName);
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

function showErrorModal(agentName, errors) {
  // Remove existing modal if any
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

  // Header
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

  // Error list
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

    // Expandable detail
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

    // Mark resolved button
    if (!err.resolved) {
      var resolveBtn = document.createElement("button");
      resolveBtn.className = "resolve-btn";
      resolveBtn.textContent = "Mark Resolved";
      resolveBtn.addEventListener("click", function() {
        // For now just visually resolve (full impl would POST to server)
        row.classList.add("resolved");
        err.resolved = true;
        // Update badge count
        var badge = document.querySelector("[data-agent='" + agentName + "'] .error-badge");
        if (badge) {
          var remaining = errors.filter(function(e) { return !e.resolved; }).length;
          if (remaining === 0) { badge.remove(); }
          else { badge.textContent = remaining + (remaining === 1 ? " error" : " errors"); }
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

function renderAgents(dashboard) {
  var grid = document.getElementById("agent-grid");
  var agents = mergeConfigAndDashboard(agentConfig, dashboard);
  var agentNames = Object.keys(agents);

  if (agentNames.length === 0) {
    grid.innerHTML = '<div class="placeholder-message">No agents configured</div>';
    return;
  }

  // Rebuild grid
  grid.innerHTML = "";
  agentNames.forEach(function (name) {
    var card = renderAgentCard(name, agents[name]);
    grid.appendChild(card);
  });
}

// --- Render events ---

function eventTypeClass(type) {
  if (!type) return "";
  return type.replace(/_/g, "-").toLowerCase();
}

function renderEvents(events) {
  var log = document.getElementById("event-log");
  if (!events || events.length === 0) {
    log.innerHTML = '<div class="placeholder-message">No events yet</div>';
    return;
  }

  log.innerHTML = "";
  events.forEach(function (evt) {
    var row = document.createElement("div");
    row.className = "event-row";

    var time = document.createElement("span");
    time.className = "event-time";
    time.textContent = formatTimestamp(evt.timestamp || evt.ts || evt.time);
    row.appendChild(time);

    var type = document.createElement("span");
    type.className = "event-type " + eventTypeClass(evt.type || evt.event);
    type.textContent = evt.type || evt.event || "info";
    row.appendChild(type);

    var detail = document.createElement("span");
    detail.className = "event-detail";
    var detailText = evt.message || evt.detail || evt.msg || "";
    if (!detailText && evt.agent) {
      detailText = evt.agent;
      if (evt.job) detailText += " - " + evt.job;
    }
    detail.textContent = detailText;
    detail.title = detailText;
    row.appendChild(detail);

    log.appendChild(row);
  });

  // Auto-scroll to bottom
  log.scrollTop = log.scrollHeight;
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
  try {
    var dashboard = await fetchDashboard();
    var dashJSON = JSON.stringify(dashboard);
    if (dashJSON !== lastDashboardJSON) {
      lastDashboardJSON = dashJSON;
      renderAgents(dashboard);
    }
    setConnected(true);
    updateTimestamp();
  } catch (e) {
    setConnected(false);
    console.warn("Dashboard fetch failed:", e.message);
  }

  try {
    var events = await fetchEvents();
    latestEvents = events;
    var evtJSON = JSON.stringify(events);
    if (evtJSON !== lastEventsJSON) {
      lastEventsJSON = evtJSON;
      renderEvents(events);
    }
  } catch (e) {
    console.warn("Events fetch failed:", e.message);
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
  // Load config once (agent registry + job definitions)
  try {
    agentConfig = await fetchConfig();
  } catch (e) {
    console.warn("Config fetch failed, will retry on next poll:", e.message);
  }
  // Initial fetch
  poll();
  // Repeat
  setInterval(poll, CONFIG.POLL_INTERVAL);
}

// --- Init ---
document.addEventListener("DOMContentLoaded", function () {
  startPolling();
});
