#!/usr/bin/env bash
# Traffic Node menu for Debian or Ubuntu.
#
#   curl -fsSL https://raw.githubusercontent.com/MoonlessWanderer/TrafficNode/main/install.sh | sudo -E bash
set -euo pipefail

APP_DIR=""
APP_USER="trafficnode"
APP_GROUP="trafficnode"
SERVICE="traffic-node"
STATE_FILE=""
UNIT_FILE=""
PYTHON=""

ACTION=""
ASSUME_YES=0
PANEL_URL=""
NODE_ID=""
NODE_KEY=""
INTERVAL="30"
VERIFY_TLS="1"
INTERVAL_SET=0
URL_SET=0

usage() {
  cat <<'EOF'
Usage:
  install.sh                         Open the menu
  install.sh install [--dir PATH]
  install.sh connect [options]
  install.sh update
  install.sh start|stop|restart|status|logs
  install.sh interval NUMBER
  install.sh uninstall [--yes]

Options for connect:
  --url ADDRESS     Panel address, including http:// or https://.
  --id TEXT         Node id from the panel.
  --key TEXT        Node key from the panel.
  --interval NUMBER Seconds between reports. Default: 30.
  --insecure        Do not verify the panel TLS certificate.

The node is not installed under /opt.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run this script as root."
  fi
}

prompt() {
  local label="$1"
  local value=""
  if [ -r /dev/tty ]; then
    read -r -p "$label" value </dev/tty
  else
    read -r -p "$label" value
  fi
  printf '%s' "$value"
}

prompt_secret() {
  local label="$1"
  local value=""
  if [ -r /dev/tty ]; then
    read -r -s -p "$label" value </dev/tty
    echo >&2
  else
    read -r -s -p "$label" value
    echo >&2
  fi
  printf '%s' "$value"
}

valid_url() {
  [[ "$1" =~ ^https?://[^[:space:]]+$ ]]
}

valid_node_id() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{4,32}$ ]]
}

