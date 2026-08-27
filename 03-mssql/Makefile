# Task 03 — SQL Server with automated backups and PITR restore.
#
# NOTE: `make` is NOT installed on the development host used for this project.
# These targets are thin wrappers over scripts/, which are the tested path and
# can be run directly:  ./scripts/up.sh, ./scripts/verify.sh
#
# Requires GNU make and bash. On Windows use Git Bash.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help up down destroy verify quick schema agent backups restore pitr logs ps sql

help: ## Show this help
	@echo "Task 03 — SQL Server, automated backups, PITR restore"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

up: ## Bring up SQL Server, create the database, apply schema and seed
	@./scripts/up.sh

down: ## Stop containers, KEEPING the data and backup volumes
	@MSYS_NO_PATHCONV=1 docker compose down

destroy: ## Stop containers AND destroy the data and backup volumes
	@MSYS_NO_PATHCONV=1 docker compose down -v

verify: ## Run every check and both restore drills
	@./scripts/verify.sh

quick: ## Non-destructive checks only
	@./scripts/verify.sh --quick

schema: ## Schema and data inventory
	@./scripts/checks/schema-report.sh

agent: ## Probe SQL Server Agent availability on this instance
	@./scripts/checks/agent-availability.sh

backups: ## Three-tier backup strategy, verification and retention
	@./scripts/drills/03-backup-tiers.sh

restore: ## DRILL: destroy data and restore from backup
	@./scripts/drills/01-restore-roundtrip.sh

pitr: ## DRILL: point-in-time recovery with STOPAT
	@./scripts/drills/02-point-in-time.sh

ps: ## Service status
	@MSYS_NO_PATHCONV=1 docker compose ps

logs: ## Tail the backup scheduler log
	@MSYS_NO_PATHCONV=1 docker compose logs -f --tail=50 backup

sql: ## Interactive sqlcmd session
	@MSYS_NO_PATHCONV=1 docker exec -it task03-mssql /opt/mssql-tools18/bin/sqlcmd \
	  -S localhost -U sa -P "$$(cat secrets/mssql_sa_password.txt)" -C
