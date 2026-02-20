# Django Workload - Docker Compose Setup

This directory contains Docker configuration for running the Django workload benchmark using Docker Compose with separate containers for the database and client/server.

**Note:** This setup uses the official `benchpress_cli.py` commands as documented in the main Django workload README.

## Architecture Support

This setup automatically detects your system architecture (x86_64 or arm64) and:
- Uses the appropriate base images (`dcperf-base-x86_64` or `dcperf-base-arm64`)
- Runs the correct benchpress job (`django_workload_default` for x86_64, `django_workload_arm` for arm64)
- Tags images with the architecture suffix (`*-x86_64:latest` or `*-arm64:latest`)

## Container Architecture

The setup consists of three separate containers with CPU affinity:

1. **cassandra-db**: Cassandra database server (pinned to CPU Core 0)
   - x86_64: `./benchpress_cli.py run django_workload_default -r db`
   - arm64: `./benchpress_cli.py run django_workload_arm -r db`
2. **django-server**: Django + uWSGI server (pinned to CPU Core 0)
   - x86_64: `./benchpress_cli.py run django_workload_default -r server -i '{"db_addr": "<db-server-ip>"}'`
   - arm64: `./benchpress_cli.py run django_workload_arm -r server -i '{"db_addr": "<db-server-ip>"}'`
3. **siege-client**: Siege load testing client (pinned to CPU Core 1)
   - x86_64: `./benchpress_cli.py run django_workload_default -r client -i '{"server_addr": "<django-server-ip>"}'`
   - arm64: `./benchpress_cli.py run django_workload_arm -r client -i '{"server_addr": "<django-server-ip>"}'`

**CPU Affinity:** Cassandra and Django server share Core 0, while the Siege client runs on Core 1 to isolate load generation from the server processes.

## Quick Start

### 0. Check Architecture (Optional)

```bash
cd /DCPerf/packages/django_workload/docker
make arch
# Output: Detected architecture: x86_64 (or arm64)
```

### 1. Build the Images

```bash
cd /DCPerf/packages/django_workload/docker

# Auto-detects architecture and builds appropriate images
docker-compose build

# Or explicitly set architecture
ARCH=arm64 docker-compose build
```

### 2. Run the Benchmark

```bash
# Start both containers
docker-compose up

# Or run in detached mode
docker-compose up -d

# View logs
docker-compose logs -f
```

### 3. Stop and Clean Up

```bash
# Stop containers
docker-compose down

# Stop and remove volumes (data will be lost)
docker-compose down -v
```

## Configuration

### Using Environment Variables

Create a `.env` file from the example:

```bash
cp .env.example .env
```

Edit `.env` to customize the configuration:

```bash
# Example: Run with custom iterations and fixed reps
ITERATIONS=10
REPS=50000
```

### Key Configuration Options

All configuration is passed as JSON input to `benchpress_cli.py` commands.

#### Architecture
- `ARCH`: Target architecture (auto-detected: `x86_64` or `arm64`)
  - Determines which base image and benchpress job to use
  - Can be overridden: `ARCH=arm64 docker-compose build`

#### Cassandra (Database)
- `BIND_IP`: IP address for Cassandra to bind (auto-detected via `hostname -i` if empty)
  - Maps to: `-i '{"bind_ip": "<ip>"}'` in benchpress_cli.py

#### Django Server
- `DB_ADDR`: Cassandra database address (default: "cassandra-db")
  - Maps to: `-i '{"db_addr": "<addr>"}'` in benchpress_cli.py

#### Siege Client
- `SERVER_ADDR`: Django server address (default: "django-server")
  - Maps to: `-i '{"server_addr": "<addr>"}'` in benchpress_cli.py
- `ITERATIONS`: Number of benchmark iterations (optional, default: 7)
  - Maps to: `-i '{"iterations": <n>}'` in benchpress_cli.py
- `REPS`: Fixed number of requests per iteration (optional)
  - Maps to: `-i '{"reps": <n>}'` in benchpress_cli.py
  - Use this to avoid Siege hanging issues (see main README.md troubleshooting)

