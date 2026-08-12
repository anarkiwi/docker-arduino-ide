#!/bin/sh
# Run Arduino IDE either on a host X11 display passed into the container, or on
# a private Xvfb display exported over VNC (and noVNC). See docs/usage.md.
set -eu

: "${ARDUINO_IDE_HOME:=/data}"
: "${ARDUINO_IDE_HEADLESS:=auto}"
: "${ARDUINO_IDE_DISPLAY_WIDTH:=1600}"
: "${ARDUINO_IDE_DISPLAY_HEIGHT:=1000}"
: "${ARDUINO_IDE_DISPLAY_DEPTH:=24}"
: "${DISPLAY:=:0}"
: "${VNC_PORT:=5900}"
: "${NOVNC_PORT:=6080}"
: "${VNC_PASSWORD_FILE:=/run/secrets/vnc_password}"
: "${XDG_RUNTIME_DIR:=/tmp/runtime-arduino}"
export DISPLAY XDG_RUNTIME_DIR

log() { echo "entrypoint: $*" >&2; }
die() { log "$*"; exit 1; }

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
mkdir -p "${ARDUINO_IDE_HOME}" 2>/dev/null || true

# The IDE, the bundled arduino-cli and the toolchains it downloads all key off
# HOME: sketchbook, ~/.arduinoIDE and ~/.arduino15 land under one mount.
[ -w "${ARDUINO_IDE_HOME}" ] \
  || die "${ARDUINO_IDE_HOME} is not writable by uid $(id -u):$(id -g); chown the mounted directory to it, or run with a --user that owns it"
HOME=${ARDUINO_IDE_HOME}
export HOME

[ $# -gt 0 ] || set -- arduino-ide

# Only the Electron app needs a display and the Chromium flags; arduino-cli and
# arduino-fwuploader run against the same data directory without one.
needs_display=false
case "$1" in
  arduino-ide)
    needs_display=true
    for arg in "$@"; do
      case "${arg}" in
        --version|-V|--help|-h) needs_display=false;;
      esac
    done

    # Chromium's setuid helper has to unshare namespaces, which needs
    # CAP_SYS_ADMIN the container does not have by default; the container is the
    # sandbox instead.
    case "${ARDUINO_IDE_SANDBOX:-0}" in
      1|true|yes) :;;
      *) set -- "$@" --no-sandbox;;
    esac

    # Electron's zygote maps its shared memory in /dev/shm; docker's default 64M
    # is too small for Chromium and the renderer dies on startup.
    shm_kb=$(df -Pk /dev/shm 2>/dev/null | awk 'NR == 2 { print $2 }')
    if [ -n "${shm_kb}" ] && [ "${shm_kb}" -lt 262144 ]; then
      log "/dev/shm is ${shm_kb}K; passing --disable-dev-shm-usage, run with --shm-size=512m instead"
      set -- "$@" --disable-dev-shm-usage
    fi
    ;;
esac

# A local display (:N[.S]) is a host display only if its socket is mounted in.
local_display=false
display_number=
case "${DISPLAY}" in
  :*) local_display=true
      display_number=${DISPLAY#:}
      display_number=${display_number%%.*};;
esac
# A remote DISPLAY (host:0) is always someone else's server; a local one is
# only usable if its socket was mounted in.
host_display=true
if [ "${local_display}" = true ] && [ ! -e "/tmp/.X11-unix/X${display_number}" ]; then
  host_display=false
fi

case "${ARDUINO_IDE_HEADLESS}" in
  1|true|yes) headless=true;;
  0|false|no) headless=false;;
  auto) if [ "${host_display}" = true ]; then headless=false; else headless=true; fi;;
  *) die "ARDUINO_IDE_HEADLESS must be auto, 1 or 0 (got ${ARDUINO_IDE_HEADLESS})";;
esac

pids=
cleanup() {
  [ -n "${pids}" ] || return 0
  # shellcheck disable=SC2086 # pids is a deliberately word split list.
  kill ${pids} 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

start_display() {
  [ "${local_display}" = true ] \
    || die "headless mode needs a local DISPLAY like :0 (got ${DISPLAY})"
  geometry="${ARDUINO_IDE_DISPLAY_WIDTH}x${ARDUINO_IDE_DISPLAY_HEIGHT}x${ARDUINO_IDE_DISPLAY_DEPTH}"
  log "starting Xvfb on ${DISPLAY} (${geometry})"
  Xvfb "${DISPLAY}" -screen 0 "${geometry}" -nolisten tcp &
  pids="${pids} $!"

  waited=0
  while [ "${waited}" -lt 100 ]; do
    xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && return 0
    waited=$((waited + 1))
    sleep 0.1
  done
  die "Xvfb did not come up on ${DISPLAY}"
}

start_vnc() {
  set -- x11vnc -display "${DISPLAY}" -rfbport "${VNC_PORT}" \
    -forever -shared -noxdamage -quiet
  if [ -r "${VNC_PASSWORD_FILE}" ]; then
    # x11vnc reads the file itself, so the password never appears in argv.
    log "using VNC password from ${VNC_PASSWORD_FILE}"
    set -- "$@" -passwdfile "${VNC_PASSWORD_FILE}"
  else
    log "no password file at ${VNC_PASSWORD_FILE}; VNC is unauthenticated"
    set -- "$@" -nopw
  fi
  log "starting x11vnc on port ${VNC_PORT}"
  "$@" &
  pids="${pids} $!"
}

start_novnc() {
  log "starting noVNC on port ${NOVNC_PORT} (http://localhost:${NOVNC_PORT}/vnc.html)"
  websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
  pids="${pids} $!"
}

if [ "${headless}" = true ] && [ "${needs_display}" = true ]; then
  start_display
  if [ "${VNC_PORT}" != 0 ]; then
    start_vnc
    [ "${NOVNC_PORT}" = 0 ] || start_novnc
  fi
fi

log "running: $*"
"$@" &
ide_pid=$!
pids="${pids} ${ide_pid}"
wait "${ide_pid}"
