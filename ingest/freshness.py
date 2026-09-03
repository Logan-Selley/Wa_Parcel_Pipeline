"""Source freshness gate -- has the publisher republished since we last looked?

    python -m ingest.freshness --county 053
    python -m ingest.freshness --all
    python -m ingest.freshness --state
    python -m ingest.freshness --county 053 --force

WHY THIS EXISTS
---------------
The four counties and the statewide layer republish every few weeks. A daily
schedule against them means most runs re-fetch 1.5M unchanged parcels, rebuild
every model, and re-export 3.2 GB to produce artifacts byte-identical to
yesterday's. The work is not merely wasted -- it puts avoidable load on public
services we do not own.

One HTTP call answers it. `editingInfo.lastEditDate` is already in the metadata
payload that ingest.run fetches first for every source, and it is already
recorded per run in raw.source_field_snapshot. The gate is a comparison between
those two values; there is no new state to maintain.

WHY THE ARGUMENTS MIRROR ingest.run
-----------------------------------
`--county 053` here gates `--county 053` there. The gate and the work it guards
take the same argument, so the DAG cannot drift into checking one source and
ingesting another.

EXIT CODES -- the whole interface
---------------------------------
    0   changed, or freshness cannot be established -> ingest
    99  provably unchanged                          -> skip
    1   error                                       -> fail

Airflow maps 99 to a skipped task via DockerOperator's skip_on_exit_code, and
skips propagate downstream, so an all-unchanged day costs five metadata calls
and nothing else. The code is arbitrary but must not collide with a real
failure, which is why it is not 1 or 2.

BIAS: SKIP ONLY ON PROOF
------------------------
Every uncertain case exits 0. No snapshot table, no prior row for this layer, a
null recorded value, a publisher that does not populate editingInfo -- all mean
"cannot prove it is unchanged", and the safe answer is to do the work. The
failure mode this ordering prevents is silent staleness: a pipeline that skips
because it cannot see, reports success, and publishes last month's numbers.
Redundant work is visible and cheap; a confident wrong answer is neither.

KNOWN GAP
---------
The gate is keyed on the SOURCE, not on whether OUR pipeline succeeded. If
ingest lands cleanly and dbt then fails, the next scheduled run sees an
unchanged source, skips, and does not retry the failure on its own. Two
remedies, both ordinary Airflow: clear the failed task (it reruns from there,
past the gate), or trigger with the `force` param set. Fixing it "properly"
would mean recording pipeline outcomes in the orchestrator and consulting them
here, which is exactly the coupling the DockerOperator boundary exists to
prevent.
"""

from __future__ import annotations

import argparse
import datetime
import logging
import sys

from sqlalchemy import Engine, text

from ingest import arcgis, db
from ingest.load import RAW_SCHEMA
from ingest.manifest import load_manifest

log = logging.getLogger("ingest.freshness")

SNAPSHOT_TABLE = f"{RAW_SCHEMA}.source_field_snapshot"

# Distinct from any exit code a crash or an argparse failure produces.
EXIT_CHANGED = 0
EXIT_UNCHANGED = 99
EXIT_ERROR = 1