valid_key() {
  local key="$1"
  [ "${#key}" -ge 16 ] && [ "${#key}" -le 200 ] || return 1
  [[ "$key" != *$'\n'* && "$key" != *$'\r'* && "$key" != *\"* ]] || return 1
  [[ "$key" =~ [[:space:]] ]] && return 1
  return 0
}

valid_interval() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  [ "$1" -ge 5 ] && [ "$1" -le 3600 ]
}

bind_app_dir() {
  APP_DIR="${APP_DIR%/}"
  case "$APP_DIR" in
    /*/*) ;;
    *) die "The install directory must be an absolute path with a parent directory." ;;
  esac
  case "$APP_DIR" in
    *[[:space:]]*|*".."*) die "The install directory is invalid." ;;
  esac
  case "$APP_DIR" in
    /opt|/opt/*)
      die "Choose a directory outside /opt."
      ;;
    /|/usr|/usr/local|/etc|/var|/var/lib|/home|/root|/tmp|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys|/run|/srv|/usr/bin|/usr/sbin|/usr/lib)
      die "Refusing to use ${APP_DIR} as the install directory."
      ;;
  esac
  STATE_FILE="${APP_DIR}/data/install.state"
  UNIT_FILE="${APP_DIR}/traffic-node.service"
}

default_install_dir() {
  local base
  base="$(pwd -P)"
  base="${base%/}"
  if [ "$base" = "/" ]; then
    printf '%s' "/traffic-node"
  else
    printf '%s' "${base}/traffic-node"
  fi
}

choose_install_dir() {
  if [ -z "$APP_DIR" ]; then
    local default entered
    default="$(default_install_dir)"
    if [ -r /dev/tty ]; then
      entered="$(prompt "Install directory [${default}]: ")"
      APP_DIR="${entered:-$default}"
    else
      APP_DIR="$default"
    fi
  fi
  bind_app_dir
}

locate_installed_dir() {
  local unit="/etc/systemd/system/${SERVICE}.service"
  local dir=""
  if [ -f "$unit" ] || [ -L "$unit" ]; then
    dir="$(sed -n 's/^WorkingDirectory=//p' "$unit" | head -n 1 | tr -d '[:space:]')"
  fi
  if [ -n "$dir" ]; then
    APP_DIR="$dir"
  fi
  [ -n "$APP_DIR" ] || die "The node is not installed."
  bind_app_dir
}

installed() {
  local unit="/etc/systemd/system/${SERVICE}.service"
  [ -f "$unit" ] || [ -L "$unit" ]
}

require_deb() {
  if [ ! -f /etc/os-release ]; then
    die "This installer supports Debian and Ubuntu."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "This installer supports Debian and Ubuntu. Detected: ${ID:-unknown}." ;;
  esac
}

load_proxy_file() {
  local file="$1"
  local line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ''|\#*) continue ;;
    esac
    line="${line#export }"
    case "$line" in
      http_proxy=*|https_proxy=*|HTTP_PROXY=*|HTTPS_PROXY=*|no_proxy=*|NO_PROXY=*|all_proxy=*|ALL_PROXY=*)
        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        if [ -z "${!key:-}" ] && [ -n "$value" ]; then
          export "$key=$value"
        fi
        ;;
    esac
  done <"$file"
}

proxy_from_apt() {
  local scheme="$1"
  local file line value
  local files=()
  shopt -s nullglob
  files=(/etc/apt/apt.conf.d/*)
  shopt -u nullglob
  [ -f /etc/apt/apt.conf ] && files+=("/etc/apt/apt.conf")
  for file in "${files[@]}"; do
    [ -f "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *Acquire::"${scheme}"::Proxy*)
          value="${line#*\"}"
          value="${value%%\"*}"
          if [ -n "$value" ] && [ "$value" != "false" ] && [ "$value" != "DIRECT" ]; then
            printf '%s' "$value"
            return 0
          fi
          ;;
      esac
    done <"$file"
  done
  return 1
}

load_proxy() {
  local apt_http="" apt_https=""
  load_proxy_file /etc/environment
  apt_http="$(proxy_from_apt http)" || true
  apt_https="$(proxy_from_apt https)" || true
  if [ -z "${http_proxy:-}${HTTP_PROXY:-}" ] && [ -n "$apt_http" ]; then
    export http_proxy="$apt_http"
    export HTTP_PROXY="$apt_http"
  fi
  if [ -z "${https_proxy:-}${HTTPS_PROXY:-}" ]; then
    if [ -n "$apt_https" ]; then
      export https_proxy="$apt_https"
      export HTTPS_PROXY="$apt_https"
    elif [ -n "${http_proxy:-}${HTTP_PROXY:-}" ]; then
      export https_proxy="${HTTP_PROXY:-$http_proxy}"
      export HTTPS_PROXY="$https_proxy"
    fi
  fi
  [ -n "${http_proxy:-}" ] && [ -z "${HTTP_PROXY:-}" ] && export HTTP_PROXY="$http_proxy"
  [ -n "${HTTP_PROXY:-}" ] && [ -z "${http_proxy:-}" ] && export http_proxy="$HTTP_PROXY"
  [ -n "${https_proxy:-}" ] && [ -z "${HTTPS_PROXY:-}" ] && export HTTPS_PROXY="$https_proxy"
  [ -n "${HTTPS_PROXY:-}" ] && [ -z "${https_proxy:-}" ] && export https_proxy="$HTTPS_PROXY"
  if [ -n "${https_proxy:-}${http_proxy:-}" ]; then
    if [ -z "${no_proxy:-}${NO_PROXY:-}" ]; then
      export no_proxy="localhost,127.0.0.1"
      export NO_PROXY="$no_proxy"
    fi
    [ -n "${no_proxy:-}" ] && [ -z "${NO_PROXY:-}" ] && export NO_PROXY="$no_proxy"
    [ -n "${NO_PROXY:-}" ] && [ -z "${no_proxy:-}" ] && export no_proxy="$NO_PROXY"
    echo "Using the configured proxy for downloads."
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "$@"
}

ensure_python() {
  apt_install ca-certificates curl python3 tar
  local py version
  if command -v python3 >/dev/null 2>&1; then
    py="$(command -v python3)"
  else
    die "Python 3 was not found. Install Python 3.9 or newer and run this again."
  fi
  version="$("$py" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
  if ! "$py" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
    die "Found Python ${version} at ${py}. This node needs Python 3.9 or newer."
  fi
  PYTHON="$py"
  echo "Using Python ${version} at ${py}"
}

ensure_user() {
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
  fi
}

ensure_app_access() {
  local dir
  dir="$(dirname "$APP_DIR")"
  while [ "$dir" != "/" ]; do
    if ! runuser -u "$APP_USER" -- test -x "$dir"; then
      chmod o+x "$dir"
    fi
    dir="$(dirname "$dir")"
  done
}

write_state() {
  install -d -o "$APP_USER" -g "$APP_GROUP" -m 0750 "${APP_DIR}/data"
  cat >"$STATE_FILE" <<EOF
PANEL_URL=$(printf '%q' "${PANEL_URL:-}")
INTERVAL=$(printf '%s' "${INTERVAL:-30}")
VERIFY_TLS=$(printf '%s' "${VERIFY_TLS:-1}")
EOF
  chown "$APP_USER:$APP_GROUP" "$STATE_FILE"
  chmod 0640 "$STATE_FILE"
}

load_state() {
  PANEL_URL=""
  INTERVAL="30"
  VERIFY_TLS="1"
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
  [ -n "${INTERVAL:-}" ] || INTERVAL="30"
  [ -n "${VERIFY_TLS:-}" ] || VERIFY_TLS="1"
}

write_service() {
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Traffic Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/node.env
ExecStart=${PYTHON} ${APP_DIR}/node.py
Restart=always
RestartSec=10
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT_FILE"
  ln -sfn "$UNIT_FILE" "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload
}

write_env() {
  ENV_PATH="${APP_DIR}/node.env" \
  PANEL_URL="$PANEL_URL" \
  NODE_ID="$NODE_ID" \
  NODE_KEY="$NODE_KEY" \
  INTERVAL="$INTERVAL" \
  VERIFY_TLS="$VERIFY_TLS" \
  "$PYTHON" - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["ENV_PATH"])
lines = []
for key in ("PANEL_URL", "NODE_ID", "NODE_KEY", "INTERVAL", "VERIFY_TLS"):
    value = os.environ[key].replace("\\", "\\\\").replace('"', '\\"')
    lines.append(f'{key}="{value}"')
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
os.chmod(path, 0o640)
PY
  chown "$APP_USER:$APP_GROUP" "${APP_DIR}/node.env"
}

env_value() {
  local key="$1"
  [ -f "${APP_DIR}/node.env" ] || return 0
  "$PYTHON" - "$APP_DIR/node.env" "$key" <<'PY'
import sys
from pathlib import Path

path, key = sys.argv[1], sys.argv[2]
if key == "NODE_KEY":
    raise SystemExit(0)
for line in Path(path).read_text(encoding="utf-8").splitlines():
    if line.startswith(key + "="):
        print(line.split("=", 1)[1].strip().strip('"'))
        break
PY
}

set_interval_value() {
  INTERVAL="$1" "$PYTHON" - "$APP_DIR/node.env" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
interval = os.environ["INTERVAL"]
lines = []
found = False
for line in path.read_text(encoding="utf-8").splitlines():
    if line.startswith("INTERVAL="):
        lines.append(f'INTERVAL="{interval}"')
        found = True
    else:
        lines.append(line)
if not found:
    lines.append(f'INTERVAL="{interval}"')
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
os.chmod(path, 0o640)
PY
  chown "$APP_USER:$APP_GROUP" "${APP_DIR}/node.env"
}

proxy_url() {
  printf '%s' "${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
}

curl_get() {
  local url="$1"
  local dest="$2"
  local proxy
  proxy="$(proxy_url)"
  if [ -n "$proxy" ]; then
    curl -fsSL --retry 3 --retry-delay 2 --proxy "$proxy" -o "$dest" "$url" && return 0
    echo "Download through the proxy failed. Trying a direct connection."
  fi
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    curl -fsSL --retry 3 --retry-delay 2 --noproxy '*' -o "$dest" "$url"
}

fetch_source() {
  local dest="$1"
  local archive url
  local urls=(
    "https://codeload.github.com/MoonlessWanderer/TrafficNode/tar.gz/refs/heads/main"
    "https://github.com/MoonlessWanderer/TrafficNode/archive/refs/heads/main.tar.gz"
  )
  mkdir -p "$dest"
  for url in "${urls[@]}"; do
    archive="$(mktemp)"
    if curl_get "$url" "$archive" && tar -tzf "$archive" >/dev/null 2>&1; then
      if tar -xzf "$archive" -C "$dest" --strip-components=1; then
        rm -f "$archive"
        return 0
      fi
    fi
    rm -f "$archive"
  done
  return 1
}

require_ready() {
  locate_installed_dir
  [ -f "$APP_DIR/node.py" ] || die "The node is not installed."
  if [ -z "$PYTHON" ]; then
    if command -v python3 >/dev/null 2>&1; then
      PYTHON="$(command -v python3)"
    else
      die "Python 3 was not found."
    fi
  fi
}

require_connected() {
  require_ready
  [ -f "$APP_DIR/node.env" ] || die "This node is not connected. Choose Connect to panel."
}

install_node() {
  if installed; then
    die "The node is already installed. Choose Update."
  fi
  echo "Installing system packages."
  ensure_python
  choose_install_dir
  if [ -e "$APP_DIR" ]; then
    die "The directory already exists: ${APP_DIR}"
  fi
  ensure_user
  echo "Downloading the node."
  mkdir -p "$APP_DIR"
  if ! fetch_source "$APP_DIR"; then
    rm -rf "$APP_DIR"
    die "Could not download the node from GitHub."
  fi
  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
  chmod 0750 "$APP_DIR"
  chmod 0755 "$APP_DIR/install.sh"
  ensure_app_access
  PANEL_URL=""
  INTERVAL="30"
  VERIFY_TLS="1"
  write_state
  write_service
  echo
  echo "Installed in ${APP_DIR}"
  echo "Choose Connect to panel, then paste the node id and key from the panel."
}

connect_node() {
  require_ready
  if [ -z "$NODE_ID" ] || [ -z "$NODE_KEY" ] || [ -z "$PANEL_URL" ]; then
    echo "Create the node in the panel first. The key is shown only once."
  fi
  if [ -f "$APP_DIR/node.env" ] && [ "$ASSUME_YES" -ne 1 ] && [ "$URL_SET" -ne 1 ]; then
    local answer
    answer="$(prompt "Replace the saved connection? Type yes: ")"
    [ "$answer" = "yes" ] || die "Cancelled."
  fi
  if [ -f "$APP_DIR/node.env" ] && [ "$INTERVAL_SET" -ne 1 ]; then
    local current
    current="$(env_value INTERVAL)"
    [ -n "$current" ] && INTERVAL="$current"
  fi
  if [ -z "$PANEL_URL" ]; then
    echo "Use http:// and the panel port until a certificate is installed."
    PANEL_URL="$(prompt "Panel URL: ")"
  fi
  PANEL_URL="${PANEL_URL%/}"
  valid_url "$PANEL_URL" || die "Enter the panel address, including http:// or https://."
  if [ -z "$NODE_ID" ]; then
    NODE_ID="$(prompt "Node id: ")"
  fi
  NODE_ID="${NODE_ID#"${NODE_ID%%[![:space:]]*}"}"
  NODE_ID="${NODE_ID%"${NODE_ID##*[![:space:]]}"}"
  valid_node_id "$NODE_ID" || die "The node id is not valid."
  if [ -z "$NODE_KEY" ]; then
    NODE_KEY="$(prompt_secret "Node key: ")"
  fi
  valid_key "$NODE_KEY" || die "The node key is not valid."
  if [ "$INTERVAL_SET" -ne 1 ] && [ -r /dev/tty ]; then
    local entered
    entered="$(prompt "Report interval in seconds [${INTERVAL}]: ")"
    if [ -n "$entered" ]; then
      INTERVAL="$entered"
    fi
  fi
  valid_interval "$INTERVAL" || die "The interval must be from 5 to 3600 seconds."
  if [ "$VERIFY_TLS" = "1" ] && [ "$URL_SET" -ne 1 ] && [ -r /dev/tty ] && [[ "$PANEL_URL" == https://* ]]; then
    local tls
    tls="$(prompt "Verify the TLS certificate [yes]: ")"
    case "${tls,,}" in
      ""|y|yes) VERIFY_TLS="1" ;;
      n|no) VERIFY_TLS="0" ;;
      *) die "Answer yes or no." ;;
    esac
  fi
  write_env
  write_state
  write_service
  systemctl enable "$SERVICE"
  if systemctl is-active --quiet "$SERVICE"; then
    systemctl restart "$SERVICE"
  else
    systemctl start "$SERVICE"
  fi
  echo "Checking the connection."
  if runuser -u "$APP_USER" -- env NODE_CONFIG="${APP_DIR}/node.env" "$PYTHON" "${APP_DIR}/node.py" --once; then
    echo "Connected. Reports are sent every ${INTERVAL} seconds."
  else
    echo "The service is running, but the first report was not accepted. Choose View logs."
  fi
}

update_node() {
  require_ready
  load_state
  ensure_python
  local stage
  stage="$(mktemp -d)"
  echo "Downloading the update."
  if ! fetch_source "$stage"; then
    rm -rf "$stage"
    die "Could not download the update."
  fi
  cp -a "$stage"/. "$APP_DIR"/
  rm -rf "$stage"
  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
  chmod 0750 "$APP_DIR"
  chmod 0755 "$APP_DIR/install.sh"
  if [ -f "$APP_DIR/node.env" ]; then
    chmod 0640 "$APP_DIR/node.env"
  fi
  ensure_app_access
  write_service
  if [ -f "$APP_DIR/node.env" ] && systemctl is-active --quiet "$SERVICE"; then
    systemctl restart "$SERVICE"
  fi
  echo "Updated. The connection was kept."
}

start_node() {
  require_connected
  systemctl start "$SERVICE"
  echo "Started."
}

stop_node() {
  require_connected
  systemctl stop "$SERVICE"
  echo "Stopped."
}

restart_node() {
  require_connected
  systemctl restart "$SERVICE"
  echo "Restarted."
}

show_logs() {
  require_ready
  journalctl -u "$SERVICE" -n 80 --no-pager
}

show_status() {
  require_ready
  load_state
  local active="inactive" enabled="disabled" node_id=""
  systemctl is-active --quiet "$SERVICE" && active="active"
  systemctl is-enabled --quiet "$SERVICE" && enabled="enabled"
  node_id="$(env_value NODE_ID || true)"
  echo "Directory: ${APP_DIR}"
  echo "Service: ${active}, ${enabled}"
  if [ -f "$APP_DIR/node.env" ]; then
    echo "Panel: $(env_value PANEL_URL)"
    echo "Node: ${node_id}"
    echo "Interval: $(env_value INTERVAL) seconds"
  else
    echo "Not connected to a panel."
  fi
}

change_interval() {
  local chosen current entered
  require_connected
  if [ "$INTERVAL_SET" -ne 1 ]; then
    [ -r /dev/tty ] || die "Pass the interval in seconds."
    current="$(env_value INTERVAL)"
    [ -n "$current" ] || current="30"
    entered="$(prompt "Report interval in seconds [${current}]: ")"
    chosen="${entered:-$current}"
  else
    chosen="$INTERVAL"
  fi
  valid_interval "$chosen" || die "The interval must be from 5 to 3600 seconds."
  set_interval_value "$chosen"
  PANEL_URL="$(env_value PANEL_URL)"
  VERIFY_TLS="$(env_value VERIFY_TLS)"
  [ -n "$VERIFY_TLS" ] || VERIFY_TLS="1"
  INTERVAL="$chosen"
  write_state
  if systemctl is-active --quiet "$SERVICE"; then
    systemctl restart "$SERVICE"
  fi
  echo "Reports are sent every ${INTERVAL} seconds."
}

remove_dir() {
  case "$APP_DIR" in
    /*/*) ;;
    *) die "Refusing to remove ${APP_DIR}." ;;
  esac
  case "$APP_DIR" in
    /|/root|/opt|/usr|/etc|/var|/home|/tmp|/usr/local)
      die "Refusing to remove ${APP_DIR}."
      ;;
  esac
  [ -f "$APP_DIR/node.py" ] || die "Refusing to remove ${APP_DIR}: node.py is missing."
  [ -f "$APP_DIR/install.sh" ] || die "Refusing to remove ${APP_DIR}: install.sh is missing."
  [ -f "$STATE_FILE" ] || die "Refusing to remove ${APP_DIR}: the install state is missing."
  rm -rf "$APP_DIR"
}

