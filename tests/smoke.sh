#!/bin/sh
# Smoke test an Arduino IDE image: tests/smoke.sh <image> [expected-version]
# Starts the IDE headlessly, checks it maps its window, compiles a sketch with
# the bundled arduino-cli, and checks the display, VNC and noVNC paths.
set -eu

image=${1:?usage: smoke.sh <image> [expected-version]}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
expected=${2:-$(sed -n 's/^ARG ARDUINO_IDE_VERSION=//p' "${here}/../Dockerfile")}
boot_timeout=${ARDUINO_IDE_SMOKE_TIMEOUT:-240}
compile=${ARDUINO_IDE_SMOKE_COMPILE:-1}

work=$(mktemp -d)
containers=
volumes=
cleanup() {
  # shellcheck disable=SC2086 # deliberately word split lists.
  [ -z "${containers}" ] || docker rm -f ${containers} >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  [ -z "${volumes}" ] || docker volume rm -f ${volumes} >/dev/null 2>&1 || true
  chmod -R u+w "${work}" 2>/dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# Wait for a command to succeed, or fail after boot_timeout seconds.
wait_for() {
  what=$1
  shift
  waited=0
  while [ "${waited}" -lt "${boot_timeout}" ]; do
    "$@" >/dev/null 2>&1 && return 0
    waited=$((waited + 1))
    sleep 1
  done
  fail "timed out after ${boot_timeout}s waiting for ${what}"
}

# The window title carries the version, so it is the check that the Electron
# app really started rather than just the entrypoint.
ide_window() {
  docker exec "$1" xwininfo -root -children 2>/dev/null \
    | sed -n 's/.*"\([^"]* | Arduino IDE [^"]*\)".*/\1/p' | head -1
}
has_ide_window() { [ -n "$(ide_window "$1")" ]; }

# 1. Versions, and no display started for commands that do not need one.
docker run --rm "${image}" arduino-cli version >"${work}/cli" 2>"${work}/cli.err"
grep -q "^arduino-cli" "${work}/cli" || fail "arduino-cli version: $(cat "${work}/cli")"
grep -q "starting Xvfb" "${work}/cli.err" && fail "arduino-cli started a display server"
env_version=$(docker run --rm --entrypoint sh "${image}" -c 'printf %s "$ARDUINO_IDE_VERSION"')
[ "${env_version}" = "${expected}" ] \
  || fail "image ARDUINO_IDE_VERSION ${env_version} != ${expected}"
app_version=$(docker run --rm --entrypoint sh "${image}" -c \
  'sed -n "s/.*\"version\": *\"\([^\"]*\)\".*/\1/p" \
     /opt/arduino-ide/resources/app/package.json | head -1')
[ "${app_version}" = "${expected}" ] \
  || fail "bundled app version ${app_version} != ${expected}"
ok "Arduino IDE ${expected}, $(head -1 "${work}/cli")"

# The IDE drives boards through the binaries it ships beside itself; a missing
# one turns into a runtime failure only when a board is selected.
docker run --rm --entrypoint sh "${image}" -c \
  'cd /opt/arduino-ide/resources/app/lib/backend/resources \
   && test -x arduino-cli && test -x arduino-fwuploader \
   && test -x arduino-language-server && test -x clangd' \
  || fail "bundled arduino tooling is incomplete"
groups=$(docker run --rm --entrypoint id "${image}" -nG)
case " ${groups} " in
  *" dialout "*) ok "bundled cli, fwuploader, language server and clangd; user in dialout";;
  *) fail "image user is not in dialout (${groups}), serial boards will not open";;
esac

# 2. A sketch compiles: the bundled cli, the core it downloads and the data
# directory under HOME all have to work together.
if [ "${compile}" = 1 ]; then
  mkdir -p "${work}/build/Arduino/blink"
  cat > "${work}/build/Arduino/blink/blink.ino" <<'EOF'
void setup() { pinMode(LED_BUILTIN, OUTPUT); }
void loop() { digitalWrite(LED_BUILTIN, HIGH); delay(500); digitalWrite(LED_BUILTIN, LOW); delay(500); }
EOF
  docker run --rm -u "$(id -u):$(id -g)" -v "${work}/build:/data" "${image}" \
    sh -c 'arduino-cli core update-index >/dev/null \
      && arduino-cli core install arduino:avr >/dev/null \
      && arduino-cli compile -b arduino:avr:uno /data/Arduino/blink' \
    >"${work}/compile" 2>&1 \
    || { tail -20 "${work}/compile" >&2; fail "compiling a sketch failed"; }
  grep -q "program storage space" "${work}/compile" \
    || fail "compile produced no size report: $(tail -3 "${work}/compile")"
  [ -d "${work}/build/.arduino15/packages/arduino/hardware/avr" ] \
    || fail "the avr core was not installed under the data directory"
  ok "compiled a sketch for arduino:avr:uno ($(sed -n 's/^Sketch uses //p' "${work}/compile" | head -1))"
