FROM lscr.io/linuxserver/sabnzbd:latest

# Install AWS CLI for S3 uploads and curl for API callbacks
RUN apk add --no-cache \
    aws-cli \
    curl \
    bash \
    coreutils

# Copy our scripts
COPY scripts/ /opt/openmedia/scripts/
RUN chmod +x /opt/openmedia/scripts/*.sh

# Copy SABnzbd config template
COPY templates/sabnzbd.ini.template /opt/openmedia/templates/sabnzbd.ini.template

# Custom entrypoint wraps the linuxserver init
COPY scripts/entrypoint.sh /opt/openmedia/entrypoint.sh
RUN chmod +x /opt/openmedia/entrypoint.sh

# Post-processing script goes where SABnzbd expects it
RUN mkdir -p /config/scripts
COPY scripts/post-process.sh /config/scripts/post-process.sh
RUN chmod +x /config/scripts/post-process.sh

ENTRYPOINT ["/opt/openmedia/entrypoint.sh"]
