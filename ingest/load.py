"""Landing GeoDataFrames into the bronze layer.

Bronze keeps every source field. The only transformations applied here are
lowercasing column names (see normalize_columns) and coercing each column to the
dtype implied by the service's own field metadata (see BronzeLoader).

Pages are streamed one at a time into a staging table and swapped into place at
the end, so memory stays bounded regardless of county size and a failed run
leaves the previous load untouched.
"""

from __future__ import annotations

import datetime
import logging
import re
from pathlib import Path
from typing import TYPE_CHECKING

import geopandas as gpd
from sqlalchemy import text

if TYPE_CHECKING:
    from sqlalchemy import Engine

    from ingest.arcgis import LayerMetadata

log = logging.getLogger(__name__)

RAW_SCHEMA = "raw"
GEOM_COLUMN = "geom"
OID_COLUMN = "objectid"          # fallback only; prefer the service's objectIdField

# Arbitrary application namespace for pg_advisory_lock, so these locks cannot
# collide with anything else using advisory locks on this database.
ADVISORY_LOCK_NAMESPACE = 4919
SWAP_LOCK_TIMEOUT = "30s"

# Esri field type -> PostgreSQL column type.
#
# esriFieldTypeDate maps to bigint, NOT timestamp: ArcGIS serialises dates as
# epoch MILLISECONDS even in GeoJSON output (verified -- Pierce RetiredDate
# comes back as 1485475200000, not an ISO string). Declaring it as a timestamp
# would either fail on insert or silently reinterpret the number. Converting to
# a real timestamp is a transformation, so it belongs in dbt, not in bronze.
ESRI_TO_PG = {
    "esriFieldTypeOID": "integer",
    "esriFieldTypeInteger": "integer",
    "esriFieldTypeBigInteger": "bigint",
    "esriFieldTypeSmallInteger": "smallint",
    "esriFieldTypeDouble": "double precision",
    "esriFieldTypeSingle": "real",
    "esriFieldTypeString": "text",
    "esriFieldTypeDate": "bigint",
    "esriFieldTypeGlobalID": "text",
    "esriFieldTypeGUID": "text",
    "esriFieldTypeXML": "text",
}

# PostgreSQL column type -> pandas dtype used to coerce each page before insert.
# Nullable extension dtypes throughout, because a page where a column happens to
# be entirely null would otherwise be inferred as float64 and inserting NaN into
# an integer or text column fails.
PG_TO_PANDAS = {
    "integer": "Int64",
    "bigint": "Int64",
    "smallint": "Int64",
    "double precision": "Float64",
    "real": "Float64",
    "text": "string",
}

_SAFE_IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]*$")


