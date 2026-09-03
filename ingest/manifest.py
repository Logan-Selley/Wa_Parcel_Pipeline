"""Reads the source manifest.

The manifest lives under `vars:` in parcels/dbt_project.yml so that dbt parses it
natively at compile time and this module reads the exact same bytes. There is no
second copy and no codegen step -- if the two ever disagree, it is a bug here.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

# Resolved from this file rather than the cwd, so the CLI works from anywhere.
REPO_ROOT = Path(__file__).resolve().parent.parent
DBT_PROJECT = REPO_ROOT / "parcels" / "dbt_project.yml"

# Bare SQL literals that are syntactically valid identifiers. Without this,
# a mapping like `is_active: "true"` looks like a reference to a column
# named "true".
SQL_LITERALS = frozenset({"true", "false", "null", "current_timestamp", "current_date"})


@dataclass(frozen=True)
class CountySource:
    """One county's endpoint, CRS, and field mapping."""

    fips: str
    name: str
    service_url: str
    layer_id: int
    source_crs: int
    item_id: str | None = None
    portal_url: str | None = None
    map: dict[str, str | None] = field(default_factory=dict)
    allow_null: dict[str, str] = field(default_factory=dict)
    notes: dict[str, str] = field(default_factory=dict)
    # Source fields never to request, fetch, or store -- owner and taxpayer
    # names and mailing addresses. Enforced at the request level so they never
    # cross the wire; see the manifest entries for the reasoning.
    exclude: list[str] = field(default_factory=list)
    # Consumed by conform_parcels on the dbt side (record identity, A3). The
    # extractor does not use them, but the dataclass must accept them: this
    # file and dbt read the SAME manifest, so any key one side adds must at
    # least parse on the other.
    record_key: dict = field(default_factory=dict)
    identity_exclude: list[str] = field(default_factory=list)

    @property
    def layer_url(self) -> str:
        """The queryable REST endpoint."""
        return f"{self.service_url}/{self.layer_id}"

    @property
    def raw_table(self) -> str:
        """Destination table in the raw schema.

        Must stay in step with macros/conform_parcels.sql, which derives the
        same name as `'parcels_' ~ cfg['name'] | lower`. Changing the rule here
        silently breaks every source() reference on the dbt side.
        """
        return f"parcels_{self.name.lower()}"

    @property
    def excluded_columns(self) -> set[str]:
        """Lowercased names of fields that must never be fetched or stored."""
        return {c.lower() for c in self.exclude}

    def retained_fields(self, published: list[str]) -> list[str]:
        """The published fields minus the exclusions, in published casing.

        Passed to the service as outFields so excluded columns are never
        transmitted. Returns the published names rather than lowercased ones
        because ArcGIS matches its own field casing.
        """
        excluded = self.excluded_columns
        return [f for f in published if f.lower() not in excluded]

    @property
    def source_columns(self) -> set[str]:
        """Columns the manifest expects to exist, lowercased.

        Only bare column references -- entries containing SQL syntax
        (split_part, coalesce, literals) are skipped, since picking identifiers
        out of an arbitrary expression needs a real parser. Enough for a
        first-pass existence check against the field snapshot; not a substitute
        for the drift test on the dbt side.
        """
        out: set[str] = set()
        for expr in self.map.values():
            if expr is None:
                continue
            token = str(expr).strip()
            # isidentifier() is true for bare SQL literals too, so `is_active:
            # "true"` would otherwise be reported as a missing column.
            if token.isidentifier() and token.lower() not in SQL_LITERALS:
                out.add(token.lower())
        return out


@dataclass(frozen=True)
class StateSource:
    name: str
    service_url: str
    source_crs: int
    layers: dict[str, int]
    item_id: str | None = None
    portal_url: str | None = None

    def layer_url(self, key: str) -> str:
        """Resolve a named layer, e.g. 'parcels', 'file_date', 'landuse_lookup'."""
        if key not in self.layers:
            raise KeyError(f"{key!r} not in state_source.layers ({sorted(self.layers)})")
        return f"{self.service_url}/{self.layers[key]}"


@dataclass(frozen=True)
class Manifest:
    target_crs: int
    counties: dict[str, CountySource]
    state: StateSource

    def county(self, fips: str) -> CountySource:
        if fips not in self.counties:
            raise KeyError(f"FIPS {fips!r} not in manifest ({sorted(self.counties)})")
        return self.counties[fips]


def load_manifest(path: Path | None = None) -> Manifest:
    """Parse the manifest out of dbt_project.yml."""
    path = path or DBT_PROJECT
    raw: dict[str, Any] = yaml.safe_load(path.read_text())

    try:
        variables = raw["vars"]
    except KeyError as exc:
        raise ValueError(f"{path} has no top-level 'vars:' block") from exc

    counties = {
        fips: CountySource(fips=fips, **cfg)
        for fips, cfg in variables["counties"].items()
    }
    state = StateSource(**variables["state_source"])
    return Manifest(
        target_crs=variables["target_crs"],
        counties=counties,
        state=state,
    )
