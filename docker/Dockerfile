FROM akrishnaams/ubuntu2204:oh-my-bash
# FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies quietly
RUN apt-get update -qq && \
    apt-get install -y -qq wget tmux python3-pip git dmidecode kmod policycoreutils \
                          sudo lshw iputils-ping bc iperf3 

# Install Python dependencies
RUN pip3 install -q click pyyaml tabulate pandas

# Clone DCPerf
RUN git clone https://github.com/parsa-epfl/DCPerf.git

# Create logs Directory
WORKDIR /DCPerf
RUN mkdir -p ./LOGs/

# Run the health-checks
RUN ./benchpress_cli.py install health_check >/dev/null 2>&1
RUN rm -rf /var/lib/apt/lists/*

 
RUN chmod +x ./health_check.sh
CMD ["./health_check.sh"]

