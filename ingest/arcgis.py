"""ArcGIS REST Feature Service client.

Two responsibilities: describe a layer, and page through its features.

Metadata discovery is not an optimisation here -- it is how the pipeline learns
maxRecordCount (which differs per county) and how it proves the CRS it received
is the CRS the manifest claims. Both are correctness concerns, not conveniences.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Any, Iterator

import json
import logging
import requests
import time
from concurrent.futures import FIRST_COMPLETED,wait,ThreadPoolExecutor
import itertools

log = logging.getLogger(__name__)

USER_AGENT = "parcel-pipeline/0.1 (+https://github.com/Logan-Selley)"
TIMEOUT = 90
MAX_RETRIES = 3
BACKOFF_FACTOR = 2
MAX_WORKERS = 4

# Worth retrying: the server is overloaded or briefly unavailable. Everything
# else in the 4xx range is deterministic -- a malformed where clause or a bad
# field name will fail identically three more times.
TRANSIENT_STATUS_CODES = {429, 500, 502, 503, 504}


class ArcGISError(RuntimeError):
    """A service returned something the pipeline cannot safely proceed on."""


class _TransientPayloadError(Exception):
    """Internal: an in-body ArcGIS error worth retrying.

    ArcGIS reports query failures as HTTP 200 with an {"error": ...} body. Most
    are deterministic -- a bad field or an invalid parameter -- and naming them
    in `details` is how the service says so:

        "'Invalid field: NO_SUCH_COLUMN' parameter is invalid"
        "'outFields' parameter is invalid"

    But under load the same service returns a GENERIC failure with no parameter
    named:

        "Unable to perform query. Please check your parameters."

    That one is transient. Verified during a full statewide load: offset
    2,632,000 failed this way after 70 minutes of successful paging, and the
    identical request returned 2,000 features when replayed moments later.
    Treating it as permanent discards the whole run for a momentary blip.
    """


def _is_transient_payload_error(err: dict[str, Any]) -> bool:
    """True when an in-body error looks like load rather than a bad request."""
    details = " ".join(err.get("details") or []).lower()
    if "parameter is invalid" in details or "invalid field" in details:
        return False
    return "unable to perform query" in details or not details


@dataclass(frozen=True)
class LayerMetadata:
    """The self-description of a Feature Service layer."""

    name: str
    geometry_type: str
    max_record_count: int
    supports_pagination: bool
    capabilities: str
    native_wkid: int
    field_names: list[str]
    field_types: dict[str, str]
    # The service names its own row identifier. All four WA counties currently
    # say OBJECTID, but it is not guaranteed -- FID and OBJECTID_1 both occur in
    # the wild. Assuming it would break deterministic paging, not just the
    # uniqueness check.
    oid_field: str
    # The publisher's own last-edit date, epoch ms, from editingInfo. This is
    # the county's analogue of the state's File_Date: when the SOURCE was last
    # published, not when we happened to fetch it. Using ingest time as a proxy
    # would make any staleness metric a function of our run schedule rather
    # than a property of the data.
    last_edit_epoch_ms: int | None
    # Coded-value domains, keyed by field name:
    #   {field: {"domain_name": str, "coded_values": {code: label}}}
    #
    # These are the published reference data for the layer and are easy to miss --
    # they arrive in the same ?f=json payload as the field list, so the pipeline
    # was already fetching and discarding them. The statewide service carries
    # three that nothing else publishes in full: DOR land use labels, the FIPS ->
    # county-name crosswalk, and county-unique land use descriptions covering
    # more counties than the standalone lookup table does.
    domains: dict[str, dict[str, Any]]

    @property
    def supports_extract(self) -> bool:
        return "Extract" in self.capabilities


def _get_with_retry(url: str, params: dict[str, Any], session: Optional[requests.Session] = None) -> dict[str, Any]:
    """Wraps the core request logic with retries and exponential backoff"""
    params = {"f": "json", **params}
    owns = session is None
    sess = session or requests.Session()

    try:
        for attempt in range(MAX_RETRIES + 1):
            try:
                response = sess.get(
                    url, params=params, timeout=TIMEOUT, headers={"User-Agent": USER_AGENT}
                )
                response.raise_for_status()
                payload = response.json()

                if "error" in payload:
                    err = payload["error"]
                    if _is_transient_payload_error(err):
                        raise _TransientPayloadError(f"{url} -> {err}")
                    raise ArcGISError(f"{url} -> {err}")
                return payload
            except requests.exceptions.HTTPError as e:
                status_code = e.response.status_code if e.response is not None else 0
                if status_code not in TRANSIENT_STATUS_CODES:
                    raise ArcGISError(f"Permanent HTTP Client Error {status_code}: {e}") from e
                if attempt == MAX_RETRIES:
                    raise ArcGISError(f"HTTP Error {status_code} persisted after {MAX_RETRIES} retries.") from e
                    
            except (
                requests.exceptions.ConnectionError,
                requests.exceptions.Timeout,
                # A body that will not parse is transient too: ArcGIS serves
                # truncated payloads and HTML error pages -- with a 200 status --
                # while under load. JSONDecodeError subclasses RequestException
                # but is neither an HTTPError nor a Timeout, so without naming it
                # here it would fall to the catch-all and never be retried.
                requests.exceptions.JSONDecodeError,
                # Generic in-body failures -- see _TransientPayloadError.
                _TransientPayloadError,
            ) as e:
                if attempt == MAX_RETRIES:
                    raise ArcGISError(f"Transient failure persisted after {MAX_RETRIES} retries. Error: {e}") from e
                log.warning("transient failure (attempt %d/%d): %s", attempt + 1, MAX_RETRIES, e)

            except requests.exceptions.RequestException as e:
                # Anything else: not obviously transient, so fail rather than retry blind.
                raise ArcGISError(f"Unrecoverable request anomaly encountered: {e}") from e

            sleep_time = BACKOFF_FACTOR ** (attempt + 1)
            time.sleep(sleep_time)

        # Unreachable: the final attempt always returns or raises. Present so the
        # declared return type holds without an implicit None path.
        raise ArcGISError(f"{url}: retry loop exhausted without a result")
    finally:
        if owns:
            sess.close()


def fetch_layer_metadata(layer_url: str) -> LayerMetadata:
    """Read a layer's self-description."""
    payload = _get_with_retry(layer_url, {})
    fields = payload.get("fields") or []
    extent_sr = payload.get("extent", {}).get("spatialReference", {})

    return LayerMetadata(
        name=payload.get("name", ""),
        geometry_type=payload.get("geometryType", ""),
        max_record_count=int(payload.get("maxRecordCount", 1000)),
        supports_pagination=bool(
            payload.get("advancedQueryCapabilities", {}).get("supportsPagination")
        ),
        capabilities=payload.get("capabilities", ""),
        native_wkid=int(extent_sr.get("latestWkid") or extent_sr.get("wkid") or 0),
        field_names=[f["name"] for f in fields],
        field_types={f["name"]: f["type"] for f in fields},
        oid_field=payload.get("objectIdField") or "OBJECTID",
        last_edit_epoch_ms=(payload.get("editingInfo") or {}).get("lastEditDate"),
        domains={
            f["name"]: {
                "domain_name": (f.get("domain") or {}).get("name") or "",
                # Codes may be int (DOR: 11) or str (county-unique: '11-10').
                # Normalised to str here so one column can hold both.
                "coded_values": {
                    str(c["code"]): c["name"]
                    for c in ((f.get("domain") or {}).get("codedValues") or [])
                },
            }
            for f in fields
            # `or {}` not `.get(..., {})`: the key is present with a null value
            # on undomained fields, so the default would never fire.
            if (f.get("domain") or {}).get("codedValues")
        },
    )