def last_ingested_edit(layer_url: str, engine: Engine) -> datetime.datetime | None:
    """The newest publisher edit time we have on record for this layer.

    Keyed on layer_url, not fips: the three statewide layers all snapshot under
    fips '53' and only the URL tells them apart.

    Returns None when the answer is unknown for any reason -- no table, no
    column, no rows for this layer, or only rows written before
    source_last_edit_at existed. Callers treat None as "cannot prove
    unchanged", so every one of those cases ingests.

    Both catalog checks are load-bearing, not defensive noise. A warehouse that
    predates this feature has the table but not the column, and querying it
    would raise UndefinedColumn -- an error, when the correct reading is "no
    evidence yet". The first ingest after the migration populates the column
    and the gate starts working on its own.
    """
    with engine.connect() as connection:
        # to_regclass returns null rather than raising on a missing relation.
        if connection.execute(
            text("select to_regclass(:t)"), {"t": SNAPSHOT_TABLE}
        ).scalar() is None:
            log.info("%s does not exist yet", SNAPSHOT_TABLE)
            return None

        # to_regclass cannot answer this one; the catalog can.
        if not connection.execute(
            text(
                """
                select true
                from information_schema.columns
                where table_schema = :schema
                  and table_name = :table
                  and column_name = 'source_last_edit_at'
                """
            ),
            {"schema": RAW_SCHEMA, "table": "source_field_snapshot"},
        ).scalar():
            log.info(
                "%s has no source_last_edit_at column yet -- it is added by the "
                "next ingest",
                SNAPSHOT_TABLE,
            )
            return None

        return connection.execute(
            text(
                f"""
                select max(source_last_edit_at)
                from {SNAPSHOT_TABLE}
                where layer_url = :url
                """
            ),
            {"url": layer_url},
        ).scalar()


def source_changed(label: str, layer_url: str, engine: Engine) -> bool:
    """True when this layer needs re-ingesting. One HTTP call."""
    metadata = arcgis.fetch_layer_metadata(layer_url)

    if metadata.last_edit_epoch_ms is None:
        log.info("%s: publisher exposes no lastEditDate -- ingesting", label)
        return True

    remote = datetime.datetime.fromtimestamp(
        metadata.last_edit_epoch_ms / 1000, datetime.timezone.utc
    )
    recorded = last_ingested_edit(layer_url, engine)

    if recorded is None:
        log.info(
            "%s: no recorded edit time (published %s) -- ingesting",
            label,
            remote.date(),
        )
        return True

    if remote > recorded:
        log.info(
            "%s: republished %s, last ingested edit %s -- ingesting",
            label,
            remote.isoformat(timespec="seconds"),
            recorded.isoformat(timespec="seconds"),
        )
        return True

    log.info(
        "%s: unchanged since %s -- skipping",
        label,
        recorded.isoformat(timespec="seconds"),
    )
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest.freshness", description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--county", metavar="FIPS", help="single county, e.g. 053")
    target.add_argument("--all", action="store_true", help="every county in the manifest")
    target.add_argument(
        "--state",
        nargs="?",
        const="ALL",
        metavar="LAYER",
        help="the statewide service; no argument checks every layer",
    )

    parser.add_argument(
        "--force",
        action="store_true",
        help="report changed without checking. The escape hatch for reruns "
        "after a downstream failure, and for a first run against a new model.",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)-7s %(message)s",
    )

    if args.force:
        log.info("--force -- skipping the freshness check")
        return EXIT_CHANGED

    manifest = load_manifest()

    # (label, layer_url) pairs, resolved the same way ingest.run resolves them.
    if args.state:
        keys = list(manifest.state.layers) if args.state == "ALL" else [args.state]
        sources = [(f"state:{k}", manifest.state.layer_url(k)) for k in keys]
    else:
        counties = (
            list(manifest.counties.values())
            if args.all
            else [manifest.county(args.county)]
        )
        sources = [(f"{c.fips} {c.name}", c.layer_url) for c in counties]

    engine = db.get_engine()

    # ANY changed layer means ingest, so this could short-circuit -- it
    # deliberately does not. Checking all of them costs one metadata call each
    # and makes the task log say which sources moved, which is the question
    # anyone reads this log to answer.
    changed = [
        label for label, url in sources if source_changed(label, url, engine)
    ]

    if changed:
        log.info("ingesting: %s", ", ".join(changed))
        return EXIT_CHANGED

    log.info("all %d source(s) unchanged", len(sources))
    return EXIT_UNCHANGED


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        # An unreachable service must FAIL, never skip. Both look like "no new
        # data" from a distance and they are opposite conditions.
        log.error("freshness check failed: %s", exc)
        sys.exit(EXIT_ERROR)
