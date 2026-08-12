# syntax=docker/dockerfile:1

# Pinned upstream release, updated by .github/workflows/upstream-bump.yml. The
# image release version is ARDUINO_IDE_VERSION.
ARG ARDUINO_IDE_VERSION=2.3.10
ARG ARDUINO_IDE_SHA256=cc8a0b01e763d4646b670ce70c1bc8c389a0fa14ab556dcc0749c03f475a7975

FROM debian:trixie-slim AS build
ARG ARDUINO_IDE_VERSION
ARG ARDUINO_IDE_SHA256
SHELL ["/bin/sh", "-eux", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# The zip is the same Electron tree as the AppImage without the FUSE image
# around it, so it needs no extraction step at runtime.
RUN curl -fsSL -o ide.zip \
      "https://github.com/arduino/arduino-ide/releases/download/${ARDUINO_IDE_VERSION}/arduino-ide_${ARDUINO_IDE_VERSION}_Linux_64bit.zip" \
    && printf '%s  ide.zip\n' "${ARDUINO_IDE_SHA256}" > ide.sha256 \
    && sha256sum -c ide.sha256 \
    && unzip -q ide.zip \
    && mkdir -p /out/opt \
    && mv "arduino-ide_${ARDUINO_IDE_VERSION}_Linux_64bit" /out/opt/arduino-ide \
    && rm ide.zip ide.sha256

# The IDE drives the boards through the arduino-cli, fwuploader and language
# server binaries it ships in resources; nothing here is fetched at runtime.
RUN cli=/out/opt/arduino-ide/resources/app/lib/backend/resources \
    && test -x "${cli}/arduino-cli" \
    && test -x "${cli}/arduino-fwuploader" \
    && test -x "${cli}/arduino-language-server" \
    && test -x /out/opt/arduino-ide/arduino-ide

FROM debian:trixie-slim
ARG ARDUINO_IDE_VERSION
SHELL ["/bin/sh", "-eux", "-c"]

# Chromium's shared library set, plus libsecret for the IDE's credential store
# and libgl1-mesa-dri for software (llvmpipe) OpenGL so the editor renders
# without a GPU. xvfb/x11vnc/novnc provide the headless display served by
# entrypoint.sh. Mount /dev/dri to use the host GPU instead.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
        libcairo2 libcups2t64 libdbus-1-3 libdrm2 libexpat1 libgbm1 \
        libgl1 libgl1-mesa-dri libglib2.0-0t64 libgtk-3-0t64 libnspr4 \
        libnss3 libpango-1.0-0 libsecret-1-0 libx11-6 libx11-xcb1 \
        libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 \
        libxrandr2 libxshmfence1 \
        ca-certificates novnc x11-utils x11vnc xauth xvfb \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -G dialout -s /bin/sh arduino \
    && install -d -o arduino -g arduino /data \
    && install -d -m 1777 /tmp/.X11-unix

COPY --from=build /out/opt /opt
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Electron's setuid sandbox helper: keeps the renderer namespaced even for an
# unprivileged --user, and works for any uid. ARDUINO_IDE_NO_SANDBOX=1 drops it
# for hosts whose seccomp or userns policy rejects it.
RUN chown root:root /opt/arduino-ide/chrome-sandbox \
    && chmod 4755 /opt/arduino-ide/chrome-sandbox \
    && ln -s /opt/arduino-ide/arduino-ide /usr/local/bin/arduino-ide \
    && ln -s /opt/arduino-ide/resources/app/lib/backend/resources/arduino-cli \
        /usr/local/bin/arduino-cli \
    && ln -s /opt/arduino-ide/resources/app/lib/backend/resources/arduino-fwuploader \
        /usr/local/bin/arduino-fwuploader

ENV ARDUINO_IDE_VERSION=${ARDUINO_IDE_VERSION} \
    ARDUINO_IDE_HOME=/data \
    DISPLAY=:0 \
    ARDUINO_IDE_DISPLAY_WIDTH=1600 \
    ARDUINO_IDE_DISPLAY_HEIGHT=1000 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080 \
    XDG_RUNTIME_DIR=/tmp/runtime-arduino

# By name, not 1000:1000: a numeric USER gets no supplementary groups, and
# dialout is what makes a passed in /dev/ttyACM* openable without --group-add.
USER arduino
WORKDIR /data
VOLUME ["/data"]
EXPOSE 5900 6080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["arduino-ide"]

LABEL org.opencontainers.image.title="Arduino IDE" \
      org.opencontainers.image.description="Arduino IDE 2, headless over VNC or on a host X11 display, with serial boards passed in" \
      org.opencontainers.image.version="${ARDUINO_IDE_VERSION}" \
      org.opencontainers.image.source="https://github.com/anarkiwi/docker-arduino-ide" \
      org.opencontainers.image.url="https://www.arduino.cc/en/software" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"
