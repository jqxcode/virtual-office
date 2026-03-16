# Virtual Office - Shared Constants
# Version: 0.1.0

$SYSTEM_VERSION = "0.1.0"
$PROJECT_ROOT = $PSScriptRoot | Split-Path -Parent
$CONFIG_DIR = Join-Path $PROJECT_ROOT "config"
$STATE_DIR = Join-Path $PROJECT_ROOT "state"
$OUTPUT_DIR = Join-Path $PROJECT_ROOT "output"
$AUDIT_DIR = Join-Path $OUTPUT_DIR "audit"
$EVENTS_FILE = Join-Path $STATE_DIR "events.jsonl"
$DASHBOARD_FILE = Join-Path $STATE_DIR "dashboard.json"