uninstall_node() {
  require_ready
  if [ "$ASSUME_YES" -ne 1 ]; then
    echo "This removes the service, the files, and the saved node key."
    local answer
    answer="$(prompt "Type DELETE to continue: ")"
    [ "$answer" = "DELETE" ] || die "Cancelled."
  fi
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
  remove_dir
  userdel "$APP_USER" >/dev/null 2>&1 || true
  echo "Uninstalled."
}

parse_args() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      install|connect|update|start|stop|restart|status|logs|interval|uninstall)
        ACTION="$1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
    esac
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)
        APP_DIR="${2:-}"
        [ -n "$APP_DIR" ] || die "Missing directory after --dir."
        shift 2
        ;;
      --url)
        PANEL_URL="${2:-}"
        URL_SET=1
        shift 2
        ;;
      --id)
        NODE_ID="${2:-}"
        shift 2
        ;;
      --key)
        NODE_KEY="${2:-}"
        shift 2
        ;;
      --interval)
        INTERVAL="${2:-}"
        INTERVAL_SET=1
        shift 2
        ;;
      --insecure)
        VERIFY_TLS="0"
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [ "$ACTION" = "interval" ] && [ "$INTERVAL_SET" -eq 0 ]; then
          INTERVAL="$1"
          INTERVAL_SET=1
          shift
        else
          die "Unknown argument: $1"
        fi
        ;;
    esac
  done
}