**Note:** Other parameters like number of workers, ICacheBuster settings, etc. are automatically configured by benchpress_cli.py based on system resources.

### Using Command-Line Overrides

```bash
# Override specific values
docker-compose up \
  -e ITERATIONS=10 \
  -e REPS=50000

# Run with custom database binding
BIND_IP=192.168.1.100 docker-compose up
```

## Results and Logs

Results and logs are mounted to the host system:

```
./results/        # Benchmark results
./logs/cassandra/ # Cassandra logs
./logs/django/    # Django and Siege logs
```

Create these directories before running if they don't exist:

```bash
mkdir -p results logs/cassandra logs/django
```

## Resource Allocation

The default docker-compose.yml includes resource limits. Adjust these based on your system:

```yaml
deploy:
  resources:
    limits:
      cpus: '8.0'
      memory: 16G
```

## Advanced Usage

### Architecture-Specific Builds

The setup automatically detects your architecture, but you can override it:

```bash
# Build for ARM64 explicitly
ARCH=arm64 docker-compose build

# Build for x86_64 explicitly
ARCH=x86_64 docker-compose build

# Run with specific architecture
ARCH=arm64 docker-compose up

# Check what will be used
make arch
```

### Run Only Database

```bash
docker-compose up cassandra-db
```

### Run Server with External Database

Modify `DB_ADDR` to point to an external Cassandra instance:

```bash
docker-compose run \
  -e DB_ADDR=192.168.1.100 \
  django-server
```

### Run Client with External Server

Modify `SERVER_ADDR` to point to an external Django instance:

```bash
docker-compose run \
  -e SERVER_ADDR=192.168.1.100 \
  siege-client
```

### Modify CPU Affinity

Edit `docker-compose.yml` to change CPU pinning:

```yaml
# Pin to different cores
cassandra-db:
  cpuset: "0"      # Core 0

django-server:
  cpuset: "0"      # Core 0 (shares with Cassandra)

siege-client:
  cpuset: "1"      # Core 1 (isolated)
```

Or allow multiple cores:

```yaml
siege-client:
  cpuset: "2-3"    # Cores 2 and 3
```

### Use Fixed Repetitions (Avoid Siege Hanging)

If Siege hangs on your platform, use fixed repetitions instead of duration:

```bash
# Run each iteration for 5000 requests per CPU core
docker-compose up -e REPS=5000 -e DURATION=""
```

### Build Specific Targets

```bash
# Build only the database image
docker-compose build cassandra-db

# Build only the server image
docker-compose build django-server

# Build only the client image
docker-compose build siege-client
```

## Troubleshooting


### Django Server Cannot Connect to Cassandra

1. Ensure Cassandra is healthy:
   ```bash
   docker-compose ps
   ```

2. Check network connectivity:
   ```bash
   docker-compose exec django-clientserver nc -zv cassandra-db 9042
   ```

### Siege Hanging

Use fixed repetitions instead of duration:
```bash
docker-compose up -e REPS=5000
```


### Check Resource Usage

```bash
docker stats
```

### Health Checks

```bash
# Check health status
docker-compose ps

# Manual health check
docker-compose exec cassandra-db nc -z localhost 9042
docker-compose exec django-server nc -z localhost 8000
```

## Cleaning Up

```bash
# Stop and remove containers
docker-compose down

# Also remove volumes (Cassandra data)
docker-compose down -v

# Remove images (architecture-aware)
make clean-all

# Or manually (replace x86_64 with arm64 if on ARM)
docker rmi docker.io/akrishnaams/dcperf-djangobench-cassandra-x86_64:latest \
        docker.io/akrishnaams/dcperf-djangobench-server-x86_64:latest \
        docker.io/akrishnaams/dcperf-djangobench-client-x86_64:latest

# Full cleanup including build cache
docker system prune -a
```

## References

- [Django Workload Documentation](../README.md)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Cassandra Documentation](https://cassandra.apache.org/doc/)