def feature_count(layer_url: str, where: str = "1=1") -> int:
    """Total features matching `where`. Use to verify a load landed completely."""
    payload = _get_with_retry(f"{layer_url}/query", {"where": where, "returnCountOnly": "true"})
    if "count" not in payload:
        raise ArcGISError(f"{layer_url}/query returned no count: {sorted(payload)}")
    return int(payload["count"])


def assert_crs(declared_crs: int, observed_wkid: int, context: str) -> None:
    """Fail loudly when a service's CRS is not what the manifest claims.

    This guards the most expensive silent failure in the pipeline. The dbt macro
    calls st_setsrid(geom, <manifest source_crs>) -- and st_setsrid RELABELS
    without reprojecting. So if a source quietly starts returning WGS84 while the
    manifest still says 2926, the geometry is stamped 2926, transformed from the
    wrong datum, and lands as plausible-looking garbage that raises no error and
    fails no test.

    Nothing downstream can detect this. It has to be caught here.
    """
    if observed_wkid and observed_wkid != declared_crs:
        raise ArcGISError(
            f"{context}: manifest declares EPSG:{declared_crs} but the service "
            f"returned EPSG:{observed_wkid}. Refusing to load -- st_setsrid would "
            f"mislabel this geometry rather than reproject it. Reconcile the "
            f"manifest against the source before re-running."
        )


def fetch_page_worker(session:requests.Session, layer_url: str, params: dict[str, Any]) -> dict[str, Any]:
    """Worker task that handles a single page payload query.

    The response format is set by the caller in base_params -- geojson for
    spatial layers, esri json for tables, which have no geometry to encode.
    """
    return _get_with_retry(f"{layer_url}/query", params, session=session)

