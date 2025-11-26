#!/bin/bash
set -e

# Build base image
cd ./docker
docker build --no-cache -t ghcr.io/parsa-epfl/dcperf/dcperf-base:latest .

# Build QEMU aarch64 image
cd ../docker
docker build --no-cache -f Dockerfile.qemu.aarch64 -t ghcr.io/parsa-epfl/dcperf/dcperf-qemu-aarch64:latest .

# Build feedsim image
cd ../packages/feedsim/docker
docker build --no-cache -t ghcr.io/parsa-epfl/dcperf/dcperf-feedsim:latest .

