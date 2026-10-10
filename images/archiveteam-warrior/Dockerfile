FROM atdr.meo.ws/archiveteam/warrior-dockerfile:latest@sha256:9eaa5a345e7f1eb9a13ce407eb7943463bfa17ad14c0f0174469af8f4c5447c2

# Project installers apt-get these via sudo, which no_new_privs blocks; they skip the install when dpkg already has them.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ghostscript \
 && rm -rf /var/lib/apt/lists/*
USER 1000
