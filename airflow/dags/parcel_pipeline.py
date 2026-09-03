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

HOW THE DAG NO-OPS WHEN NOTHING PUBLISHED
-----------------------------------------
The sources republish every few weeks, so most daily runs would re-fetch 1.5M
unchanged parcels to produce yesterday's artifacts again. Each ingest is
therefore preceded by a `check_*` gate that compares the publisher's
editingInfo.lastEditDate against the last one we recorded (ingest/freshness.py).

The mechanism is two Airflow behaviours composed:

  * DockerOperator's `skip_on_exit_code` turns the gate's exit 99 into a SKIPPED
    task rather than a failure. Skipped propagates: an ingest whose gate skipped
    is skipped too, under the default all_success rule.
  * dbt_build uses NONE_FAILED_MIN_ONE_SUCCESS instead. It runs when at least
    one ingest actually ran and none failed -- so one county publishing is
    enough to rebuild everything, which is correct, because the reconciliation
    is cross-county and the scorecard is comparative.

Together: every source unchanged -> zero successful ingests -> dbt_build skips
-> export skips -> the run costs five metadata calls. Any source changed -> the
full pipeline. There is no third state and no branching operator to keep in
sync.

The gate is deliberately not `ShortCircuitOperator`: that would put the freshness
logic in the Airflow environment, where it would need requests, SQLAlchemy and
warehouse credentials, and where it could not be run or tested outside Airflow.
`python -m ingest.freshness --county 053` works from a shell.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.docker.operators.docker import DockerOperator
from airflow.utils.trigger_rule import TriggerRule
from docker.types import Mount

PIPELINE_IMAGE = "parcel-pipeline:latest"
NETWORK = "parcel_pipeline_default"
HOST_ROOT = os.environ["PIPELINE_HOST_ROOT"]

# ingest.freshness exits 99 for "provably unchanged". Must match EXIT_UNCHANGED
# there; the constant is duplicated because this file and that one live in
# different Python environments by design and cannot import each other.
SKIP_UNCHANGED = 99

COUNTIES = [("033", "king"), ("053", "pierce"),
            ("061", "snohomish"), ("063", "spokane")]

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
                  retries: int = 0, mounts=None, skip_on_exit_code=None,
                  trigger_rule=TriggerRule.ALL_SUCCESS) -> DockerOperator:
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
        skip_on_exit_code=skip_on_exit_code,
        trigger_rule=trigger_rule,
    )


def freshness_gate(task_id: str, selector: str) -> DockerOperator:
    """Skip the run for this source unless the publisher republished.

    `selector` is passed verbatim to BOTH this gate and the ingest it guards,
    so the two cannot drift apart.

    One metadata call and one indexed max(). Two minutes is generous for that
    and still short enough that a hung public service fails the gate rather
    than stalling the schedule -- which is the right outcome, because a
    NON-RESPONDING source must never read as an unchanged one.

    retries=1: a single transient blip should not fail the run, but the gate is
    not where to ride out an outage. If the source is genuinely down, failing
    here is cheaper and clearer than failing 20 minutes into a fetch.
    """
    return pipeline_task(
        task_id,
        # params.force is templated at runtime, so a manual trigger with
        # {"force": true} bypasses every gate without editing the DAG.
        f"python -m ingest.freshness {selector}"
        "{{ ' --force' if params.force else '' }}",
        timeout_min=2,
        retries=1,
        skip_on_exit_code=SKIP_UNCHANGED,
    )


with DAG(
    dag_id="parcel_pipeline",
    description="Ingest WA county + state parcels, conform and reconcile, export",
    start_date=datetime(2026, 1, 1),
    # Daily is cheap now that each source is gated: an unchanged day costs five
    # metadata calls. Checking daily against sources that publish every few
    # weeks means the data is picked up the morning after it lands, rather than
    # waiting out a slower schedule that happened to guess wrong.
    schedule="@daily",
    catchup=False,
    # Manual trigger with {"force": true} bypasses every freshness gate. The
    # documented remedy for rerunning after a downstream failure, and for the
    # first run after a model change that no source republish will trigger.
    params={"force": False},
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
    ingest_counties = []
    for fips, name in COUNTIES:
        check = freshness_gate(f"check_{name}", f"--county {fips}")
        ingest = pipeline_task(
            f"ingest_{name}",
            f"python -m ingest.run --county {fips}",
            timeout_min=20,
            retries=2,
        )
        check >> ingest
        ingest_counties.append(ingest)

    # --state with no argument covers all three statewide layers, and the gate
    # takes the same selector: if parcels, File_Date or the land use lookup
    # moved, all three are refetched together. They are one publication.
    check_state = freshness_gate("check_state", "--state")
    ingest_state = pipeline_task(
        "ingest_state",
        "python -m ingest.run --state",
        timeout_min=45,   # 3.3M parcels; ~10 min with keyset paging, headroom for a bad day
        retries=2,
    )
    check_state >> ingest_state

    # ---- transform -------------------------------------------------------
    # No retries. A dbt failure is deterministic -- a compile error or a failed
    # assertion -- so a retry burns time and reruns the same failure. The one
    # exception, lock contention, is prevented by max_active_runs above.
    #
    # A FULL BUILD, overlaps included. An earlier version excluded them, which
    # was wrong twice over. The lock contention that motivated it only occurs
    # between CONCURRENT invocations -- inside one build dbt orders the overlap
    # models after int_parcels_conformed, and max_active_runs=1 rules out the
    # concurrent case entirely. And excluding them did not exclude their
    # consumer: agg_quality_scorecard refs the four county overlap tables
    # directly, so it rebuilt every night reading whatever they last held. The
    # published encroachment counts would have silently aged away from the
    # parcels beside them in the same table.
    #
    # The cost that justified the exclusion is also gone: 32.55s for all four
    # counties, against 119s for int_parcels_repaired alone. See the Makefile.
    dbt_build = pipeline_task(
        "dbt_build",
        "bash -c 'cd parcels && dbt build'",
        # Measured 8m23s for the full 64-node build on four threads, overlaps
        # included. 30 leaves room for a slower disk without letting a genuinely
        # stuck build hold the warehouse all night.
        timeout_min=30,
        # ALL_SUCCESS would skip this whenever ANY gate skipped, so a single
        # unchanged county would suppress a rebuild the other three earned.
        # This rule means: at least one ingest ran, and nothing failed.
        trigger_rule=TriggerRule.NONE_FAILED_MIN_ONE_SUCCESS,
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
