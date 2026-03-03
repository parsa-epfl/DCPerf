# Makefile for Django Workload Docker Setup
.PHONY: help config build clean-build pull up down logs clean start stop restart status ps \
        setup init prune stats reset run run-detached clean-all \
        build-db build-server build-client clean-build-db clean-build-server clean-build-client \
        push push-db push-server push-client pull-db pull-server pull-client

# Default target
.DEFAULT_GOAL := help

# Support both docker-compose (V1) and docker compose (V2)
COMPOSE := $(shell command -v docker-compose 2>/dev/null)
ifndef COMPOSE
	COMPOSE := docker compose
endif
DOCKER := docker

# Auto-detect architecture if not set
ARCH ?= $(shell uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/;s/arm64/arm64/')
export ARCH

# Configuration - CORES is a number (1, 16, 32, ...), INSTANCES is a count
CORES ?= 1
INSTANCES ?= 1

# Derive human-readable cores label: 1 -> single-core, N -> N-core
ifeq ($(CORES),1)
	CORES_LABEL := single-core
else
	CORES_LABEL := $(CORES)-core
endif

# Determine compose file name
ifeq ($(INSTANCES),1)
	COMPOSE_FILE := docker-compose.yml
else
	COMPOSE_FILE := docker-compose-$(INSTANCES)-inst.yml
endif

# Determine env file name
ifeq ($(INSTANCES),1)
	CONFIG := $(CORES_LABEL)
else
	CONFIG := $(CORES_LABEL)-$(INSTANCES)-inst
endif
ENV_FILE := .env.$(CONFIG)

# Auto-generate compose file if not present
ifeq (,$(wildcard $(COMPOSE_FILE)))
$(info Generating missing $(COMPOSE_FILE) for $(INSTANCES) instance(s), arch=$(ARCH)...)
$(shell python3 generate_docker_compose.py $(INSTANCES) $(COMPOSE_FILE) --arch $(ARCH))
endif

# Auto-generate env file if not present
ifeq (,$(wildcard $(ENV_FILE)))
$(info Generating missing $(ENV_FILE) for $(CORES) cores, $(INSTANCES) instance(s), arch=$(ARCH)...)
$(shell python3 generate_env.py $(CORES) $(INSTANCES) $(ENV_FILE) --arch $(ARCH))
endif

# Compose command with config files
COMPOSE_CMD := $(COMPOSE) -f $(COMPOSE_FILE) --env-file $(ENV_FILE)

# Instance number list for dynamic rule generation
INSTANCE_NUMS := $(shell seq 1 $(INSTANCES))

# Service mappings
SERVICES := db server client
CONTAINER_db := cassandra-db
CONTAINER_server := django-server
CONTAINER_client := siege-client

# Template to generate service-specific rules for single instance
define make-service-rules
logs-$(1): ## Show logs from $(1)
	$(COMPOSE_CMD) logs -f $(CONTAINER_$(1))

shell-$(1): ## Open shell in $(1)
	$(COMPOSE_CMD) exec $(CONTAINER_$(1)) /bin/bash

start-$(1): ## Start only $(1)
	$(COMPOSE_CMD) up -d $(CONTAINER_$(1))

stop-$(1): ## Stop $(1)
	$(COMPOSE_CMD) stop $(CONTAINER_$(1))
endef

# Template to generate N-instance rules
define make-instance-rules
logs-$(1)-inst$(2): ## Show logs from $(1) instance $(2)
	$(COMPOSE_CMD) logs -f $(CONTAINER_$(1))-inst$(2)

shell-$(1)-inst$(2): ## Open shell in $(1) instance $(2)
	$(COMPOSE_CMD) exec $(CONTAINER_$(1))-inst$(2) /bin/bash

start-$(1)-inst$(2): ## Start only $(1) instance $(2)
	$(COMPOSE_CMD) up -d $(CONTAINER_$(1))-inst$(2)

stop-$(1)-inst$(2): ## Stop $(1) instance $(2)
	$(COMPOSE_CMD) stop $(CONTAINER_$(1))-inst$(2)
endef

# Generate per-service rules (single instance) or per-instance rules (multi)
ifeq ($(INSTANCES),1)
$(foreach service,$(SERVICES),$(eval $(call make-service-rules,$(service))))
else
$(foreach service,$(SERVICES),$(foreach inst,$(INSTANCE_NUMS),$(eval $(call make-instance-rules,$(service),$(inst)))))
endif

help: ## Show this help message
	@echo "Django Workload Docker Commands"
	@echo "Architecture: $(ARCH)"
	@echo ""
	@echo "Configuration Variables (pass on command line):"
	@echo "  CORES     = $(CORES)  (number of cores per instance; 1 = single-core)"
	@echo "  INSTANCES = $(INSTANCES)  (number of parallel instances)"
	@echo "  Using:    $(COMPOSE_FILE)  +  $(ENV_FILE)"
	@echo ""
	@echo "Usage examples:"
	@echo "  make up                            # defaults: 1 core, 1 instance"
	@echo "  make CORES=16 up                   # 16-core, 1 instance"
	@echo "  make CORES=16 INSTANCES=3 up       # 16-core, 3 instances"
	@echo "  make CORES=32 INSTANCES=4 up       # 32-core, 4 instances (auto-generated)"
	@echo ""
	@echo "  Missing compose/env files are auto-generated from:"
	@echo "    generate_docker_compose.py  and  generate_env.py"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

config: ## Show current configuration
	@echo "Current Configuration:"
	@echo "  CORES        = $(CORES)"
	@echo "  CORES_LABEL  = $(CORES_LABEL)"
	@echo "  INSTANCES    = $(INSTANCES)"
	@echo "  CONFIG       = $(CONFIG)"
	@echo "  COMPOSE_FILE = $(COMPOSE_FILE)"
	@echo "  ENV_FILE     = $(ENV_FILE)"
	@echo "  ARCH         = $(ARCH)"
	@echo ""
	@if [ -f "$(COMPOSE_FILE)" ]; then \
		echo "✓ Docker Compose file exists: $(COMPOSE_FILE)"; \
	else \
		echo "✗ Docker Compose file NOT found: $(COMPOSE_FILE)"; \
	fi
	@if [ -f "$(ENV_FILE)" ]; then \
		echo "✓ Environment file exists: $(ENV_FILE)"; \
	else \
		echo "✗ Environment file NOT found: $(ENV_FILE)"; \
	fi


build: ## Build all Docker images (db, server, client)
	$(COMPOSE_CMD) build

build-db: ## Build only the Cassandra database image (single-instance only)
	$(COMPOSE_CMD) build cassandra-db

build-server: ## Build only the Django server image (single-instance only)
	$(COMPOSE_CMD) build django-server

build-client: ## Build only the Siege client image (single-instance only)
	$(COMPOSE_CMD) build siege-client

clean-build-db:
	$(COMPOSE_CMD) build --no-cache cassandra-db

clean-build-server:
	$(COMPOSE_CMD) build --no-cache django-server

clean-build-client:
	$(COMPOSE_CMD) build --no-cache siege-client

clean-build: ## Build all Docker images with no cache
	$(COMPOSE_CMD) build --no-cache

push: ## Push all Docker images to registry
	$(DOCKER) push docker.io/akrishnaams/dcperf-djangobench-cassandra-$(ARCH):latest
	$(DOCKER) push docker.io/akrishnaams/dcperf-djangobench-server-$(ARCH):latest
	$(DOCKER) push docker.io/akrishnaams/dcperf-djangobench-client-$(ARCH):latest

push-db: ## Push only the Cassandra database image
	$(DOCKER) push docker.io/akrishnaams/dcperf-djangobench-cassandra-$(ARCH):latest

push-server: ## Push only the Django server image
	$(DOCKER) push docker.io/akrishnaams/dcperf-djangobench-server-$(ARCH):latest

push-client: ## Push only the Siege client image
	$(DOCKER) push docker.io/akrishnaams/dcperf-djangobench-client-$(ARCH):latest

pull: ## Pull all Docker images from registry
	$(DOCKER) pull docker.io/akrishnaams/dcperf-djangobench-cassandra-$(ARCH):latest
	$(DOCKER) pull docker.io/akrishnaams/dcperf-djangobench-server-$(ARCH):latest
	$(DOCKER) pull docker.io/akrishnaams/dcperf-djangobench-client-$(ARCH):latest

pull-db: ## Pull only the Cassandra database image
	$(DOCKER) pull docker.io/akrishnaams/dcperf-djangobench-cassandra-$(ARCH):latest

pull-server: ## Pull only the Django server image
	$(DOCKER) pull docker.io/akrishnaams/dcperf-djangobench-server-$(ARCH):latest

pull-client: ## Pull only the Siege client image
	$(DOCKER) pull docker.io/akrishnaams/dcperf-djangobench-client-$(ARCH):latest

up: ## Start all containers in detached mode
	$(COMPOSE_CMD) up -d

start: up ## Alias for 'up'

down: ## Stop and remove all containers
	$(COMPOSE_CMD) down

stop: down ## Alias for 'down'

restart: ## Restart all containers
	$(COMPOSE_CMD) restart

logs: ## Show logs from all containers (follow mode)
	$(COMPOSE_CMD) logs -f

status: ## Show status of all containers
	$(COMPOSE_CMD) ps

ps: status ## Alias for 'status'

run: ## Run benchmark (start containers and show logs)
	$(COMPOSE_CMD) up

run-detached: up logs ## Start containers in background and show logs

clean: ## Stop containers and remove volumes
	$(COMPOSE_CMD) down -v

clean-all: clean ## Stop containers, remove volumes and images
	$(DOCKER) rmi docker.io/akrishnaams/dcperf-djangobench-cassandra-$(ARCH):latest \
	            docker.io/akrishnaams/dcperf-djangobench-server-$(ARCH):latest \
	            docker.io/akrishnaams/dcperf-djangobench-client-$(ARCH):latest || true

setup: ## Create required directories
ifeq ($(INSTANCES),1)
	mkdir -p results logs/cassandra logs/django
else
	@mkdir -p $(foreach i,$(INSTANCE_NUMS),results/inst$(i)) \
	          $(foreach i,$(INSTANCE_NUMS),logs/cassandra-inst$(i)) \
	          $(foreach i,$(INSTANCE_NUMS),logs/django-inst$(i))
endif

init: setup ## Initialize environment (create directories)

prune: ## Remove all stopped containers, networks, and build cache
	$(DOCKER) system prune -f

stats: ## Show resource usage statistics
	$(DOCKER) stats --no-stream

# Service-specific rules (auto-generated from templates above)
# Available commands: logs-{service}, shell-{service}, start-{service}, stop-{service}
# Where {service} = db, server, client
# For 3-instance mode: add -inst1, -inst2, or -inst3 suffix
# Examples: logs-db, shell-server-inst2, start-client, stop-db-inst1

reset: clean build up ## Complete reset: clean, rebuild, and start
