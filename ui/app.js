/* Virtual Office - Live Dashboard */

var CONFIG = {
  POLL_INTERVAL: 2000,
  MAX_EVENTS: 50,
  API_BASE: ""
};

// --- State ---
var lastDashboardJSON = "";
var lastEventsJSON = "";
var isConnected = false;

// --- Fetch helpers ---

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

  // Job list
  var jobs = agentData.jobs || [];
  if (jobs.length > 0) {
    var ul = document.createElement("ul");
    ul.className = "job-list";
    jobs.forEach(function (job) {
      var li = document.createElement("li");
      li.className = "job-item";

      var statusIcon = document.createElement("span");
      statusIcon.className = "job-status-icon";
      if (job.status === "running") {
        statusIcon.textContent = "\u25B6"; // play triangle
      } else if (job.status === "completed" || job.status === "done") {
        statusIcon.textContent = "\u2713"; // checkmark
      } else if (job.status === "failed" || job.status === "error") {
        statusIcon.textContent = "\u2717"; // x mark
      } else if (job.status === "queued" || job.status === "pending") {
        statusIcon.textContent = "\u2022"; // bullet
      } else {
        statusIcon.textContent = "\u2022";
      }
      li.appendChild(statusIcon);

      var jobName = document.createElement("span");
      jobName.className = "job-name";
      jobName.textContent = job.name || job.job || "unknown";
      li.appendChild(jobName);

      ul.appendChild(li);
    });
    card.appendChild(ul);
  }

  return card;
}

function renderAgents(dashboard) {
  var grid = document.getElementById("agent-grid");
  if (!dashboard || !dashboard.agents) {
    grid.innerHTML = '<div class="placeholder-message">No agents configured</div>';
    return;
  }

  var agents = dashboard.agents;
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
    var evtJSON = JSON.stringify(events);
    if (evtJSON !== lastEventsJSON) {
      lastEventsJSON = evtJSON;
      renderEvents(events);
    }
  } catch (e) {
    console.warn("Events fetch failed:", e.message);
  }
}

function startPolling() {
  // Initial fetch
  poll();
  // Repeat
  setInterval(poll, CONFIG.POLL_INTERVAL);
}

// --- Init ---
document.addEventListener("DOMContentLoaded", function () {
  startPolling();
});
