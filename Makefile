# WA Parcel Reconciliation — task runner
#
# Exists for two reasons, both of which have already cost time:
#
#   1. dbt does NOT read .env. env_var() in profiles.yml reads the process
#      environment, so the file has to be sourced before dbt starts. There is
#      no --env-file flag in dbt-core.
#
#   2. `dbt` on PATH is dbt Fusion 2.0, which does not support Postgres at all
#      ("the 'postgres' adapter is not yet supported by dbt Fusion"). Every
#      target below pins .venv/bin/dbt explicitly. Never invoke a bare `dbt`
#      in this project.
#
# Recipes run under bash regardless of your login shell, so the bash-only
# `set -a` idiom works even though the project shell is fish.

SHELL := /bin/bash
ROOT  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
DBT   := $(ROOT)/.venv/bin/dbt
PY    := $(ROOT)/.venv/bin/python

# set -a exports everything defined until set +a, which is how the .env values
# reach dbt's env_var() calls.
ENV := set -a; . $(ROOT)/.env; set +a;

.DEFAULT_GOAL := help
.PHONY: help build build-all test overlaps docs ingest ingest-state ingest-all list check

help:  ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build:  ## Routine build — everything except the expensive overlap models
	@$(ENV) cd $(ROOT)/parcels && $(DBT) build --exclude tag:expensive

build-all:  ## Full build including overlap models (~81s extra)
	@$(ENV) cd $(ROOT)/parcels && $(DBT) build

test:  ## Run tests only
	@$(ENV) cd $(ROOT)/parcels && $(DBT) test --exclude tag:expensive

overlaps:  ## Rebuild only the per-county overlap models
	@$(ENV) cd $(ROOT)/parcels && $(DBT) build --select tag:overlaps

docs:  ## Generate and serve dbt docs
	@$(ENV) cd $(ROOT)/parcels && $(DBT) docs generate && $(DBT) docs serve

# --- ingestion -------------------------------------------------------------
# COUNTY is a FIPS code from the manifest: make ingest COUNTY=053
ingest:  ## Ingest one county (COUNTY=<fips>), optional WHERE=<sql>
	@test -n "$(COUNTY)" || { echo "usage: make ingest COUNTY=053 [WHERE='OBJECTID <= 5000']"; exit 2; }
	@$(ENV) cd $(ROOT) && $(PY) -m ingest.run --county $(COUNTY) $(if $(WHERE),--where "$(WHERE)")

ingest-state:  ## Ingest the statewide reference layers
	@$(ENV) cd $(ROOT) && $(PY) -m ingest.run --state

ingest-all:  ## Ingest every county in the manifest
	@$(ENV) cd $(ROOT) && $(PY) -m ingest.run --all

list:  ## Show the source manifest
	@$(ENV) cd $(ROOT) && $(PY) -m ingest.run --list

# --- diagnostics -----------------------------------------------------------
check:  ## Verify the environment before blaming a query
	@echo "dbt      : $$($(DBT) --version 2>/dev/null | head -1)"
	@echo "warehouse: $$(docker inspect -f '{{.State.Status}}' parcel_warehouse 2>/dev/null || echo 'not running')"
	@echo "disk     : $$(docker exec parcel_warehouse df -h /var/lib/postgresql/data 2>/dev/null | tail -1 | awk '{print $$4" free ("$$5" used)"}')"
	@$(ENV) docker exec parcel_warehouse psql -U $$POSTGRES_USER -d $$POSTGRES_DB -tAc \
	  "select 'geom index: ' || coalesce((select indexname from pg_indexes where schemaname='staging' and tablename='int_parcels_conformed' and indexname='idx_conformed_geom'), 'MISSING');" 2>/dev/null
	@$(ENV) docker exec parcel_warehouse psql -U $$POSTGRES_USER -d $$POSTGRES_DB -tAc \
	  "select 'active queries: ' || count(*) from pg_stat_activity where datname=current_database() and state<>'idle';" 2>/dev/null
