#!/usr/bin/env python3
"""
Generate a .env file for the Django workload benchmark.

CPU layout (mirrors the existing convention):
  - Server/DB cores: packed first, one contiguous block per instance
  - Client cores:    follow immediately after all server blocks

  Example: 3 instances × 16 cores/instance
    SERVER_NODE_CPUS_INST1 = 0-15
    SERVER_NODE_CPUS_INST2 = 16-31
    SERVER_NODE_CPUS_INST3 = 32-47
    CLIENT_NODE_CPUS_INST1 = 48-63
    CLIENT_NODE_CPUS_INST2 = 64-79
    CLIENT_NODE_CPUS_INST3 = 80-95

Usage:
    python3 generate_env.py <cores_per_instance> <num_instances> [output_file]

Arguments:
    cores_per_instance  CPU cores allocated to each instance (server + client each)
    num_instances       Number of benchmark instances
    output_file  Output path (default: .env.single-core for 1 core,
                              .env.<n>-core for n>1 core and 1 instance,
                              .env.<cores_label>-<instances>-inst for multiple instances)

Examples:
    python3 generate_env.py 1 1                  -> .env.single-core
    python3 generate_env.py 16 1                 -> .env.16-core
    python3 generate_env.py 16 3                 -> .env.16-core-3-inst
    python3 generate_env.py 16 3 --arch x86_64   -> .env.16-core-3-inst  (ARCH=x86_64)
    python3 generate_env.py 32 4 my.env
"""

import sys
import argparse


def generate_env(cores_per_inst: int, n: int, arch: str = "arm64") -> str:
    total_cores = 2 * n * cores_per_inst

    lines = [
        f"# Django Workload {cores_per_inst}-Core {n}-Instance Configuration"
        f" ({total_cores} cores total)",
        "",
        "# Architecture Configuration",
        f"ARCH={arch}",
        "",
        "# CPU affinity configuration - Per Instance",
        "# DB and Server share cores, Client uses separate cores",
    ]

    # Server/DB CPU ranges (first half of the total core space)
    for i in range(1, n + 1):
        start = (i - 1) * cores_per_inst
        end = start + cores_per_inst - 1
        lines.append(f'SERVER_NODE_CPUS_INST{i}="{start}-{end}"')

    # Client CPU ranges (second half of the total core space)
    for i in range(1, n + 1):
        start = n * cores_per_inst + (i - 1) * cores_per_inst
        end = start + cores_per_inst - 1
        lines.append(f'CLIENT_NODE_CPUS_INST{i}="{start}-{end}"')

    lines += [
        "",
        "# Django Server Configuration",
        "NUM_DJANGO_THREADS=",
        "",
        "# Siege Client Configuration",
        "NUM_CLIENT_THREADS=",
        "ITERATIONS=7",
        "REPS=",
        "",
    ]

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Generate a .env file for n Django workload instances."
    )
    parser.add_argument(
        "cores_per_instance",
        type=int,
        help="CPU cores dedicated to each instance (server and client each get this many)",
    )
    parser.add_argument(
        "num_instances",
        type=int,
        help="Number of benchmark instances",
    )
    parser.add_argument(
        "output_file",
        nargs="?",
        help="Output file path (default: .env.<cores>-core-<n>-inst)",
    )
    parser.add_argument(
        "--arch",
        default="arm64",
        help="Target architecture written into ARCH= (default: arm64, e.g. arm64, x86_64)",
    )
    args = parser.parse_args()

    if args.cores_per_instance < 1:
        print("Error: cores_per_instance must be >= 1", file=sys.stderr)
        sys.exit(1)
    if args.num_instances < 1:
        print("Error: num_instances must be >= 1", file=sys.stderr)
        sys.exit(1)

    cores_label = "single-core" if args.cores_per_instance == 1 else f"{args.cores_per_instance}-core"
    if args.num_instances == 1:
        default_name = f".env.{cores_label}"
    else:
        default_name = f".env.{cores_label}-{args.num_instances}-inst"
    output_path = args.output_file or default_name
    content = generate_env(args.cores_per_instance, args.num_instances, args.arch)

    with open(output_path, "w") as fh:
        fh.write(content)

    total = 2 * args.num_instances * args.cores_per_instance
    print(
        f"Generated {output_path} "
        f"({args.num_instances} instance(s) × {args.cores_per_instance} cores, "
        f"{total} cores total, arch={args.arch})."
    )


if __name__ == "__main__":
    main()
