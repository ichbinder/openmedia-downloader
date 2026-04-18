FROM lscr.io/linuxserver/sabnzbd:latest

# ── Build 7-Zip with RAR codec from source ─────────────────────
# Alpine's 7zip package ships without RAR support (license reasons).
# We compile the official 7-Zip 25.01 source which includes the
# unRAR decompression code. This gives us multi-threaded RAR
# extraction via 7zz — unlike unrar which is single-threaded.
RUN apk add --no-cache --virtual .build-deps build-base wget \
 && wget -qO /tmp/7z-src.tar.xz 'https://7-zip.org/a/7z2501-src.tar.xz' \
 && mkdir -p /tmp/7z-src && cd /tmp/7z-src && tar xf /tmp/7z-src.tar.xz \
 && cd /tmp/7z-src/CPP/7zip/Bundles/Alone2 \
 && make -j$(nproc) -f makefile.gcc \
 && cp _o/7zz /usr/local/bin/7zz-rar \
 && chmod +x /usr/local/bin/7zz-rar \
 && cd / && rm -rf /tmp/7z-src /tmp/7z-src.tar.xz \
 && apk del .build-deps

# Install rclone for fast S3 uploads (Go-based, ~9x faster than Python aws-cli)
# and curl for API callbacks
RUN apk add --no-cache \
    rclone \
    curl \
    bash \
    coreutils \
    xxd \
    ffmpeg \
    jq

# ── Replace unrar with 7zz-rar wrapper for multi-threaded extraction ──
# Move real unrar to .real as fallback, install wrapper as /usr/bin/unrar
COPY scripts/unrar-wrapper.sh /usr/bin/unrar-wrapper
RUN mv /usr/bin/unrar /usr/bin/unrar.real \
 && chmod +x /usr/bin/unrar-wrapper \
 && ln -sf /usr/bin/unrar-wrapper /usr/bin/unrar

# Bootstrap script: fetches config from API using 3 ENV vars
# Runs FIRST during s6 Stage 2 (cont-init.d), before config generation
COPY scripts/00-fetch-config.sh /etc/cont-init.d/00-fetch-config
RUN chmod +x /etc/cont-init.d/00-fetch-config

# Custom init script: generates sabnzbd.ini before SABnzbd starts
# Runs during s6 Stage 2 (cont-init.d), after bootstrap
COPY scripts/10-generate-config.sh /etc/cont-init.d/10-generate-config
RUN chmod +x /etc/cont-init.d/10-generate-config

# Post-processing script: called by SABnzbd after download completes
RUN mkdir -p /config/scripts
COPY scripts/post-process.sh /config/scripts/post-process.sh
RUN chmod +x /config/scripts/post-process.sh

# SABnzbd config template
COPY templates/sabnzbd.ini.template /opt/openmedia/templates/sabnzbd.ini.template

# NZB submission + monitoring script (runs as CMD after SABnzbd is up)
COPY scripts/submit-and-monitor.sh /opt/openmedia/submit-and-monitor.sh
RUN chmod +x /opt/openmedia/submit-and-monitor.sh
