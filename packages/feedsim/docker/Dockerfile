# Start from the dcperf base image
FROM ghcr.io/parsa-epfl/dcperf/dcperf-base-x86_64:latest
# FROM ghcr.io/parsa-epfl/dcperf/dcperf-base-arm64:latest

# Update package lists
RUN apt-get update
RUN apt-get install -y curl vim

# Set working directory
WORKDIR /DCPerf
RUN git checkout feedsim

# Run the install command for feedsim_autoscale
RUN ./benchpress_cli.py install feedsim_autoscale
RUN rm -rf /var/lib/apt/lists/*

CMD ["./health_check.sh"]
