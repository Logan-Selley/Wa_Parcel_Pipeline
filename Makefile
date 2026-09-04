# WA Parcel Reconciliation -- task runner
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
.PHONY: help build test overlaps docs ingest ingest-state ingest-all list check freshness

# --- export / static site ----------------------------------------------------
# The warehouse is a build tool, not a service: gold tables export to static
# artifacts (parquet for analysis, csv for Tableau, fgb -> vector tiles for the
# map). Nothing needs to be hosted for the outputs to exist.

export:  ## Export gold tables to parquet/csv/json + FlatGeobuf (exports/)
	@$(ENV) cd $(ROOT) && $(PY) scripts/export.py

# tippecanoe is BUILT, not pulled. klokantech/tippecanoe -- the image every
# tutorial names -- is v1.24.1: it cannot read FlatGeobuf (it parses the binary
# as text and reports "Found unexpected character") and has no PMTiles output
# whatsoever. ghcr.io/felt/tippecanoe is not publicly pullable. See
# docker/Dockerfile.tippecanoe.
tippecanoe-image:  ## Build the tippecanoe image (felt fork, pinned)
	@docker image inspect parcel-tippecanoe:latest >/dev/null 2>&1 || \
	  docker build -f $(ROOT)/docker/Dockerfile.tippecanoe -t parcel-tippecanoe:latest $(ROOT)

# A TILE DIRECTORY, NOT A .pmtiles ARCHIVE.
#
# PMTiles is one file read with HTTP range requests, which is elegant and does
# not work here: GitHub Pages advertises `accept-ranges: bytes` and then answers
# a Range request with 200 and the whole 17.8 MB body (verified, on a cache
# HIT). pmtiles.js rejects that, so the map renders a basemap and nothing else.
#
# A directory of z/x/y.pbf needs no byte-serving -- every tile is its own GET.
# Costs 4,522 files and 52 MB against the archive's single 17 MB, and a rebuild
# rewrites most of them, which is the price of the host not byte-serving.
#
# -Z is MINIMUM zoom, -z is MAXIMUM zoom. They are different flags and the
# casing is the only thing distinguishing them. This once read `-Z6 -Z13`,
# setting the minimum twice, so the archive held nothing below z13.
#
# --no-tile-compression is REQUIRED for static hosting. Tippecanoe gzips tiles
# by default, and the browser only inflates them if the server sends
# Content-Encoding: gzip -- which Pages does not do for .pbf. Without this flag
# MapLibre receives gzip bytes and fails to parse every tile.
tiles: tippecanoe-image  ## Build the map tiles from the FlatGeobuf export
	@rm -rf $(ROOT)/site/data/tiles
	@mkdir -p $(ROOT)/site/data
	@docker run --rm --user $$(id -u):$$(id -g) \
	  -v $(ROOT)/exports:/data -v $(ROOT)/site/data:/out parcel-tippecanoe:latest \
	  tippecanoe -e /out/tiles --force \
	  --layer=findings --read-parallel -Z6 -z13 \
	  --drop-densest-as-needed --extend-zooms-if-still-dropping \
	  --no-tile-compression \
	  -T is_encroachment:bool -T is_unflagged_coincident:bool \
	  -T disagrees_with_state:bool -T absent_from_state:bool \
	  -T absent_from_ours:bool -T geometry_repaired:bool \
	  -T is_quarantined:bool -T state_duplicate_id:bool \
	  /data/fgb/wa_findings.fgb
	@echo "site/data/tiles: $$(find $(ROOT)/site/data/tiles -name '*.pbf' | wc -l) tiles, $$(du -sh $(ROOT)/site/data/tiles | cut -f1)"

# site/index.html requests data/*.json and data/tiles/{z}/{x}/{y}.pbf by
# relative path, so site/ is served as the Pages root exactly as assembled.
site: tiles  ## Assemble the static site (data into site/data/)
	@cp $(ROOT)/exports/json/*.json $(ROOT)/site/data/
	@echo "site/ ready -- serve with any static file server"

.PHONY: export tiles site tippecanoe-image

# --- orchestration -----------------------------------------------------------
# Airflow runs in its OWN containers and its OWN metadata database, and invokes
# the pipeline image as sibling containers. It never shares a Python
# environment with dbt -- see airflow/dags/parcel_pipeline.py.

pipeline-image:  ## Build the pipeline image the DAG runs (ingest + dbt + export)
	@docker build -f $(ROOT)/docker/Dockerfile.pipeline -t parcel-pipeline:latest $(ROOT)

airflow-up: pipeline-image  ## Start Airflow (http://localhost:8080)
	@$(ENV) DOCKER_GID=$$(getent group docker | cut -d: -f3) \
	  HOST_UID=$$(id -u) HOST_GID=$$(id -g) PWD=$(ROOT) \
	  docker compose -f $(ROOT)/docker-compose.airflow.yml up -d
	@echo "Airflow starting -> http://localhost:8080"
	@echo "The DAG is paused by default; unpause it in the UI to schedule."

airflow-down:  ## Stop Airflow (metadata volume is preserved)
	@$(ENV) PWD=$(ROOT) docker compose -f $(ROOT)/docker-compose.airflow.yml down

airflow-logs:  ## Tail the Airflow scheduler/webserver logs
	@$(ENV) PWD=$(ROOT) docker compose -f $(ROOT)/docker-compose.airflow.yml logs -f airflow

.PHONY: pipeline-image airflow-up airflow-down airflow-logs


help:  ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# There is no longer a "routine" build distinct from a full one. `build` and
# `test` used to pass --exclude tag:expensive to skip the overlap models; both
# the cost and the correctness argument for that are gone.
#
#   cost         overlaps are 32.55s for all four counties on 4 threads
#                (snohomish 32.0, king 26.8, pierce 15.0, spokane 14.9) against
#                119s for int_parcels_repaired alone. The tag dated from a build
#                that ran over an hour, which was the missing GiST index on
#                int_parcels_conformed, not these models.
#
#   correctness  agg_quality_scorecard refs the per-county overlap tables
#                directly, so excluding the overlap models never excluded their
#                consumer. The scorecard rebuilt against whatever those tables
#                last held and published encroachment counts quietly older than
#                every other number beside them.
#
# tag:overlaps stays, for iterating on the overlap logic alone.

build:  ## Full build -- every model and test (~8m20s, 64 nodes, 4 threads)
	@$(ENV) cd $(ROOT)/parcels && $(DBT) build

test:  ## Run tests only
	@$(ENV) cd $(ROOT)/parcels && $(DBT) test

overlaps:  ## Rebuild only the per-county overlap models (~33s)
	@$(ENV) cd $(ROOT)/parcels && $(DBT) build --select tag:overlaps

freshness:  ## Check whether any source has republished since the last ingest
	@$(ENV) cd $(ROOT) && $(PY) -m ingest.freshness --all; \
	  $(ENV) cd $(ROOT) && $(PY) -m ingest.freshness --state

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
