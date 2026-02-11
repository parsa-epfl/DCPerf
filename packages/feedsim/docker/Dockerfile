# Build standard: docker build --target standard -t dcperf-feedsim:standard .
# Build lean: docker build --target lean -t dcperf-feedsim:lean .
# Default (lean): docker build -t dcperf-feedsim:lean .



# ==========================================
# Standard - Full-featured image with dcperf-base
# ==========================================
FROM ghcr.io/parsa-epfl/dcperf/dcperf-base-x86_64:latest AS standard
# FROM ghcr.io/parsa-epfl/dcperf/dcperf-base-arm64:latest AS builder

WORKDIR /DCPerf
RUN git checkout feedsim

# Install feedsim_autoscale
RUN apt-get update -qq && \
    ./benchpress_cli.py install feedsim_autoscale >/dev/null 2>&1

WORKDIR /DCPerf
CMD ["./health_check.sh"]





# ==========================================
# Lean - Minimal runtime image
# ==========================================
FROM ghcr.io/parsa-epfl/dcperf/dcperf-base-x86_64:latest AS lean
# FROM ghcr.io/parsa-epfl/dcperf/dcperf-base-arm64:latest AS builder

WORKDIR /DCPerf
RUN git checkout feedsim

# Install feedsim_autoscale and remove build dependencies to minimize image size
RUN apt-get update -qq && \
    ./benchpress_cli.py install feedsim_autoscale >/dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean && \
    mv ./benchmarks/feedsim/src/build/workloads/ranking/DriverNodeRank . && \
    mv ./benchmarks/feedsim/src/build/workloads/ranking/LeafNodeRank . && \
    mv ./benchmarks/feedsim/src/build/workloads/ranking/ParentNodeRank . && \
    mv ./benchmarks/feedsim/src/scripts/search_qps.sh . && \
    rm -rf ./benchmarks/feedsim/src && \
    rm -rf ./benchmarks/feedsim/third_party && \
    mkdir -p ./benchmarks/feedsim/src/build/workloads/ranking/ && \
    mkdir -p ./benchmarks/feedsim/src/scripts && \
    mv DriverNodeRank ./benchmarks/feedsim/src/build/workloads/ranking/ && \
    mv LeafNodeRank ./benchmarks/feedsim/src/build/workloads/ranking/ && \
    mv ParentNodeRank ./benchmarks/feedsim/src/build/workloads/ranking/ && \
    mv search_qps.sh ./benchmarks/feedsim/src/scripts/  && \
    rm -rf ./benchmarks/health_check 

WORKDIR /DCPerf
CMD ["bash"]
