# Makefile for FeedSim Workload Docker Setup
.PHONY: help config build clean-build pull up down logs shell clean start stop restart status ps \
        setup init prune stats reset run run-detached clean-all \
        push pull

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

# Configuration selection
CORES ?= single-core
INSTANCES ?= 1
SLO ?= with_slo

# Determine which docker-compose file to use
ifeq ($(INSTANCES),3)
	COMPOSE_FILE := docker-compose-3-inst.yml
	CONFIG := $(CORES)-3-inst
else
	COMPOSE_FILE := docker-compose.yml
	CONFIG := $(CORES)
endif

# Determine which .env file to use
ENV_FILE := .env.$(CONFIG).$(SLO)

# Compose command with config files
COMPOSE_CMD := $(COMPOSE) -f $(COMPOSE_FILE) --env-file $(ENV_FILE)

# Container name for single instance
CONTAINER := feedsim

# Template to generate 3-instance rules
define make-instance-rules
logs-inst$(1): ## Show logs from feedsim instance $(1)
	$(COMPOSE_CMD) logs -f feedsim-inst$(1)

shell-inst$(1): ## Open shell in feedsim instance $(1)
	$(COMPOSE_CMD) exec feedsim-inst$(1) /bin/bash

start-inst$(1): ## Start feedsim instance $(1)
	$(COMPOSE_CMD) up -d feedsim-inst$(1)

stop-inst$(1): ## Stop feedsim instance $(1)
	$(COMPOSE_CMD) stop feedsim-inst$(1)
endef

# Generate rules for 3-instance mode
$(foreach inst,1 2 3,$(eval $(call make-instance-rules,$(inst))))

help: ## Show this help message
	@echo "FeedSim Workload Docker Commands"
	@echo "Architecture: $(ARCH)"
	@echo ""
	@echo "Configuration Variables:"
	@echo "  CORES=$(CORES) (options: single-core, 16-core)"
	@echo "  INSTANCES=$(INSTANCES) (options: 1, 3)"
	@echo "  SLO=$(SLO) (options: with_slo, without_slo)"
	@echo "  Using: $(COMPOSE_FILE) with $(ENV_FILE)"
	@echo ""
	@echo "Usage examples:"
	@echo "  make up                                              # Use defaults (single-core, 1 instance, with_slo)"
	@echo "  make CORES=16-core SLO=without_slo up               # 16-core, single instance, without SLO"
	@echo "  make CORES=16-core INSTANCES=3 SLO=with_slo up      # 16-core, 3 instances, with SLO"
	@echo ""
	@echo "Service-specific commands:"
	@echo "  Single instance: logs, shell (start=up, stop=down)"
	@echo "  3-instance mode: logs-inst1, shell-inst2, start-inst3, stop-inst1"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

config: ## Show current configuration
	@echo "Current Configuration:"
	@echo "  CORES       = $(CORES)"
	@echo "  INSTANCES   = $(INSTANCES)"
	@echo "  CONFIG      = $(CONFIG)"
	@echo "  SLO         = $(SLO)"
	@echo "  COMPOSE_FILE = $(COMPOSE_FILE)"
	@echo "  ENV_FILE    = $(ENV_FILE)"
	@echo "  ARCH        = $(ARCH)"
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


build: ## Build Docker image
	$(COMPOSE_CMD) build

clean-build: ## Build Docker image with no cache
	$(COMPOSE_CMD) build --no-cache

push: ## Push Docker image to registry
	$(DOCKER) push docker.io/akrishnaams/dcperf-feedsim-$(ARCH):latest

pull: ## Pull Docker image from registry
	$(DOCKER) pull docker.io/akrishnaams/dcperf-feedsim-$(ARCH):latest

up: ## Start containers in detached mode
	$(COMPOSE_CMD) up -d

start: up ## Alias for 'up'

down: ## Stop and remove all containers
	$(COMPOSE_CMD) down

stop: down ## Alias for 'down'

restart: ## Restart containers
	$(COMPOSE_CMD) restart

logs: ## Show logs from feedsim container (follow mode)
	$(COMPOSE_CMD) logs -f

shell: ## Open shell in feedsim container
	$(COMPOSE_CMD) exec $(CONTAINER) /bin/bash

status: ## Show status of all containers
	$(COMPOSE_CMD) ps

ps: status ## Alias for 'status'

run: ## Run benchmark (start containers and show logs)
	$(COMPOSE_CMD) up

run-detached: up logs ## Start containers in background and show logs

clean: ## Stop containers and remove volumes
	$(COMPOSE_CMD) down -v

clean-all: clean ## Stop containers, remove volumes and images
	$(DOCKER) rmi docker.io/akrishnaams/dcperf-feedsim-$(ARCH):latest || true

setup: ## Create required directories
ifeq ($(INSTANCES),3)
	mkdir -p results/inst1 results/inst2 results/inst3 logs/inst1 logs/inst2 logs/inst3
else
	mkdir -p results logs
endif

init: setup ## Initialize environment (create directories)

prune: ## Remove all stopped containers, networks, and build cache
	$(DOCKER) system prune -f

stats: ## Show resource usage statistics
	$(DOCKER) stats --no-stream

# Service-specific rules (auto-generated for 3-instance mode)
# Single instance: logs, shell (explicitly defined above)
# 3-instance mode: logs-inst1, shell-inst1, start-inst1, stop-inst1 (and inst2, inst3)

reset: clean build up ## Complete reset: clean, rebuild, and start