else
  ok "compile test skipped (ARDUINO_IDE_SMOKE_COMPILE=${compile})"
fi

# 3. Headless boot, as the calling user against a bind mounted data dir.
mkdir -p "${work}/data"
name=arduino-ide-smoke-$$
containers="${containers} ${name}"
docker run -d --name "${name}" \
  -u "$(id -u):$(id -g)" \
  --shm-size=512m \
  -p 127.0.0.1::5900 -p 127.0.0.1::6080 \
  -v "${work}/data:/data" \
  "${image}" >/dev/null

wait_for "the IDE window" has_ide_window "${name}"
title=$(ide_window "${name}")
case "${title}" in
  *"| Arduino IDE ${expected}") ok "ide window: ${title}";;
  *) fail "window title '${title}' is not version ${expected}";;
esac

# HOME is the data directory, so the whole native layout lands on one mount.
for dir in .arduinoIDE .arduino15 Arduino; do
  [ -d "${work}/data/${dir}" ] || fail "${dir} not created in the data directory"
done
[ "$(find "${work}/data/.arduinoIDE" -maxdepth 0 -user "$(id -un)" | wc -l)" = 1 ] \
  || fail "data dir not owned by the calling user"
ok "sketchbook, .arduinoIDE and .arduino15 created and owned by the calling user"

# 4. VNC and noVNC are serving, checked from inside the container's netns
# (python3 comes with websockify).
probe() {
  docker run --rm --network "container:${name}" --entrypoint python3 "${image}" \
    -c "$1" 2>/dev/null || true
}
handshake=$(probe 'import socket
s = socket.create_connection(("127.0.0.1", 5900), 10)
print(s.recv(11).decode(errors="replace").strip())')
case "${handshake}" in
  RFB*) ok "vnc serving (${handshake})";;
  *) fail "no RFB handshake on the VNC port (got '${handshake}')";;
esac
status=$(probe 'import socket
s = socket.create_connection(("127.0.0.1", 6080), 10)
s.sendall(b"GET /vnc.html HTTP/1.0\r\n\r\n")
print(s.recv(64).decode(errors="replace").splitlines()[0])')
case "${status}" in
  *200*) ok "novnc serving (${status})";;
  *) fail "noVNC did not return 200 (got '${status}')";;
esac

vnc_port=$(docker port "${name}" 5900/tcp | head -1 | sed 's/.*://')
[ -n "${vnc_port}" ] || fail "VNC port not published"
ok "vnc published on 127.0.0.1:${vnc_port}"

docker rm -f "${name}" >/dev/null
containers=

# 5. An unwritable data directory fails immediately rather than half starting.
mkdir -p "${work}/locked"
chmod 500 "${work}/locked"
if docker run --rm -u 12345:12345 -v "${work}/locked:/data" "${image}" \
     >"${work}/locked.log" 2>&1; then
  fail "an unwritable data directory did not fail"
fi
grep -q "is not writable" "${work}/locked.log" \
  || fail "unwritable data dir gave no diagnostic: $(tail -3 "${work}/locked.log")"
ok "unwritable data directory rejected with a diagnostic"

# 6. Host display passthrough: an X server in another container, shared over a
# volume, is detected and used instead of starting Xvfb and VNC.
volume=arduino-ide-smoke-x11-$$
volumes="${volumes} ${volume}"
xserver=arduino-ide-smoke-x-$$
containers="${containers} ${xserver}"
docker volume create "${volume}" >/dev/null
docker run -d --name "${xserver}" -u "$(id -u):$(id -g)" \
  -v "${volume}:/tmp/.X11-unix" --entrypoint Xvfb \
  "${image}" :0 -screen 0 1600x1000x24 -nolisten tcp >/dev/null

mkdir -p "${work}/hostdata"
client=arduino-ide-smoke-client-$$
containers="${containers} ${client}"
docker run -d --name "${client}" -u "$(id -u):$(id -g)" --shm-size=512m \
  -v "${volume}:/tmp/.X11-unix" -v "${work}/hostdata:/data" \
  "${image}" >/dev/null

wait_for "the IDE on the shared X display" has_ide_window "${xserver}"
docker logs "${client}" 2>&1 | grep -q "starting Xvfb" \
  && fail "started Xvfb despite a host display being available"
ok "host X11 display used without starting Xvfb or VNC"

echo "PASS ${image} (${expected})"
