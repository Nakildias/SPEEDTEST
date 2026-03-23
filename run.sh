#!/usr/bin/env bash
# Speedtest local server — deps + venv + optional port cleanup (Arch / Fedora / Debian).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DEFAULT_PORT=8080

detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID_LIKE:-} ${ID:-}" in
      *arch*) echo arch ;;
      *fedora* | *rhel* | *centos*) echo fedora ;;
      *debian* | *ubuntu*) echo debian ;;
      *)
        if [[ -f /etc/arch-release ]]; then echo arch
        elif [[ -f /etc/fedora-release ]]; then echo fedora
        elif [[ -f /etc/debian_version ]]; then echo debian
        else echo unknown
        fi
        ;;
    esac
  elif [[ -f /etc/arch-release ]]; then echo arch
  elif [[ -f /etc/fedora-release ]]; then echo fedora
  elif [[ -f /etc/debian_version ]]; then echo debian
  else echo unknown
  fi
}

DISTRO="$(detect_distro)"

run_elevated() {
  if [[ "${EUID:-0}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  elif command -v doas >/dev/null 2>&1; then
    doas "$@"
  else
    echo "Root privileges needed for: $*" >&2
    echo "Re-run with sudo or install sudo/doas." >&2
    return 1
  fi
}

ensure_system_python() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  echo "python3 not found — installing via package manager (you may be prompted for a password)..." >&2
  case "$DISTRO" in
    arch)
      run_elevated pacman -Sy --needed --noconfirm python python-pip
      ;;
    fedora)
      run_elevated dnf install -y python3 python3-pip
      ;;
    debian)
      run_elevated apt-get update -qq
      run_elevated apt-get install -y python3 python3-venv python3-pip
      ;;
    *)
      echo "Unknown distro: install python3, python3-venv (if needed), and pip, then re-run." >&2
      return 1
      ;;
  esac
}

ensure_venv_package() {
  # Debian/Ubuntu often need python3-venv for 'python3 -m venv'
  [[ "$DISTRO" == debian ]] || return 0
  if python3 -m venv --help >/dev/null 2>&1; then
    python3 -c "import venv" 2>/dev/null && return 0
  fi
  echo "Installing python3-venv (password may be requested)..." >&2
  run_elevated apt-get update -qq
  run_elevated apt-get install -y python3-venv python3-pip
}

VENV="$ROOT/.venv"

create_venv() {
  ensure_venv_package
  if ! python3 -m venv "$VENV" 2>/tmp/speedtest-venv.err; then
    cat /tmp/speedtest-venv.err >&2 || true
    if [[ "$DISTRO" == fedora ]] && grep -qi ensurepip /tmp/speedtest-venv.err 2>/dev/null; then
      echo "Retrying after python3-devel (Fedora)..." >&2
      run_elevated dnf install -y python3-devel
      python3 -m venv "$VENV"
    else
      echo "Failed to create venv. Install OS 'python3-venv' (or equivalent) and re-run." >&2
      return 1
    fi
  fi
}

port_available() {
  local p="$1"
  python3 -c "import socket; s=socket.socket(); s.bind(('0.0.0.0', int('${p}'))); s.close()" 2>/dev/null
}

# PIDs listening on TCP port (best effort across distros).
pids_on_port() {
  local port=$1
  local p

  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r line; do
      p=$(echo "$line" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')
      [[ -n "$p" ]] && echo "$p"
    done < <(ss -tlnp "sport = :$port" 2>/dev/null || true)
    return 0
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
    return 0
  fi

  if command -v fuser >/dev/null 2>&1; then
    fuser -n tcp "$port" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true
  fi
}

free_port_listeners() {
  local port=$1
  local pid owner myuid killed=0
  myuid=$(id -u)

  mapfile -t pids < <(pids_on_port "$port" | sort -u)
  if [[ ${#pids[@]} -eq 0 || -z "${pids[0]:-}" ]]; then
    echo "Could not detect a process listening on port $port (install iproute2/ss or lsof for better detection)." >&2
    return 1
  fi

  for pid in "${pids[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if [[ ! -r "/proc/$pid" ]]; then
      continue
    fi
    owner=$(stat -c %u "/proc/$pid" 2>/dev/null || echo "")
    if [[ "$owner" == "$myuid" ]]; then
      if kill "$pid" 2>/dev/null; then
        echo "Stopped your process PID $pid on port $port." >&2
        killed=1
      fi
    else
      echo "Port $port is used by PID $pid (another user); trying elevated stop (password may be asked)..." >&2
      if run_elevated kill "$pid" 2>/dev/null; then
        echo "Stopped PID $pid." >&2
        killed=1
      else
        echo "Could not stop PID $pid." >&2
      fi
    fi
  done

  [[ "$killed" -eq 1 ]]
}

resolve_port() {
  local PORT="${PORT:-$DEFAULT_PORT}"
  local line

  while true; do
    if port_available "$PORT"; then
      echo "$PORT"
      return 0
    fi

    echo "Port $PORT is already in use." >&2
    read -r -p "Enter a different port (1–65535), or press Enter to try stopping listeners on $PORT: " line || exit 1

    if [[ -z "${line// }" ]]; then
      free_port_listeners "$PORT" || true
      sleep 0.35
      if port_available "$PORT"; then
        echo "$PORT"
        return 0
      fi
      echo "Port $PORT is still in use — try another port or stop the service manually." >&2
      continue
    fi

    if ! [[ "$line" =~ ^[0-9]+$ ]] || (( line < 1 || line > 65535 )); then
      echo "Enter a number between 1 and 65535." >&2
      continue
    fi
    PORT="$line"
  done
}

# --- main ---
ensure_system_python
if [[ ! -d "$VENV" ]]; then
  create_venv
fi

# shellcheck source=/dev/null
source "$VENV/bin/activate"

pip install -q --upgrade pip
pip install -r "$ROOT/requirements.txt" --quiet

PORT="$(resolve_port)"
export PORT
echo "Starting server on http://0.0.0.0:${PORT}"
exec uvicorn server:app --host 0.0.0.0 --port "$PORT"
