# docker-arduino-ide

[Arduino IDE 2](https://www.arduino.cc/en/software) in a container: run it headlessly over
VNC/noVNC, or on a host X11 display, with USB serial boards passed in.

Image versions match the upstream release exactly: image `2.3.10` runs Arduino IDE
`2.3.10`, built from the pinned, checksummed upstream Linux release. A daily workflow opens
a pull request when upstream publishes a new stable release.

## Images

    ghcr.io/anarkiwi/docker-arduino-ide:2.3.10
    docker.io/anarkiwi/arduino-ide:2.3.10

Tags: `X.Y.Z`, `latest`. linux/amd64.

## Use

`HOME` in the container is the data directory, `/data` by default, so the sketchbook,
`.arduinoIDE` and `.arduino15` (cores, libraries, toolchains) all live on one mount. Run as
yourself so the files stay yours:

    docker run --rm -p 5900:5900 -p 6080:6080 \
      -u $(id -u):$(id -g) --shm-size=512m \
      -v ~/arduino:/data \
      ghcr.io/anarkiwi/docker-arduino-ide:latest

With no host X11 display available the container starts its own Xvfb, exports it on VNC
port 5900, and serves noVNC on <http://localhost:6080/vnc.html>.

To use the host's display, GPU and boards instead, pass them in — `bin/arduino-ide-docker`
wraps this, mounting your home directory at its own path and adding every `/dev/ttyACM*`
and `/dev/ttyUSB*` with the group that owns it:

    ./bin/arduino-ide-docker

Cores, libraries and toolchains are downloaded by the IDE on first run into the data
directory, not baked into the image.

## Existing install

The IDE and the bundled `arduino-cli` record absolute paths — the sketchbook location, the
board manager's data directory, scan results. Mount an existing home directory **at the
path it has on the host** and point `ARDUINO_IDE_HOME` at it, and the container picks up
the boards, libraries and preferences already installed. On vek-x:

    docker run --rm \
      -u $(id -u):$(id -g) --shm-size=512m \
      -e ARDUINO_IDE_HOME=/home/josh \
      -v /home/josh:/home/josh \
      -v /scratch/anarkiwi:/scratch/anarkiwi \
      -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
      --device /dev/ttyACM0 --group-add "$(stat -c %g /dev/ttyACM0)" \
      ghcr.io/anarkiwi/docker-arduino-ide:latest

`/scratch/anarkiwi` is there because `directories.user` in `~/.arduinoIDE/arduino-cli.yaml`
points outside the home directory; anything else referenced by absolute path needs the same
treatment. That replaces the unpacked `/usr/local/arduino` install without touching its
data.

See [docs/usage.md](docs/usage.md) for serial boards, VNC passwords, GPU passthrough and
the environment variables, and [docs/releasing.md](docs/releasing.md) for the release and
upstream tracking workflows.

## Test

    docker build -t arduino-ide:test .
    tests/smoke.sh arduino-ide:test

The smoke test checks the pinned version against the bundled application, compiles a sketch
for `arduino:avr:uno` with the bundled `arduino-cli`, boots the IDE headlessly and checks it
maps its window and populates the data directory as the calling user, checks VNC and noVNC
are serving, checks an unwritable data directory is rejected, and checks a shared host X11
display is used when one is present.

## Scope

The image is the upstream Linux build unpacked at `/opt/arduino-ide`, so it includes the
`arduino-cli`, `arduino-fwuploader`, `arduino-language-server` and `clangd` binaries the IDE
ships; `arduino-cli` and `arduino-fwuploader` are on `PATH` and can be run instead of the
IDE. Chromium's setuid sandbox needs `CAP_SYS_ADMIN`, which containers do not have by
default, so the IDE runs with `--no-sandbox` and the container is the boundary; set
`ARDUINO_IDE_SANDBOX=1` with `--cap-add SYS_ADMIN` to use it.

Arduino IDE is AGPL-3.0-or-later, © Arduino SA; this packaging is licensed separately, see
[LICENSE](LICENSE).