pause_menu() {
  [ -r /dev/tty ] || return 0
  prompt "Press Enter to continue: " >/dev/null
}

run_action() {
  set +e
  (
    set -euo pipefail
    "$@"
  )
  set -e
  pause_menu
}

menu_loop() {
  local choice
  while true; do
    echo
    echo "Traffic Node"
    if installed; then
      locate_installed_dir
      if [ -f "$APP_DIR/node.env" ]; then
        if [ -z "$PYTHON" ] && command -v python3 >/dev/null 2>&1; then
          PYTHON="$(command -v python3)"
        fi
        echo "Connected: $(env_value PANEL_URL || true)"
      else
        echo "Installed in ${APP_DIR}, not connected"
      fi
    else
      APP_DIR=""
      echo "Not installed"
    fi
    cat <<'EOF'

  1) Install
  2) Connect to panel
  3) Update
  4) Start
  5) Stop
  6) Restart
  7) View logs
  8) Status
  9) Change interval
 10) Uninstall
  0) Exit
EOF
    choice="$(prompt "Select: ")"
    case "$choice" in
      1) run_action install_node ;;
      2) run_action connect_node ;;
      3) run_action update_node ;;
      4) run_action start_node ;;
      5) run_action stop_node ;;
      6) run_action restart_node ;;
      7) run_action show_logs ;;
      8) run_action show_status ;;
      9) run_action change_interval ;;
      10) run_action uninstall_node ;;
      0|q) exit 0 ;;
      *) echo "Unknown choice." ;;
    esac
  done
}

main() {
  parse_args "$@"
  need_root
  require_deb
  load_proxy
  if [ -z "$ACTION" ]; then
    [ -r /dev/tty ] || die "Pass an action, or run this from a terminal."
    menu_loop
    exit 0
  fi
  case "$ACTION" in
    install) install_node ;;
    connect) connect_node ;;
    update) update_node ;;
    start) start_node ;;
    stop) stop_node ;;
    restart) restart_node ;;
    status) show_status ;;
    logs) show_logs ;;
    interval) change_interval ;;
    uninstall) uninstall_node ;;
  esac
}

main "$@"
