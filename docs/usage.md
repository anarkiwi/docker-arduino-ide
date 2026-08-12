# Usage

## Data directory

`HOME` inside the container is the data directory, `/data` by default. Everything Arduino
IDE keeps per user lands there:

| Path | Contents |
| --- | --- |
| `Arduino/` | sketchbook |
| `.arduinoIDE/` | IDE settings, `arduino-cli.yaml`, plugins, logs |
| `.arduino15/` | board packages, libraries, toolchains, indexes, build cache |

Mount a host directory there and run as yourself, or the files come out owned by uid 1000:

    docker run --rm -u $(id -u):$(id -g) --shm-size=512m \
      -v ~/arduino:/data ghcr.io/anarkiwi/docker-arduino-ide:latest

The entrypoint refuses to start if the data directory is not writable by the uid it is
running as, rather than letting the IDE half start against a read only home.

Nothing board specific is baked into the image. On first run the IDE downloads its builtin
tools and the cores you add from Boards Manager into `.arduino15`, so keep that mount
across runs or every start pays for the downloads again.

### An existing install

Both the IDE and `arduino-cli` store absolute paths: `sketchbook.path` in
`.arduino15/preferences.txt`, `directories.*` in `.arduinoIDE/arduino-cli.yaml`, and the
paths recorded for installed cores. Mounting an existing home directory at `/data` leaves
those dangling. Mount it at its own path and set `ARDUINO_IDE_HOME` instead:

    docker run --rm -u $(id -u):$(id -g) --shm-size=512m \
      -e ARDUINO_IDE_HOME=/home/josh \
      -v /home/josh:/home/josh \
      -v /scratch/anarkiwi:/scratch/anarkiwi \
      -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
      ghcr.io/anarkiwi/docker-arduino-ide:latest

Directories referenced from `arduino-cli.yaml` that sit outside the home directory need
their own mount at the same path — on vek-x `directories.user` is `/scratch/anarkiwi`.

## Serial boards

Upload and Serial Monitor need the board's device node and its owning group. The image user
is in `dialout`, which covers the usual case, but the group id has to match the host's:

    --device /dev/ttyACM0 --group-add "$(stat -c %g /dev/ttyACM0)"

`bin/arduino-ide-docker` adds every `/dev/ttyACM*` and `/dev/ttyUSB*` present at start,
each with the group that owns it. Boards that enumerate after the container starts are not
picked up — a Leonardo, Micro or Teensy re-enumerates while uploading, which the bootloader
reset makes visible as a new device node. Pass the whole subsystem if you hit that:

    -v /dev:/dev --group-add "$(getent group dialout | cut -d: -f3)"

Network boards found over mDNS need `--network host` to be discovered.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ARDUINO_IDE_HOME` | `/data` | data directory, used as `HOME` |
| `ARDUINO_IDE_HEADLESS` | `auto` | `1` always start Xvfb, `0` never, `auto` only when no host display |
| `ARDUINO_IDE_DISPLAY_WIDTH` | `1600` | Xvfb screen width |
| `ARDUINO_IDE_DISPLAY_HEIGHT` | `1000` | Xvfb screen height |
| `ARDUINO_IDE_DISPLAY_DEPTH` | `24` | Xvfb colour depth |
| `ARDUINO_IDE_SANDBOX` | `0` | `1` uses Chromium's setuid sandbox, needs `--cap-add SYS_ADMIN` |
| `VNC_PORT` | `5900` | x11vnc port; `0` disables VNC and noVNC |
| `NOVNC_PORT` | `6080` | noVNC port; `0` disables noVNC only |
| `VNC_PASSWORD_FILE` | `/run/secrets/vnc_password` | password file, if present |

## Shared memory

Chromium's renderer maps its shared memory in `/dev/shm`, and docker's default 64M is not
enough for the editor. Run with `--shm-size=512m`. Without it the entrypoint falls back to
`--disable-dev-shm-usage`, which keeps the IDE alive by moving those allocations to disk,
more slowly.

## Headless (VNC and noVNC)

With no host X11 display the container starts `Xvfb`, `x11vnc` and noVNC:

    docker run --rm -p 5900:5900 -p 6080:6080 --shm-size=512m \
      -v ~/arduino:/data ghcr.io/anarkiwi/docker-arduino-ide:latest

* VNC client: `localhost:5900`
* Browser: <http://localhost:6080/vnc.html>

Rendering uses Mesa's llvmpipe software rasteriser unless a GPU is passed in with
`--device /dev/dri`, which is fine for an editor.

### VNC password

Without a password file the VNC server is unauthenticated — publish it only on a trusted
network or bind it to localhost (`-p 127.0.0.1:5900:5900`). To require a password, provide
it as a Docker secret; `x11vnc` reads the file itself, so it never appears in the process
list or in `docker inspect`:

    echo 's3cret' | docker secret create vnc_password -    # swarm
    docker run --rm -v ~/vnc_password:/run/secrets/vnc_password:ro ...   # plain docker

noVNC's HTTP endpoint is plain HTTP; put it behind a TLS reverse proxy if it leaves the
host.

## Host X11 display

Mounting the X11 socket makes the entrypoint skip Xvfb and VNC and use your display
directly:

    docker run --rm -u $(id -u):$(id -g) --shm-size=512m \
      -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
      --device /dev/dri \
      -v ~/arduino:/data ghcr.io/anarkiwi/docker-arduino-ide:latest

`bin/arduino-ide-docker` does that for you, mounting your home directory at its own path
and adding the serial devices and a GPU when the host has them:

    ./bin/arduino-ide-docker
    ARDUINO_IDE_IMAGE=ghcr.io/anarkiwi/docker-arduino-ide:2.3.10 ./bin/arduino-ide-docker

| Variable | Default | Purpose |
| --- | --- | --- |
| `ARDUINO_IDE_IMAGE` | `ghcr.io/anarkiwi/docker-arduino-ide:latest` | image to run |
| `ARDUINO_IDE_DOCKER` | `docker` | container runtime |
| `ARDUINO_IDE_HOME` | `$HOME` | host directory mounted at its own path |
| `ARDUINO_IDE_EXTRA_DEVICES` | | extra device nodes to pass in, word split |
| `ARDUINO_IDE_DOCKER_OPTS` | | extra `docker run` options, word split |

If your X server needs authorisation, the wrapper mounts `$XAUTHORITY`. `xhost` rules
otherwise apply as usual.

## Sandbox

Chromium's setuid sandbox helper has to unshare namespaces, which needs `CAP_SYS_ADMIN`
that containers do not have by default, so the IDE is started with `--no-sandbox` and the
container is the isolation boundary. The helper is still installed setuid: to use it,

    -e ARDUINO_IDE_SANDBOX=1 --cap-add SYS_ADMIN

## Command line tools

The bundled binaries are on `PATH` and run without starting a display, against the same
data directory:

    docker run --rm -u $(id -u):$(id -g) -v ~/arduino:/data \
      ghcr.io/anarkiwi/docker-arduino-ide:latest \
      arduino-cli compile -b arduino:avr:uno /data/Arduino/blink

    docker run --rm ghcr.io/anarkiwi/docker-arduino-ide:latest arduino-fwuploader version

Use `--entrypoint` to bypass the entrypoint entirely:

    docker run --rm --entrypoint sh ghcr.io/anarkiwi/docker-arduino-ide:latest -c 'ls /opt/arduino-ide'
