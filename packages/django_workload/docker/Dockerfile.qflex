# Django Workload Docker Image
# Architecture-aware build - automatically detects x86_64 or arm64
# Build examples:
#   docker-compose build  (auto-detects architecture)
#   docker build --target db --build-arg ARCH=x86_64 -t docker.io/akrishnaams/dcperf-djangobench-cassandra-x86_64:latest .
#   docker build --target db --build-arg ARCH=arm64 -t docker.io/akrishnaams/dcperf-djangobench-cassandra-arm64:latest .
# Use with docker-compose for multi-container setup

# Detect architecture
ARG TARGETARCH
ARG ARCH=${TARGETARCH}

# Select base image based on architecture
FROM docker.io/akrishnaams/dcperf-base-${ARCH}:latest AS base

WORKDIR /DCPerf

RUN git checkout ayan-expt

# Set benchpress job name based on architecture
ARG ARCH
RUN echo "Building for architecture: ${ARCH}"

# Install appropriate django workload
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends python3-pip curl lsof netcat-openbsd && \
    if [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "aarch64" ]; then \
        ./benchpress_cli.py install django_workload_arm >/dev/null 2>&1; \
    else \
        ./benchpress_cli.py install django_workload_default >/dev/null 2>&1; \
    fi



# ==========================================
# DB - Cassandra Database Server
# ==========================================
FROM base AS db

ARG ARCH
WORKDIR /DCPerf

# Environment variables for Cassandra configuration
ENV BIND_IP=""
ENV ARCH=${ARCH}

# Expose Cassandra ports
# 9042: CQL native transport port
# 7000: Inter-node cluster communication
# 7001: TLS inter-node cluster communication
# 7199: JMX monitoring port
EXPOSE 9042 7000 7001 7199

# Health check to ensure Cassandra is ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD lsof -i -P -n | grep 9042 || exit 1

# Use benchpress_cli.py as documented in README
CMD ["sh", "-c", "BENCH_JOB=$([ \"${ARCH}\" = \"arm64\" ] || [ \"${ARCH}\" = \"aarch64\" ] && echo 'django_workload_arm' || echo 'django_workload_default'); \
    if [ -n \"${BIND_IP}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r db -i '{\"bind_ip\": \"'${BIND_IP}'\"}'; \
    else \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r db; \
    fi"]



# ==========================================
# Server - Django Server Only
# ==========================================
FROM base AS server

ARG ARCH
WORKDIR /DCPerf

# Environment variables for Django server configuration
ENV DB_ADDR="cassandra-db"
ENV ARCH=${ARCH}

# Expose Django/uWSGI port
EXPOSE 8000

# Health check to ensure Django server is ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
    CMD curl -f http://localhost:8000/ || exit 1

# Use benchpress_cli.py as documented in README
CMD ["sh", "-c", "BENCH_JOB=$([ \"${ARCH}\" = \"arm64\" ] || [ \"${ARCH}\" = \"aarch64\" ] && echo 'django_workload_arm' || echo 'django_workload_default'); \
    ./benchpress_cli.py run --print-realtime $BENCH_JOB -r server -i '{\"db_addr\": \"'${DB_ADDR}'\"}'"]



# ==========================================
# Client - Siege Client Only
# ==========================================
FROM base AS client

ARG ARCH
WORKDIR /DCPerf

# Environment variables for Siege client configuration
ENV SERVER_ADDR="django-server"
ENV REPS=""
ENV ITERATIONS=""
ENV ARCH=${ARCH}

# Use benchpress_cli.py as documented in README
CMD ["sh", "-c", "BENCH_JOB=$([ \"${ARCH}\" = \"arm64\" ] || [ \"${ARCH}\" = \"aarch64\" ] && echo 'django_workload_arm' || echo 'django_workload_default'); \
    if [ -n \"${REPS}\" ] && [ -n \"${ITERATIONS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r client -i '{\"server_addr\": \"'${SERVER_ADDR}'\", \"reps\": '${REPS}', \"iterations\": '${ITERATIONS}'}'; \
    elif [ -n \"${REPS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r client -i '{\"server_addr\": \"'${SERVER_ADDR}'\", \"reps\": '${REPS}'}'; \
    elif [ -n \"${ITERATIONS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r client -i '{\"server_addr\": \"'${SERVER_ADDR}'\", \"iterations\": '${ITERATIONS}'}'; \
    else \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r client -i '{\"server_addr\": \"'${SERVER_ADDR}'\"}'; \
    fi"]



# ==========================================
# ClientServer - Django Server + Siege Client
# ==========================================
FROM base AS clientserver

ARG ARCH
WORKDIR /DCPerf

# Environment variables for Django server and client configuration
ENV DB_ADDR="django-db"
ENV REPS=""
ENV ITERATIONS=""
ENV ARCH=${ARCH}

# Expose Django/uWSGI port
EXPOSE 8000

# Health check to ensure Django server is ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
    CMD curl -f http://localhost:8000/ || exit 1

# Use benchpress_cli.py as documented in README
CMD ["sh", "-c", "BENCH_JOB=$([ \"${ARCH}\" = \"arm64\" ] || [ \"${ARCH}\" = \"aarch64\" ] && echo 'django_workload_arm' || echo 'django_workload_default'); \
    if [ -n \"${REPS}\" ] && [ -n \"${ITERATIONS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r clientserver -i '{\"db_addr\": \"'${DB_ADDR}'\", \"reps\": '${REPS}', \"iterations\": '${ITERATIONS}'}'; \
    elif [ -n \"${REPS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r clientserver -i '{\"db_addr\": \"'${DB_ADDR}'\", \"reps\": '${REPS}'}'; \
    elif [ -n \"${ITERATIONS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r clientserver -i '{\"db_addr\": \"'${DB_ADDR}'\", \"iterations\": '${ITERATIONS}'}'; \
    else \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r clientserver -i '{\"db_addr\": \"'${DB_ADDR}'\"}'; \
    fi"]



# ==========================================
# Standalone - All-in-one (DB + Server + Client)
# ==========================================
FROM base AS standalone

ARG ARCH
WORKDIR /DCPerf

# Environment variables for standalone configuration
ENV REPS=""
ENV ITERATIONS=""
ENV ARCH=${ARCH}

# Expose both Cassandra and Django ports
EXPOSE 9042 8000

# Health check to ensure both services are ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD lsof -i -P -n | grep 9042 && curl -f http://localhost:8000/ || exit 1

# Use benchpress_cli.py as documented in README
CMD ["sh", "-c", "BENCH_JOB=$([ \"${ARCH}\" = \"arm64\" ] || [ \"${ARCH}\" = \"aarch64\" ] && echo 'django_workload_arm' || echo 'django_workload_default'); \
    if [ -n \"${REPS}\" ] && [ -n \"${ITERATIONS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r standalone -i '{\"reps\": '${REPS}', \"iterations\": '${ITERATIONS}'}'; \
    elif [ -n \"${REPS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r standalone -i '{\"reps\": '${REPS}'}'; \
    elif [ -n \"${ITERATIONS}\" ]; then \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r standalone -i '{\"iterations\": '${ITERATIONS}'}'; \
    else \
        ./benchpress_cli.py run --print-realtime $BENCH_JOB -r standalone; \
    fi"]
