# scripts/export.py — warehouse -> static-site artifacts.
#
# Reads the gold tables through duckdb's postgres extension and writes:
#   exports/parquet/   fct, dim, the three scorecard tables (zstd parquet)
#   exports/csv/       the same tables as CSV (Tableau build input)
#   exports/json/      the three scorecard tables as JSON (static site data)
#   exports/fgb/       bi_findings_extract as FlatGeobuf (tippecanoe input)
#
# Everything here is regenerable from the warehouse; nothing is hand-edited.
# Run via `make export`.

import os
import sys
from pathlib import Path

import duckdb
import geopandas as gpd
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "exports"

TABLES = [
    # (schema, table, export geometry as WKB blob?)
    ("marts", "fct_parcel_reconciliation", False),
    ("marts", "dim_parcel", True),
    ("marts", "agg_quality_scorecard", False),
    ("marts", "agg_scorecard_wide", False),
    ("marts", "agg_quarantine_summary", False),
]

# The three small tables the static site renders client-side.
JSON_TABLES = ["agg_scorecard_wide", "agg_quality_scorecard", "agg_quarantine_summary"]


def main() -> None:
    load_dotenv(ROOT / ".env")

    missing = [k for k in ("WAREHOUSE_HOST", "WAREHOUSE_PORT", "POSTGRES_USER",
                           "POSTGRES_PASSWORD", "POSTGRES_DB") if not os.environ.get(k)]
    if missing:
        sys.exit(f"missing env vars: {', '.join(missing)} (run from the repo, .env present?)")

    conn = duckdb.connect()
    conn.execute("INSTALL postgres; LOAD postgres;")
    dsn = (
        f"host={os.environ['WAREHOUSE_HOST']} port={os.environ['WAREHOUSE_PORT']} "
        f"user={os.environ['POSTGRES_USER']} password={os.environ['POSTGRES_PASSWORD']} "
        f"dbname={os.environ['POSTGRES_DB']}"
    )
    conn.execute(f"ATTACH '{dsn}' AS wh (TYPE postgres);")

    for sub in ("parquet", "csv", "json", "fgb"):
        (OUT / sub).mkdir(parents=True, exist_ok=True)

    # Single-snapshot semantics: a rerun REPLACES the previous snapshot. The
    # four subdirectories are wiped first, so a table dropped or renamed in
    # TABLES cannot leave its stale export behind -- everything here reflects
    # exactly one warehouse state, and any file present after a run was
    # produced by that run.
    import shutil
    for sub in ("parquet", "csv", "json", "fgb"):
        shutil.rmtree(OUT / sub, ignore_errors=True)
        (OUT / sub).mkdir(parents=True, exist_ok=True)

    for schema, table, with_wkb in TABLES:
        qualified = f"wh.{schema}.{table}"
        select = "*"
        if not with_wkb:
            # Internal geometry never leaves the warehouse in the analysis
            # tables; dim keeps its columns for provenance parity with the
            # published contract. Geometry travels only in the bi extract.
            cols = [r[0] for r in conn.execute(
                f"select column_name from wh.information_schema.columns "
                f"where table_schema = '{schema}' and table_name = '{table}' "
                f"and data_type not like 'geometry%' and column_name <> 'geom'"
            ).fetchall()]
            select = ", ".join(cols)

        parquet = OUT / "parquet" / f"{table}.parquet"
        conn.execute(
            f"COPY (SELECT {select} FROM {qualified}) TO '{parquet}' "
            "(FORMAT parquet, COMPRESSION zstd)"
        )
        csv = OUT / "csv" / f"{table}.csv"
        conn.execute(f"COPY (SELECT {select} FROM {qualified}) TO '{csv}' (FORMAT csv, HEADER)")
        print(f"  {table}: {parquet.stat().st_size / 1e6:.1f} MB parquet, "
              f"{csv.stat().st_size / 1e6:.1f} MB csv")

        if table in JSON_TABLES:
            rows = conn.execute(f"SELECT {select} FROM {qualified}").fetchall()
            names = [d[0] for d in conn.execute(
                f"SELECT {select} FROM {qualified} LIMIT 0").description]
            import json
            data = [dict(zip(names, r)) for r in rows]
            jf = OUT / "json" / f"{table}.json"
            jf.write_text(json.dumps(data, default=str, indent=1))
            print(f"  {table}: {jf.stat().st_size / 1e3:.0f} kB json ({len(data)} rows)")

    # FlatGeobuf of the map extract -- tippecanoe's input. bi_findings_extract
    # is ALREADY in WGS84 (the dbt model transforms), and the postgres extension
    # hands PostGIS geometry columns across as WKB blobs, so no spatial
    # functions are needed here: the blob is rehydrated with shapely directly.
    # (st_transform / st_aswkb would fail -- duckdb only knows them via the
    # spatial extension, which this export deliberately does not require.)
    #
    # Findings only, not every parcel. The full 1.5M-record extract produced a
    # 590 MB FlatGeobuf whose tile archive exceeded GitHub's 100 MB file limit,
    # and duplicated a statewide map the state already publishes. See the
    # bi_findings_extract header.
    print("exporting bi_findings_extract -> FlatGeobuf")
    # SELECT * EXCLUDE, not a hand-written column list. The previous version
    # enumerated every column, and adding one to the dbt model without adding
    # it here dropped it silently -- no error, just a property the map never
    # received. It had already happened three times (acres_reported,
    # state_duplicate_id, disagreements) before anyone noticed, and the failure
    # is invisible: the map renders, the popup just quietly says less.
    #
    # The model is now the single source of truth for what the map gets. geom
    # is renamed because it crosses as a WKB blob, not because it is special.
    df = conn.execute(
        "select * exclude (geom), geom as geom_wkb "
        "from wh.marts.bi_findings_extract"
    ).df()
    gdf = gpd.GeoDataFrame(
        df.drop(columns=["geom_wkb"]),
        geometry=gpd.GeoSeries.from_wkb(df["geom_wkb"].map(bytes)),
        crs="EPSG:4326",
    )
    fgb = OUT / "fgb" / "wa_findings.fgb"
    if fgb.exists():
        fgb.unlink()  # GDAL FlatGeobuf overwrite is version-dependent; replace explicitly
    gdf.to_file(fgb, driver="FlatGeobuf")
    print(f"  bi_findings_extract: {fgb.stat().st_size / 1e6:.1f} MB fgb ({len(gdf)} rows)")

    conn.close()


if __name__ == "__main__":
    main()
