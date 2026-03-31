#!/bin/bash
# Healthcheck: verify SABnzbd API is responsive
curl -sf "http://127.0.0.1:8080/sabnzbd/api?mode=version&output=json" > /dev/null 2>&1
