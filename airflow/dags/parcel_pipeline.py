"""WA parcel reconciliation — ingest, transform, export.

WHY DockerOperator AND NOT BashOperator / PythonOperator
--------------------------------------------------------
Airflow pins its transitive dependencies tightly enough to fight dbt-core, so
the two never share a Python environment. A PythonOperator that imported dbt
would put them in the same interpreter; a BashOperator would need the pipeline
installed inside the Airflow image, which amounts to the same thing.

DockerOperator keeps the boundary real: Airflow's only job is deciding WHAT
runs, WHEN, and IN WHAT ORDER. The pipeline image owns HOW. Airflow could be
swapped for Dagster, cron, or a shell script without touching a line of
pipeline code -- which is the property that makes orchestration worth adding
rather than a place for logic to accumulate.

SIBLING CONTAINERS, NOT CHILDREN
--------------------------------
DockerOperator does not run a container *inside* the Airflow container. It
talks to the HOST Docker daemon through the mounted socket and asks it to start
a sibling. Two consequences that are easy to get wrong:

  * `mounts` are resolved by the HOST daemon, so every source path must be a
    host path. PIPELINE_HOST_ROOT is passed in from compose for exactly this;
    a path that exists only inside the Airflow container would silently mount
    an empty directory.
  * The task container joins `parcel_pipeline_default`, the warehouse's
    network, so it reaches the database as `warehouse:5432` -- the container
    name and the INTERNAL port. Not `localhost:5433`, which is the host-side
    mapping the .env file carries for local work. Reusing the .env values here
    is the single most likely thing to break this DAG, so they are overridden
    below rather than passed through.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.docker.operators.docker import DockerOperator
from docker.types import Mount

PIPELINE_IMAGE = "parcel-pipeline:latest"
NETWORK = "parcel_pipeline_default"
HOST_ROOT = os.environ["PIPELINE_HOST_ROOT"]

# Inside the shared docker network the warehouse is reachable by service name on
# its internal port. See the module docstring.
WAREHOUSE_ENV = {
    "WAREHOUSE_HOST": "warehouse",
    "WAREHOUSE_PORT": "5432",
    "POSTGRES_USER": os.environ["POSTGRES_USER"],
    "POSTGRES_PASSWORD": os.environ["POSTGRES_PASSWORD"],
    "POSTGRES_DB": os.environ["POSTGRES_DB"],
}

# Exports are large (3.2 GB) and belong on the host, not in a container layer.
EXPORT_MOUNT = Mount(
    source=f"{HOST_ROOT}/exports", target="/opt/pipeline/exports", type="bind"
)


def pipeline_task(task_id: str, command: str, *, timeout_min: int,
                  retries: int = 0, mounts=None) -> DockerOperator:
    """One pipeline step as a sibling container.

    execution_timeout values come from measured runtimes, not guesses -- a
    timeout shorter than reality turns a slow day into a false alarm, and one
    far longer lets a hung task hold its resources all night.
    """
    return DockerOperator(
        task_id=task_id,
        image=PIPELINE_IMAGE,
        command=command,
        docker_url="unix://var/run/docker.sock",
        network_mode=NETWORK,
        environment=WAREHOUSE_ENV,
        mounts=mounts or [],
        working_dir="/opt/pipeline",
        auto_remove="success",   # keep failed containers around to inspect
        mount_tmp_dir=False,
        retries=retries,
        retry_delay=timedelta(minutes=2),
        execution_timeout=timedelta(minutes=timeout_min),
    )


with DAG(
    dag_id="parcel_pipeline",
    description="Ingest WA county + state parcels, conform and reconcile, export",
    start_date=datetime(2026, 1, 1),
    schedule="@daily",
    catchup=False,
    # A second concurrent run would fight the first for locks: BronzeLoader
    # takes a per-county advisory lock, and dbt's table materialisation swaps
    # by rename -- two runs racing produce "relation already exists". Serialise.
    max_active_runs=1,
    default_args={"owner": "parcel-pipeline", "depends_on_past": False},
    tags=["parcels", "reconciliation"],
) as dag:

    # ---- extract ---------------------------------------------------------
    # Counties fan out in parallel, which is safe WITHOUT an Airflow pool:
    # BronzeLoader holds a session-scoped advisory lock per table, so two runs
    # of the SAME county block each other while different counties do not.
    # The concurrency guarantee lives in the pipeline, where it can be tested.
    #
    # retries=2 here and nowhere else: sources are public services that go down
    # for minutes at a time. The extractor already retries transient failures
    # internally with backoff and fails fast on deterministic ones, so an
    # Airflow retry only covers the longer outage the process cannot ride out.
    ingest_counties = [
        pipeline_task(
            f"ingest_{name}",
            f"python -m ingest.run --county {fips}",
            timeout_min=20,
            retries=2,
        )
        for fips, name in [
            ("033", "king"), ("053", "pierce"),
            ("061", "snohomish"), ("063", "spokane"),
        ]
    ]

    ingest_state = pipeline_task(
        "ingest_state",
        "python -m ingest.run --state",
        timeout_min=45,   # 3.3M parcels; ~10 min with keyset paging, headroom for a bad day
        retries=2,
    )

    # ---- transform -------------------------------------------------------
    # No retries. A dbt failure is deterministic -- a compile error or a failed
    # assertion -- so a retry burns time and reruns the same failure. The one
    # exception, lock contention, is prevented by max_active_runs above.
    #
    # --exclude tag:expensive omits the overlap models. They hold ACCESS SHARE
    # on int_parcels_conformed for their whole run while a rebuild needs ACCESS
    # EXCLUSIVE, so running them alongside a build makes the build wait rather
    # than fail -- once measured at 52 minutes looking hung. They belong in a
    # separate, less frequent DAG.
    dbt_build = pipeline_task(
        "dbt_build",
        "bash -c 'cd parcels && dbt build --exclude tag:expensive'",
        timeout_min=30,
    )

    # ---- publish ---------------------------------------------------------
    # Export is downstream of a GREEN build by construction: dbt build runs
    # models and tests together, so a failed assertion fails this task and the
    # export never runs. Publishing artifacts from a warehouse that just failed
    # its own tests is the thing this ordering exists to prevent.
    export = pipeline_task(
        "export",
        "python scripts/export.py",
        timeout_min=30,
        mounts=[EXPORT_MOUNT],
    )

    [*ingest_counties, ingest_state] >> dbt_build >> export
