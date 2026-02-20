# Makefile for Django Workload Docker Setup (3-Container Architecture)
.PHONY: help build up down logs clean start stop restart shell-db shell-server shell-client status

# Default target
.DEFAULT_GOAL := help

# Variables
# Support both docker-compose (V1) and docker compose (V2)
COMPOSE := $(shell command -v docker-compose 2>/dev/null)
ifndef COMPOSE
	COMPOSE := docker compose
endif
DOCKER := docker

# Auto-detect architecture if not set
ARCH ?= $(shell uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/;s/arm64/arm64/')
export ARCH

help: ## Show this help message
	@echo "Django Workload Docker Commands (3-Container Setup)"
	@echo "Architecture: $(ARCH)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

build: ## Build all Docker images (db, server, client)
	$(COMPOSE) build

build-db: ## Build only the Cassandra database image
	$(COMPOSE) build cassandra-db

build-server: ## Build only the Django server image
	$(COMPOSE) build django-server

build-client: ## Build only the Siege client image
	$(COMPOSE) build siege-client

up: ## Start all containers in detached mode
	$(COMPOSE) up -d

start: up ## Alias for 'up'

down: ## Stop and remove all containers
	$(COMPOSE) down

stop: down ## Alias for 'down'

restart: ## Restart all containers
	$(COMPOSE) restart

logs: ## Show logs from all containers (follow mode)
	$(COMPOSE) logs -f

logs-db: ## Show logs from Cassandra database container
	$(COMPOSE) logs -f cassandra-db

logs-server: ## Show logs from Django server container
	$(COMPOSE) logs -f django-server

logs-client: ## Show logs from Siege client container
	$(COMPOSE) logs -f siege-client

status: ## Show status of all containers
	$(COMPOSE) ps

ps: status ## Alias for 'status'

shell-db: ## Open shell in Cassandra database container
	$(COMPOSE) exec cassandra-db /bin/bash

shell-server: ## Open shell in Django server container
	$(COMPOSE) exec django-server /bin/bash

shell-client: ## Open shell in Siege client container
	$(COMPOSE) exec siege-client /bin/bash

health: ## Check health status of all services
	@echo "=== Container Status ==="
	@$(COMPOSE) ps
	@echo ""
	@echo "=== Health Checks ==="
	@$(DOCKER) inspect --format='{{.Name}}: {{.State.Health.Status}}' $$($(COMPOSE) ps -q) 2>/dev/null || echo "No health checks configured"

run: ## Run benchmark (start containers and show logs)
	$(COMPOSE) up

run-detached: up logs ## Start containers in background and show logs

clean: ## Stop containers and remove volumes
	$(COMPOSE) down -v

clean-all: clean ## Stop containers, remove volumes and images
	$(DOCKER) rmi docker.io/akrishnaams/dcperf-djangobench-cassandra-$(ARCH):latest \
	            docker.io/akrishnaams/dcperf-djangobench-server-$(ARCH):latest \
	            docker.io/akrishnaams/dcperf-djangobench-client-$(ARCH):latest || true

setup: ## Create required directories
	mkdir -p results logs/cassandra logs/django

setup-env: ## Copy .env.example to .env
	cp .env.example .env
	@echo "Created .env file. Please edit it to customize configuration."

init: setup setup-env ## Initialize environment (create directories and .env)

prune: ## Remove all stopped containers, networks, and build cache
	$(DOCKER) system prune -f

arch: ## Show detected architecture
	@echo "Detected architecture: $(ARCH)"
	@echo "Will use images: docker.io/akrishnaams/dcperf-djangobench-*-$(ARCH):latest"
	@echo "Will use benchpress job: $$([ "$(ARCH)" = "arm64" ] && echo 'django_workload_arm' || echo 'django_workload_default')"

inspect-db: ## Inspect Cassandra database container
	$(COMPOSE) exec cassandra-db nodetool status || echo "Cassandra not ready"

inspect-server: ## Inspect Django server container
	$(COMPOSE) exec django-server ps aux

inspect-client: ## Inspect Siege client container
	$(COMPOSE) exec siege-client ps aux

stats: ## Show resource usage statistics
	$(DOCKER) stats --no-stream

# Quick benchmark runs
quick: ## Quick benchmark run (3 iterations, fixed reps)
	ITERATIONS=3 REPS=10000 $(COMPOSE) up

dev: ## Development run (1 iteration, 5000 reps for quick testing)
	ITERATIONS=1 REPS=5000 $(COMPOSE) up

# Troubleshooting
check-network: ## Check network connectivity between containers
	@echo "Testing connectivity..."
	@echo "Django Server → Cassandra:"
	@$(COMPOSE) exec django-server nc -zv cassandra-db 9042 && echo "✓ Connection successful" || echo "✗ Connection failed"
	@echo "Siege Client → Django Server:"
	@$(COMPOSE) exec siege-client nc -zv django-server 8000 && echo "✓ Connection successful" || echo "✗ Connection failed"

check-ports: ## Check if required ports are available
	@echo "Checking ports..."
	@! lsof -i :9042 > /dev/null && echo "✓ Port 9042 available" || echo "✗ Port 9042 in use"
	@! lsof -i :8000 > /dev/null && echo "✓ Port 8000 available" || echo "✗ Port 8000 in use"

check-cpus: ## Check CPU affinity for all containers
	@echo "=== CPU Affinity Configuration ==="
	@echo "Cassandra DB (should be on Core 0):"
	@$(DOCKER) inspect django-cassandra-db --format='{{.HostConfig.CpusetCpus}}' || echo "Not running"
	@echo "Django Server (should be on Core 0):"
	@$(DOCKER) inspect django-server --format='{{.HostConfig.CpusetCpus}}' || echo "Not running"
	@echo "Siege Client (should be on Core 1):"
	@$(DOCKER) inspect django-siege-client --format='{{.HostConfig.CpusetCpus}}' || echo "Not running"

# Service-specific commands
start-db: ## Start only Cassandra database
	$(COMPOSE) up -d cassandra-db

start-server: ## Start only Django server (requires db)
	$(COMPOSE) up -d django-server

start-client: ## Start only Siege client (requires server)
	$(COMPOSE) up -d siege-client

stop-db: ## Stop Cassandra database
	$(COMPOSE) stop cassandra-db

stop-server: ## Stop Django server
	$(COMPOSE) stop django-server

stop-client: ## Stop Siege client
	$(COMPOSE) stop siege-client

# Results and logs management
results: ## Show benchmark results
	@ls -lh results/ 2>/dev/null || echo "No results yet. Run a benchmark first."

tail-siege: ## Tail Siege benchmark output in real-time
	@tail -f results/siege.log 2>/dev/null || echo "No siege.log found"

clean-logs: ## Remove all log files
	rm -rf logs/*

clean-results: ## Remove all result files
	rm -rf results/*

reset: clean build up ## Complete reset: clean, rebuild, and start
