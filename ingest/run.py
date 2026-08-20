"""CLI entry point.

    python -m ingest.run --list
    python -m ingest.run --county 053
    python -m ingest.run --all --cache-gpkg data/raw

Deliberately runnable standalone. Airflow, when it arrives, invokes this via
BashOperator from its own container -- it never imports this package, and this
package never knows Airflow exists. Same separation the dbt side already has.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from ingest import arcgis
from ingest import load
from ingest import db
from ingest.manifest import CountySource, StateSource, load_manifest
import geopandas as gpd
import pandas as pd
from sqlalchemy import Engine

log = logging.getLogger("ingest")


def ingest_county(
    county: CountySource,
    engine: Engine,
    cache_dir: Path | None = None,
    dry_run: bool = False,
    where: str = "1=1",
) -> None:
    """Fetch one county and land it in bronze.

    The metadata call comes first for three reasons: it supplies maxRecordCount
    (which differs per county), it proves the declared CRS is real before any
    data moves, and it is the field snapshot that feeds drift detection.

    Pages stream straight into the loader rather than accumulating. Building one
    GeoDataFrame from every page would hold King's 636k features -- 69 fields
    plus polygon coordinates, as Python dicts -- in memory at once, undoing the
    bounded window iter_feature_pages maintains upstream.
    """
    log.info("[%s] %s -- %s", county.fips, county.name, county.layer_url)

    metadata = arcgis.fetch_layer_metadata(county.layer_url)
    arcgis.assert_crs(
        declared_crs=county.source_crs,
        observed_wkid=metadata.native_wkid,
        context=f"{county.name} ({county.fips})",
    )

    # Counted with the same predicate the fetch will use, so expected_count
    # stays meaningful when --where narrows the run.
    total = arcgis.feature_count(county.layer_url, where)
    log.info(
        "[%s] %s features | EPSG:%s | page size %s | %s fields | extract=%s",
        county.fips,
        f"{total:,}",
        metadata.native_wkid,
        metadata.max_record_count,
        len(metadata.field_names),
        metadata.supports_extract,
    )

    missing = county.source_columns - {f.lower() for f in metadata.field_names}
    if missing:
        raise arcgis.ArcGISError(
            f"{county.name}: manifest maps column(s) {sorted(missing)} that the "
            f"service does not publish. Check for a typo or a renamed field."
        )

    if dry_run:
        log.info("[%s] dry run -- stopping before fetch", county.fips)
        return

    gpkg_path = cache_dir / f"{county.raw_table}.gpkg" if cache_dir else None
    pages = 0

    # Excluded fields are dropped from the request itself, so owner and taxpayer
    # data is never transmitted, never written to bronze, and never reaches the
    # GeoPackage cache. Dropping them after arrival would be weaker.
    retained = county.retained_fields(metadata.field_names)
    if county.exclude:
        log.info(
            "[%s] excluding %d field(s) from the request: %s",
            county.fips,
            len(metadata.field_names) - len(retained),
            ", ".join(sorted(county.excluded_columns)),
        )

    with load.BronzeLoader(
        table=county.raw_table,
        engine=engine,
        field_types=metadata.field_types,
        srid=county.source_crs,
        oid_column=metadata.oid_field,
        exclude=county.excluded_columns,
    ) as loader:
        for page in arcgis.iter_feature_pages(
            layer_url=county.layer_url,
            out_sr=county.source_crs,
            page_size=metadata.max_record_count,
            where=where,
            order_by=metadata.oid_field,
            out_fields=",".join(retained),
        ):
            gdf = gpd.GeoDataFrame.from_features(
                page["features"], crs=f"EPSG:{county.source_crs}"
            )
            loader.append(gdf)
            if gpkg_path:
                load.write_geopackage(
                    gdf, gpkg_path, county.raw_table, append=pages > 0
                )
            pages += 1
            if pages % 25 == 0:
                log.info("[%s] %s rows so far", county.fips, f"{loader.rows:,}")

        n = loader.commit(expected_count=total)

    log.info("[%s] landed %s rows from %d pages", county.fips, f"{n:,}", pages)
    load.record_field_snapshot(county.fips, county.layer_url, metadata, engine)
    load.record_domains(county.fips, county.layer_url, metadata, engine)

def ingest_state_layer(
    state: StateSource,
    key: str,
    engine: Engine,
    dry_run: bool = False,
    where: str = "1=1",
) -> None:
    """Fetch one layer or table from the statewide service into raw.state_<key>.

    Reuses the county path entirely. The only branch is spatial vs not: layer 0
    is 3.3M parcels, while File_Date and the land use lookup are plain tables
    with no geometry, so they are requested as esri json and written with to_sql
    rather than to_postgis. Staging, validation and the atomic swap are identical.
    """
    layer_url = state.layer_url(key)
    table = f"state_{key}"
    log.info("[state] %s -- %s", key, layer_url)

    metadata = arcgis.fetch_layer_metadata(layer_url)
    spatial = bool(metadata.geometry_type)

    if spatial:
        arcgis.assert_crs(
            declared_crs=state.source_crs,
            observed_wkid=metadata.native_wkid,
            context=f"state:{key}",
        )

    total = arcgis.feature_count(layer_url, where)
    log.info(
        "[state] %s: %s rows | %s | %s fields | page size %s",
        key,
        f"{total:,}",
        f"EPSG:{metadata.native_wkid}" if spatial else "non-spatial table",
        len(metadata.field_names),
        metadata.max_record_count,
    )

    if dry_run:
        log.info("[state] %s: dry run -- stopping before fetch", key)
        return

    with load.BronzeLoader(
        table=table,
        engine=engine,
        field_types=metadata.field_types,
        srid=state.source_crs,
        oid_column=metadata.oid_field,
        has_geometry=spatial,
    ) as loader:
        for page in arcgis.iter_feature_pages(
            layer_url=layer_url,
            out_sr=state.source_crs,
            page_size=metadata.max_record_count,
            where=where,
            order_by=metadata.oid_field,
            spatial=spatial,
        ):
            if spatial:
                frame = gpd.GeoDataFrame.from_features(
                    page["features"], crs=f"EPSG:{state.source_crs}"
                )
            else:
                # Esri json wraps each row's columns in "attributes"; there is no
                # geometry to decode.
                frame = pd.DataFrame(
                    [f["attributes"] for f in page.get("features", [])]
                )
            loader.append(frame)
            if loader.rows and loader.rows % 100_000 < metadata.max_record_count:
                log.info("[state] %s: %s rows so far", key, f"{loader.rows:,}")

        n = loader.commit(expected_count=total)

    log.info("[state] %s: landed %s rows into raw.%s", key, f"{n:,}", table)
    # "53" is Washington's own FIPS. The snapshot's fips column is VARCHAR(5),
    # and layer_url already distinguishes the three state layers from each other.
    load.record_field_snapshot("53", layer_url, metadata, engine)
    load.record_domains("53", layer_url, metadata, engine)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest.run", description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--county", metavar="FIPS", help="single county, e.g. 053")
    target.add_argument("--all", action="store_true", help="every county in the manifest")
    target.add_argument("--list", action="store_true", help="show the manifest and exit")
    target.add_argument(
        "--state",
        nargs="?",
        const="ALL",
        metavar="LAYER",
        help="ingest the statewide reference service -- the reconciliation answer "
        "key. No argument fetches all of it (parcels, file_date, landuse_lookup); "
        "pass a layer name for just one.",
    )

    parser.add_argument(
        "--cache-gpkg",
        metavar="DIR",
        type=Path,
        help="also write a GeoPackage per county (the raw landing artifact; "
        "data/ is gitignored)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="probe metadata and validate the manifest without fetching features",
    )
    parser.add_argument(
        "--where",
        default="1=1",
        metavar="SQL",
        help="ArcGIS where clause, for development against a subset "
        '(e.g. "OBJECTID <= 5000"). The row count is taken with the same '
        "predicate, so the integrity check stays meaningful.",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)-7s %(message)s",
    )

    manifest = load_manifest()

    if args.list:
        print(f"target CRS : EPSG:{manifest.target_crs}")
        print(f"state      : {manifest.state.name}")
        for key in manifest.state.layers:
            print(f"             {key:16} {manifest.state.layer_url(key)}")
        print("counties   :")
        for fips, county in sorted(manifest.counties.items()):
            print(
                f"             {fips}  {county.name:11} EPSG:{county.source_crs}  "
                f"-> raw.{county.raw_table}"
            )
        return 0

    engine = db.get_engine()
    failed: list[str] = []

    if args.state:
        keys = (
            list(manifest.state.layers)
            if args.state == "ALL"
            else [args.state]
        )
        for key in keys:
            try:
                ingest_state_layer(
                    manifest.state, key, engine,
                    dry_run=args.dry_run, where=args.where,
                )
            except Exception as exc:  # noqa: BLE001 -- one layer must not stop the rest
                log.error("[state] %s FAILED: %s", key, exc)
                failed.append(f"state:{key}")
        if failed:
            log.error("failed: %s", ", ".join(failed))
            return 1
        return 0

    counties = (
        list(manifest.counties.values())
        if args.all
        else [manifest.county(args.county)]
    )

    for county in counties:
        try:
            ingest_county(
                county,
                engine=engine,
                cache_dir=args.cache_gpkg,
                dry_run=args.dry_run,
                where=args.where,
            )
        except Exception as exc:  # noqa: BLE001 -- one county must not stop the rest
            log.error("[%s] FAILED: %s", county.fips, exc)
            failed.append(county.fips)

    if failed:
        log.error("failed: %s", ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
