{{ config(materialized='table') }}

WITH repaired as (
SELECT *,
    {# Whether the SOURCE supplied no geometry, evaluated before repair. Kept as
       its own column so a parcel the county never gave geometry for stays
       distinguishable from one whose geometry repair destroyed -- ST_MakeValid
       can return a collection with no polygon component, and
       ST_CollectionExtract then yields MULTIPOLYGON EMPTY. Those are different
       findings and get different rejection reasons. #}
    (geom IS NULL OR ST_IsEmpty(geom)) as source_geom_missing,
CASE WHEN geometry_valid then geom
        ELSE  ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
    END as geom_fixed
FROM {{ ref('stg_parcels') }}
)
SELECT
    record_key_uid,record_signature,
    parcel_uid,county_fips,county_name,parcel_id,parcel_id_raw,is_active,is_stacked,situs_address,sub_address,situs_city,
    situs_zip5,situs_zip4,landuse_code_source,landuse_desc_source,value_land_appraised,value_bldg_appraised,value_basis,
    acres_reported,source_layer_url,source_crs,ingested_at,
    source_geom_missing,
    geom_fixed as geom,
    COALESCE(ST_IsValid(geom_fixed), false) as geometry_valid,
    {# r.geometry_valid, not the alias two lines up: Postgres does not expose
       select-list aliases to sibling expressions, so this resolves to the
       PRE-repair validity from stg_parcels -- which is the intended meaning
       ("we attempted a repair"). Qualifying it makes that explicit rather than
       load-bearing accident. #}
    COALESCE(NOT r.geometry_valid, false) as geometry_repaired
FROM repaired r