def normalize_columns(gdf: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    """Lowercase every column name and standardise the geometry column.

    This is a contract with the dbt side, not a preference. The manifest writes
    source fields in their published casing (TaxParcelNumber, ADDR_FULL, SITUSLINE1)
    because that is what the portals show and what makes the mapping reviewable.
    Unquoted SQL identifiers fold to lowercase, so `select TaxParcelNumber` looks
    for `taxparcelnumber`. If a column lands as "TaxParcelNumber" -- created with
    quotes, case preserved -- that lookup fails.

    Lowercasing here is what makes the two agree. Skip it and all three
    mixed-case counties break at once.

    The geometry column is renamed to `geom` for the same reason: conform_parcels
    references it by that name for every county.
    """
    gdf = gdf.rename(columns={c: c.lower() for c in gdf.columns})
    if gdf.geometry.name != GEOM_COLUMN:
        gdf = gdf.rename_geometry(GEOM_COLUMN)
    return gdf


def write_geopackage(
    gdf: gpd.GeoDataFrame, path: Path, layer: str, append: bool = False
) -> None:
    """Persist fetched data to a local GeoPackage.

    Optional, and not on the critical path. Worth having because it is the raw
    landing artifact: a single indexed SQLite file that preserves CRS properly,
    unlike a pile of GeoJSON. It is also the thing that becomes the S3/Blob
    landing zone in v2, so the shape is worth establishing now.

    Args:
        append: False for the first page (creates/overwrites), True thereafter.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    gdf.to_file(path, layer=layer, driver="GPKG", mode="a" if append else "w")


class BronzeLoader:
    """Streams pages into raw.<table>__loading, validates, then swaps into place.

    Used as a context manager. The staging table is created on entry from the
    service's declared field types, appended to page by page, validated as a
    whole, and only then renamed over the live table.

    Two properties this shape buys, both load-bearing:

    * Bounded memory. The caller holds one page at a time; nothing accumulates.
    * Atomicity. raw.<table> is untouched until commit(), so a run that dies at
      page 400 of 637 leaves the previous load fully intact rather than a
      half-populated table that dbt would happily build on.

    The schema is declared explicitly rather than inferred by the first page.
    GeoDataFrame.from_features types each page independently, so a column that
    happens to be entirely null early on (King's sparse PLUS4, for instance)
    would be inferred as float64, and appending later string values into the
    column that created would fail -- 40 minutes into the largest county.
    """

    def __init__(
        self,
        table: str,
        engine: Engine,
        field_types: dict[str, str],
        srid: int,
        oid_column: str = OID_COLUMN,
        exclude: set[str] | None = None,
        has_geometry: bool = True,
    ) -> None:
        self.table = table
        self.staging = f"{table}__loading"
        self.engine = engine
        self.srid = srid
        self.crs = f"EPSG:{srid}"
        self.oid_column = oid_column.lower()
        self.exclude = {c.lower() for c in (exclude or ())}
        # The state service exposes two non-spatial tables alongside its parcel
        # layer (File_Date, the land use lookup). They take the same staging,
        # validation and swap path -- only the geometry column and the write
        # method differ.
        self.has_geometry = has_geometry
        self.rows = 0
        self._committed = False
        self._lock_conn = None

        self.pg_types = self._resolve_types(field_types, self.exclude)
        self.columns = [*self.pg_types, GEOM_COLUMN] if has_geometry else [*self.pg_types]

    @staticmethod
    def _resolve_types(
        field_types: dict[str, str], exclude: set[str]
    ) -> dict[str, str]:
        """Lowercased column name -> PostgreSQL type, minus exclusions.

        Excluded fields are omitted from the DDL entirely, so there is no column
        for them to land in even if a future change started requesting them.
        """
        resolved: dict[str, str] = {}
        skipped: list[str] = []
        for name, esri_type in field_types.items():
            column = name.lower()
            if column in exclude:
                skipped.append(column)
                continue
            if not _SAFE_IDENTIFIER.match(column):
                raise ValueError(
                    f"source field {name!r} is not a safe SQL identifier once "
                    f"lowercased ({column!r}); it needs explicit handling"
                )
            if column in resolved:
                raise ValueError(
                    f"source fields collide when lowercased: {name!r} -> {column!r}"
                )
            pg_type = ESRI_TO_PG.get(esri_type)
            if pg_type is None:
                log.warning(
                    "unmapped Esri type %s on field %s -- landing as text",
                    esri_type,
                    name,
                )
                pg_type = "text"
            resolved[column] = pg_type
        if skipped:
            log.info("excluded %d field(s) from bronze: %s", len(skipped), sorted(skipped))
        return resolved

    def __enter__(self) -> BronzeLoader:
        # Session-scoped advisory lock held for the whole load. Two concurrent
        # runs of the same county would otherwise both create __loading and
        # interleave their appends -- the row count could still come out right
        # while the contents are a mix of two runs. Transaction-scoped locks are
        # not enough here because the load spans many transactions.
        self._lock_conn = self.engine.connect()
        acquired = self._lock_conn.execute(
            text("SELECT pg_try_advisory_lock(:ns, hashtext(:key))"),
            {"ns": ADVISORY_LOCK_NAMESPACE, "key": self.table},
        ).scalar()
        if not acquired:
            self._lock_conn.close()
            self._lock_conn = None
            raise RuntimeError(
                f"another ingest of {self.table} is already running "
                f"(advisory lock held); refusing to run concurrently"
            )

        cols = ",\n    ".join(f'"{c}" {t}' for c, t in self.pg_types.items())
        if self.has_geometry:
            # Generic geometry rather than MultiPolygon: bronze accepts whatever
            # the county publishes, and conform_parcels normalises with ST_Multi.
            ddl = (
                f"CREATE TABLE {RAW_SCHEMA}.{self.staging} (\n    {cols},\n"
                f'    "{GEOM_COLUMN}" geometry(Geometry, {self.srid})\n)'
            )
        else:
            ddl = f"CREATE TABLE {RAW_SCHEMA}.{self.staging} (\n    {cols}\n)"
        with self.engine.begin() as conn:
            conn.execute(text(f"DROP TABLE IF EXISTS {RAW_SCHEMA}.{self.staging}"))
            conn.execute(text(ddl))
        log.info(
            "staging table %s.%s created (%d columns, SRID %d)",
            RAW_SCHEMA,
            self.staging,
            len(self.columns),
            self.srid,
        )
        return self

    def append(self, gdf: gpd.GeoDataFrame) -> int:
        """Coerce one page to the declared schema and insert it."""
        if gdf.empty:
            return 0

        gdf = (
            normalize_columns(gdf)
            if self.has_geometry
            else gdf.rename(columns={c: c.lower() for c in gdf.columns})
        )

        unexpected = set(gdf.columns) - set(self.columns) - self.exclude
        if unexpected:
            # Not fatal for bronze, but it means the service is returning fields
            # its own metadata did not declare -- worth seeing in the log.
            log.warning("dropping undeclared column(s): %s", sorted(unexpected))

        # reindex both drops undeclared columns and inserts declared-but-absent
        # ones as null, so every page presents an identical shape.
        frame = gdf.reindex(columns=self.columns)
        for column, pg_type in self.pg_types.items():
            dtype = PG_TO_PANDAS.get(pg_type)
            if dtype:
                frame[column] = frame[column].astype(dtype)

        if self.has_geometry:
            page = gpd.GeoDataFrame(frame, geometry=GEOM_COLUMN, crs=self.crs)
            page.to_postgis(
                name=self.staging,
                con=self.engine,
                schema=RAW_SCHEMA,
                if_exists="append",
                index=False,
            )
        else:
            page = frame
            page.to_sql(
                name=self.staging,
                con=self.engine,
                schema=RAW_SCHEMA,
                if_exists="append",
                index=False,
            )
        self.rows += len(page)
        return len(page)

    def commit(self, expected_count: int | None = None) -> int:
        """Validate the staging table, then swap it over the live table."""
        oid = self.oid_column
        has_oid = oid in self.pg_types

        with self.engine.begin() as conn:
            # The swap takes an ACCESS EXCLUSIVE lock on the live table. Without
            # a timeout it waits indefinitely behind any open dbt query, and the
            # run appears hung rather than failed.
            conn.execute(text(f"SET LOCAL lock_timeout = '{SWAP_LOCK_TIMEOUT}'"))

            if has_oid:
                stats = conn.execute(
                    text(
                        f"SELECT count(*) AS n,"
                        f' count(DISTINCT "{oid}") AS n_distinct,'
                        f' count(*) FILTER (WHERE "{oid}" IS NULL) AS n_null'
                        f" FROM {RAW_SCHEMA}.{self.staging}"
                    )
                ).mappings().one()
            else:
                log.warning(
                    "%s does not publish %s -- uniqueness cannot be verified",
                    self.table,
                    oid,
                )
                stats = conn.execute(
                    text(f"SELECT count(*) AS n FROM {RAW_SCHEMA}.{self.staging}")
                ).mappings().one()

            n = stats["n"]
            log.info("validating %s.%s -> %s", RAW_SCHEMA, self.staging, dict(stats))

            # An empty result would otherwise pass a 0 == 0 count check and swap
            # an empty table over a good load.
            if n == 0:
                raise ValueError(
                    f"{self.table}: staging table is empty; refusing to swap over "
                    f"the existing load"
                )
            if expected_count is not None and n != expected_count:
                raise ValueError(
                    f"{self.table}: loaded {n} rows but the service reported "
                    f"{expected_count}. Refusing to swap."
                )
            if has_oid:
                if stats["n_distinct"] != n:
                    raise ValueError(
                        f"{self.table}: {n - stats['n_distinct']} duplicate "
                        f"{oid}s -- page offsets overlapped. Refusing to swap."
                    )
                if stats["n_null"]:
                    raise ValueError(
                        f"{self.table}: {stats['n_null']} rows have a null "
                        f"{oid}. Refusing to swap."
                    )

            # CASCADE is required once dbt has run: staging.stg_parcels__<county>
            # is a view over this table, and a plain DROP fails with "other
            # objects depend on it". The views are cheap to rebuild; the table
            # is not.
            conn.execute(
                text(f"DROP TABLE IF EXISTS {RAW_SCHEMA}.{self.table} CASCADE")
            )
            conn.execute(
                text(
                    f"ALTER TABLE {RAW_SCHEMA}.{self.staging} "
                    f"RENAME TO {self.table}"
                )
            )

        self._committed = True
        log.info("committed %s rows into %s.%s", f"{n:,}", RAW_SCHEMA, self.table)
        log.warning(
            "dropped %s.%s CASCADE -- any dependent dbt views were removed; "
            "run `dbt run` to rebuild them",
            RAW_SCHEMA,
            self.table,
        )
        return n

    def _release_lock(self) -> None:
        if self._lock_conn is None:
            return
        try:
            self._lock_conn.execute(
                text("SELECT pg_advisory_unlock(:ns, hashtext(:key))"),
                {"ns": ADVISORY_LOCK_NAMESPACE, "key": self.table},
            )
            self._lock_conn.commit()
        except Exception:  # noqa: BLE001 -- closing the connection frees it anyway
            log.exception("failed to release advisory lock for %s", self.table)
        finally:
            self._lock_conn.close()
            self._lock_conn = None

    def __exit__(self, exc_type, exc, tb) -> None:
        if self._committed:
            self._release_lock()
            return
        # Either the caller raised, or it left without committing. Drop the
        # partial staging table so nothing stale is left behind; the live table
        # was never touched.
        log.warning(
            "load of %s did not commit -- dropping %s.%s",
            self.table,
            RAW_SCHEMA,
            self.staging,
        )
        try:
            with self.engine.begin() as conn:
                conn.execute(
                    text(f"DROP TABLE IF EXISTS {RAW_SCHEMA}.{self.staging} CASCADE")
                )
        except Exception:  # noqa: BLE001 -- never mask the original failure
            log.exception("failed to drop staging table %s", self.staging)
        finally:
            self._release_lock()


def record_domains(
    source_key: str,
    layer_url: str,
    metadata: LayerMetadata,
    engine: Engine,
) -> int:
    """Persist the layer's coded-value domains to raw.source_domains.

    These are published reference data that arrive in the same ?f=json payload as
    the field list. Only the statewide service carries any today, and they are the
    authoritative source for three things nothing else publishes in full:

      * DOR_Land_Use_Codes (83)   -- labels for the normalized land use taxonomy.
        Nothing else describes these; the standalone lookup table describes only
        the per-county codes.
      * County_Name (39)          -- the FIPS -> county-name crosswalk, correctly
        spaced. Repairs both COUNTY_NM holding FIPS digits and the four
        multi-word names that break File_Date.
      * County_Unique_Land_Use_Codes (2,193 across 11 counties) -- a strict
        superset of the published lookup table, which has 1,931 across 10 and
        omits Snohomish entirely.

    Captured per run so drift detection covers them too: a relabelled or newly
    defined DOR code becomes visible rather than silent. captured_at is the run
    key, as in record_field_snapshot.
    """
    if not metadata.domains:
        return 0

    captured_at = datetime.datetime.now(datetime.timezone.utc)
    rows = [
        {
            "source_key": source_key,
            "layer_url": layer_url,
            # lowercased to match the column contract set by normalize_columns
            "field_name": field.lower(),
            "domain_name": spec["domain_name"],
            "code": code,
            "label": label,
            "captured_at": captured_at,
        }
        for field, spec in metadata.domains.items()
        for code, label in spec["coded_values"].items()
    ]

    with engine.begin() as conn:
        conn.execute(
            text(
                f"""
            CREATE TABLE IF NOT EXISTS {RAW_SCHEMA}.source_domains (
                source_key TEXT NOT NULL,
                layer_url TEXT NOT NULL,
                field_name TEXT NOT NULL,
                domain_name TEXT NOT NULL,
                -- text, not int: DOR codes are integers (11) while
                -- county-unique codes are strings ('11-10'). Downstream casts.
                code TEXT NOT NULL,
                label TEXT,
                captured_at TIMESTAMP WITH TIME ZONE NOT NULL
            );
        """
            )
        )
        conn.execute(
            text(
                f"""
            INSERT INTO {RAW_SCHEMA}.source_domains (
                source_key, layer_url, field_name, domain_name, code, label, captured_at
            ) VALUES (
                :source_key, :layer_url, :field_name, :domain_name, :code, :label, :captured_at
            );
        """
            ),
            rows,
        )

    log.info(
        "recorded %d domain value(s) across %d field(s) for %s",
        len(rows),
        len(metadata.domains),
        source_key,
    )
    return len(rows)


def record_field_snapshot(
    fips: str,
    layer_url: str,
    metadata: LayerMetadata,
    engine: Engine,
) -> None:
    """Append this run's observed field list to raw.source_field_snapshot.

    Free at ingest time -- the metadata call has already happened -- and it is
    the input to drift detection on the dbt side. Storing the field list, types,
    CRS and maxRecordCount per run means a county republishing with a renamed
    column turns CI red the next morning instead of producing a confusing
    compile error weeks later.

    captured_at is the run key: every row written by one call shares a single
    timestamp, so drift queries compare runs with `group by captured_at`. Do not
    make it per-row.

    The DDL lives here rather than in docker/initdb/01_init.sql because that
    script only runs on first creation of the volume, so adding it there would
    not reach an existing warehouse.
    """
    snapshot_table = "source_field_snapshot"
    captured_at = datetime.datetime.now(datetime.timezone.utc)

    if not metadata.field_types:
        log.warning("no fields found in metadata snapshot for FIPS %s", fips)
        return

    snapshot_rows = [
        {
            "fips": fips,
            "layer_url": layer_url,
            # Match the lowercase contract set by normalize_columns()
            "field_name": str(field_name).lower(),
            "field_type": str(field_type),
            "crs": f"EPSG:{metadata.native_wkid}" if metadata.native_wkid else "UNKNOWN",
            "max_record_count": metadata.max_record_count,
            "captured_at": captured_at,
        }
        for field_name, field_type in metadata.field_types.items()
    ]

    log.info(
        "recording field snapshot: %d fields for FIPS %s", len(snapshot_rows), fips
    )

    with engine.begin() as connection:
        connection.execute(
            text(
                f"""
            CREATE TABLE IF NOT EXISTS {RAW_SCHEMA}.{snapshot_table} (
                fips VARCHAR(5) NOT NULL,
                layer_url TEXT NOT NULL,
                field_name TEXT NOT NULL,
                field_type TEXT NOT NULL,
                crs TEXT,
                max_record_count INTEGER,
                captured_at TIMESTAMP WITH TIME ZONE NOT NULL
            );
        """
            )
        )
        connection.execute(
            text(
                f"""
            INSERT INTO {RAW_SCHEMA}.{snapshot_table} (
                fips, layer_url, field_name, field_type, crs, max_record_count, captured_at
            ) VALUES (
                :fips, :layer_url, :field_name, :field_type, :crs, :max_record_count, :captured_at
            );
        """
            ),
            snapshot_rows,
        )
