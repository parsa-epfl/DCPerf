# Start from the dcperf base image
FROM ghcr.io/parsa-epfl/dcperf/dcperf-base:latest

# Update package lists
RUN apt-get update

# Set working directory
WORKDIR /DCPerf

# Run the install command for feedsim_autoscale
RUN ./benchpress_cli.py install feedsim_autoscale
RUN rm -rf /var/lib/apt/lists/*

CMD ["./health_check.sh"]
