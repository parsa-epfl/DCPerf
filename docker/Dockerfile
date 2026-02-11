# FROM akrishnaams/ubuntu2204:latest
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install packages and dependencies
RUN apt-get update -qq && \
    apt-get install -y -qq wget tmux python3-pip git dmidecode kmod policycoreutils curl \
                          sudo lshw iputils-ping bc iperf3 vim && \
    pip3 install --no-cache-dir click pyyaml tabulate pandas

RUN git clone https://github.com/parsa-epfl/DCPerf.git
WORKDIR /DCPerf
RUN mkdir -p ./LOGs/

# Install health_check
RUN ./benchpress_cli.py install health_check >/dev/null 2>&1 && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean

RUN chmod +x ./health_check.sh
CMD ["./health_check.sh"]

