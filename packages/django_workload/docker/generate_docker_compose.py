#!/usr/bin/env python3
"""
Generate a docker-compose file for n Django workload instances.

Usage:
    python3 generate_docker_compose.py <n> [output_file] [--arch ARCH]

Arguments:
    n            Number of instances to generate (required)
    output_file  Output file path (optional, defaults to docker-compose-<n>-inst.yml)
    --arch       Target architecture (default: arm64, e.g. arm64, x86_64)

Examples:
    python3 generate_docker_compose.py 3
    python3 generate_docker_compose.py 5 my-compose.yml
    python3 generate_docker_compose.py 3 --arch x86_64
"""

import sys
import argparse


def generate_instance(i: int, arch: str = "arm64") -> str:
    """Generate service definitions for instance i (1-indexed)."""
    # Port assignments per instance (matching the existing 3-instance convention):
    #   cassandra host port: 9041 + i  -> container 9042
    #   cassandra p2p port:  6999 + i  -> container 7000
    #   cassandra jmx port:  7198 + i  -> container 7199
    #   django server port:  8000 + i  -> container 8000
    cassandra_port = 9041 + i
    p2p_port = 6999 + i
    jmx_port = 7198 + i
    server_port = 8000 + i

    return f"""\
  cassandra-db-inst{i}:
    build:
      context: ../../..
      dockerfile: packages/django_workload/docker/Dockerfile.qflex
      target: db
      args:
        ARCH: ${{ARCH:-{arch}}}
    image: docker.io/akrishnaams/dcperf-djangobench-cassandra-${{ARCH:-{arch}}}:latest
    pid: "host"
    container_name: django-cassandra-db-inst{i}
    hostname: cassandra-db-inst{i}
    networks:
      - django-network-inst{i}
    environment:
      BIND_IP: ""
    ports:
      - "{cassandra_port}:9042"
      - "{p2p_port}:7000"
      - "{jmx_port}:7199"
    volumes:
      - ./logs/cassandra-inst{i}:/DCPerf/benchmarks/django_workload/cassandra_logs
    healthcheck:
      test: ["CMD-SHELL", "lsof -i -P -n | grep 9042 || exit 1"]
      interval: 30s
      timeout: 20s
      retries: 10
      start_period: 120s
    cpuset: ${{SERVER_NODE_CPUS_INST{i}}}
    privileged: true

  django-server-inst{i}:
    build:
      context: ../../..
      dockerfile: packages/django_workload/docker/Dockerfile.qflex
      target: server
      args:
        ARCH: ${{ARCH:-{arch}}}
    image: docker.io/akrishnaams/dcperf-djangobench-server-${{ARCH:-{arch}}}:latest
    pid: "host"
    container_name: django-server-inst{i}
    hostname: django-server-inst{i}
    networks:
      - django-network-inst{i}
    depends_on:
      cassandra-db-inst{i}:
        condition: service_healthy
    environment:
      DB_ADDR: "cassandra-db-inst{i}"
      NUM_DJANGO_THREADS: ${{NUM_DJANGO_THREADS:-}}
    ports:
      - "{server_port}:8000"
    volumes:
      - ./logs/django-inst{i}:/DCPerf/benchmarks/django_workload/logs
    healthcheck:
      test: ["CMD", "curl", "-f", "http://[::1]:8000/feed_timeline"]
      interval: 30s
      timeout: 20s
      retries: 5
      start_period: 60s
    cpuset: ${{SERVER_NODE_CPUS_INST{i}}}
    privileged: true

  siege-client-inst{i}:
    build:
      context: ../../..
      dockerfile: packages/django_workload/docker/Dockerfile.qflex
      target: client
      args:
        ARCH: ${{ARCH:-{arch}}}
    image: docker.io/akrishnaams/dcperf-djangobench-client-${{ARCH:-{arch}}}:latest
    pid: "host"
    container_name: django-siege-client-inst{i}
    hostname: siege-client-inst{i}
    networks:
      - django-network-inst{i}
    depends_on:
      django-server-inst{i}:
        condition: service_healthy
    environment:
      SERVER_ADDR: "django-server-inst{i}"
      ITERATIONS: ${{ITERATIONS:-}}
      REPS: ${{REPS:-}}
      NUM_CLIENT_THREADS: ${{NUM_CLIENT_THREADS:-}}
    volumes:
      - ./results/inst{i}:/DCPerf/benchmarks/django_workload/results
    cpuset: ${{CLIENT_NODE_CPUS_INST{i}}}
    privileged: true
"""


def generate_network(i: int) -> str:
    """Generate network definition for instance i (1-indexed).

    Subnet assignment: 172.(20+i).0.0/16
      instance 1 -> 172.21.0.0/16
      instance 2 -> 172.22.0.0/16
      ...
    """
    subnet_second_octet = 20 + i
    return f"""\
  django-network-inst{i}:
    driver: bridge
    ipam:
      config:
        - subnet: 172.{subnet_second_octet}.0.0/16
"""


def generate_compose(n: int, arch: str = "arm64") -> str:
    """Return the full docker-compose YAML string for n instances."""
    sections = ["services:\n"]
    for i in range(1, n + 1):
        sections.append(generate_instance(i, arch))

    sections.append("networks:\n")
    for i in range(1, n + 1):
        sections.append(generate_network(i))

    return "\n".join(sections)


def main():
    parser = argparse.ArgumentParser(
        description="Generate a docker-compose file for n Django workload instances."
    )
    parser.add_argument(
        "n",
        type=int,
        help="Number of instances to generate",
    )
    parser.add_argument(
        "output_file",
        nargs="?",
        help="Output file path (default: docker-compose-<n>-inst.yml)",
    )
    parser.add_argument(
        "--arch",
        default="arm64",
        help="Target architecture (default: arm64, e.g. arm64, x86_64)",
    )
    args = parser.parse_args()

    if args.n < 1:
        print("Error: n must be >= 1", file=sys.stderr)
        sys.exit(1)

    # Warn if subnet range would overflow (max n=235 keeps second octet <= 255)
    if args.n > 235:
        print(
            f"Warning: n={args.n} exceeds the available /16 subnet range "
            "(172.21.0.0 – 172.255.0.0). Subnets will wrap.",
            file=sys.stderr,
        )

    output_path = args.output_file or f"docker-compose-{args.n}-inst.yml"
    content = generate_compose(args.n, args.arch)

    with open(output_path, "w") as fh:
        fh.write(content)

    print(f"Generated {output_path} with {args.n} instance(s) for arch={args.arch}.")


if __name__ == "__main__":
    main()
