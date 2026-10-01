FROM atdr.meo.ws/archiveteam/warrior-dockerfile:latest@sha256:19337aa9157e04f6cdb8f7c6f8c98e27d14efb0d9525334995fbdb036b95e1ca

# Project installers apt-get these via sudo, which no_new_privs blocks; they skip the install when dpkg already has them.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ghostscript \
 && rm -rf /var/lib/apt/lists/*
USER 1000