def oid_bounds(layer_url: str, oid_field: str, where: str = "1=1") -> tuple[int, int]:
    """Min and max OBJECTID matching `where`, for keyset paging."""
    stats = json.dumps([
        {"statisticType": "min", "onStatisticField": oid_field, "outStatisticFieldName": "lo"},
        {"statisticType": "max", "onStatisticField": oid_field, "outStatisticFieldName": "hi"},
    ])
    payload = _get_with_retry(
        f"{layer_url}/query",
        {"where": where, "outStatistics": stats, "returnGeometry": "false"},
    )
    feats = payload.get("features") or []
    if not feats:
        raise ArcGISError(f"{layer_url}: no {oid_field} bounds for where={where!r}")
    a = feats[0]["attributes"]
    return int(a["lo"]), int(a["hi"])


def iter_feature_pages(
    layer_url: str,
    out_sr: int,
    page_size: int,
    where: str = "1=1",
    order_by: str = "OBJECTID",
    out_fields: str = "*",
    spatial: bool = True,
) -> Iterator[dict[str, Any]]:
    """Yield pages until the layer is exhausted, using keyset pagination.

    Pages are OBJECTID RANGES, not resultOffset windows. Offset paging makes the
    service skip N rows to reach the window, so cost grows with depth: measured
    against the statewide layer at offset 2,980,000, an offset query took 32.51s
    while the equivalent OBJECTID-range query took 1.13s -- 29x. With four
    workers issuing deep offset queries concurrently, the service began returning
    generic "Unable to perform query" errors, and a full statewide load failed
    twice around 2.6-3.0M rows. Ranges are index lookups and do not degrade.

    Two correctness properties fall out of this, both of which offset paging
    lacked:

    * A range CANNOT be silently truncated. OBJECTIDs are unique, so a window of
      width `page_size` contains at most `page_size` rows -- never more than
      maxRecordCount, so the server never has cause to trim it. Offset paging
      had the opposite risk: request 2000 from a service capped at 1000 and you
      get 1000 back with no error, and an offset advanced by 2000 skips half the
      layer.
    * Coverage is total by construction. Disjoint ranges tiling [min, max]
      account for every row whether or not OBJECTIDs are contiguous; gaps simply
      yield short pages, which is expected rather than a fault.

    The total-count check at the end remains the guard that both hold.
    """
    total_features = feature_count(layer_url, where)
    if total_features == 0:
        return

    lo, hi = oid_bounds(layer_url, order_by, where)
    windows = [(a, min(a + page_size, hi + 1)) for a in range(lo, hi + 1, page_size)]
    log.info(
        "%s: %s rows across OBJECTID %s..%s in %d windows of %s",
        layer_url.rsplit("/", 3)[-3], f"{total_features:,}", f"{lo:,}", f"{hi:,}",
        len(windows), f"{page_size:,}",
    )

    base_params = {
        "outFields": out_fields,
        # Ordering is not required for correctness now that windows are disjoint,
        # but it keeps row order stable within a page.
        "orderByFields": order_by,
    }
    if spatial:
        # geojson with an explicit outSR. Without outSR the service silently
        # returns WGS84 regardless of native CRS -- see assert_crs().
        base_params["f"] = "geojson"
        base_params["outSR"] = out_sr
    else:
        # Tables have no geometry; esri json returns plain attribute rows.
        base_params["f"] = "json"

    def window_params(bounds: tuple[int, int]) -> dict[str, Any]:
        a, b = bounds
        return {
            **base_params,
            "where": f"({where}) AND {order_by} >= {a} AND {order_by} < {b}",
        }

    actual_feature_count = 0
    with requests.Session() as shared_session:
        pending = iter(windows)
        in_flight: dict[Any, tuple[int, int]] = {}
        with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            for w in itertools.islice(pending, MAX_WORKERS * 2):
                in_flight[executor.submit(
                    fetch_page_worker, shared_session, layer_url, window_params(w)
                )] = w
            while in_flight:
                done, _ = wait(in_flight, return_when=FIRST_COMPLETED)
                for future in done:
                    w = in_flight.pop(future)
                    try:
                        payload = future.result()
                    except Exception as e:
                        raise ArcGISError(
                            f"failed harvesting OBJECTID window {w[0]}..{w[1]}: {e}"
                        ) from e

                    features = payload.get("features") or []
                    actual_feature_count += len(features)
                    if features:
                        yield payload

                    nxt = next(pending, None)
                    if nxt is not None:
                        in_flight[executor.submit(
                            fetch_page_worker, shared_session, layer_url, window_params(nxt)
                        )] = nxt

    if actual_feature_count != total_features:
        raise ArcGISError(
            f"feature count mismatch: the service reported {total_features} features "
            f"but {actual_feature_count} arrived in the pages. Refusing to land a "
            f"partial load -- re-run the ingest."
        )
