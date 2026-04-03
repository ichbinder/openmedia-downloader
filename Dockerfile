FROM lscr.io/linuxserver/sabnzbd:latest

# Install rclone for fast S3 uploads (Go-based, ~9x faster than Python aws-cli)
# and curl for API callbacks
RUN apk add --no-cache \
    rclone \
    curl \
    bash \
    coreutils \
    xxd

# Custom init script: generates sabnzbd.ini before SABnzbd starts
# Runs during s6 Stage 2 (cont-init.d), before services start
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
