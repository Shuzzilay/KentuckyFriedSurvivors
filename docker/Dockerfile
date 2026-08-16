FROM steamcmd/steamcmd:ubuntu-22

LABEL org.opencontainers.image.title="project-zomboid-server" \
      org.opencontainers.image.description="PZ dedicated server with FIFO console and graceful save-on-SIGTERM"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        coreutils \
        procps \
        locales \
        ca-certificates \
        gawk \
        sqlite3 \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

ARG PZ_UID=1000
ARG PZ_GID=1000

ENV PZ_INSTALL_DIR=/opt/pzserver \
    PZ_DATA_DIR=/zomboid \
    HOME=/zomboid

RUN mkdir -p /opt/pzserver /zomboid \
    && chown -R ${PZ_UID}:${PZ_GID} /opt/pzserver /zomboid

COPY --chmod=0755 entrypoint.sh     /usr/local/bin/entrypoint.sh
COPY --chmod=0755 pz-console        /usr/local/bin/pz-console
COPY --chmod=0644 patch-ini.awk     /usr/local/bin/patch-ini.awk
COPY --chmod=0644 patch-sandbox.awk /usr/local/bin/patch-sandbox.awk

USER ${PZ_UID}:${PZ_GID}
WORKDIR /opt/pzserver

EXPOSE 16261/udp 16262/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
