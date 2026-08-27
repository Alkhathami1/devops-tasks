# Task 02 — multi-tier Docker stack.
#
# Two commands do everything the assignment's automation requirement asks for:
#   make up       bring the whole stack up from nothing
#   make verify   run every check and drill
#
# Requires GNU make and bash. On Windows use Git Bash.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help up down destroy verify quick smoke isolation resources secrets \
        drill-crash drill-oom drill-db drill-persist drill-daemon logs ps

help: ## Show this help
	@echo "Task 02 — multi-tier Docker stack"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

up: ## Bring the whole stack up from nothing (idempotent)
	@./scripts/up.sh

down: ## Stop and remove containers, KEEPING the data volume
	@MSYS_NO_PATHCONV=1 docker compose down

destroy: ## Stop and remove containers AND the data volume (destroys data)
	@MSYS_NO_PATHCONV=1 docker compose down -v

verify: ## Run every check and every failure drill
	@./scripts/verify.sh

quick: ## Run the non-destructive checks only
	@./scripts/verify.sh --quick

smoke: ## DB-backed round trip through the reverse proxy
	@./scripts/smoke-test.sh

isolation: ## Prove the private network topology
	@./scripts/isolation-check.sh

resources: ## Show applied CPU/RAM limits and live usage
	@./scripts/resources.sh

secrets: ## Compare env vars with file-based secrets
	@./scripts/drills/05-secrets-comparison.sh

drill-crash: ## DRILL A: crash and restart policy
	@./scripts/drills/01-backend-kill.sh

drill-oom: ## DRILL B: RAM exhaustion and OOM kill
	@./scripts/drills/02-oom-kill.sh

drill-persist: ## DRILL D: data persistence across down/up
	@./scripts/drills/03-persistence.sh

drill-db: ## DRILL E: database failure under a live backend
	@./scripts/drills/04-db-failure.sh

drill-daemon: ## DRILL C: Docker daemon restart (disruptive)
	@./scripts/drills/06-daemon-restart.sh

ps: ## Show service status
	@MSYS_NO_PATHCONV=1 docker compose ps

logs: ## Tail logs from all services
	@MSYS_NO_PATHCONV=1 docker compose logs -f --tail=50
