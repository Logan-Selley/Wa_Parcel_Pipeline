{{ config(materialized='table') }}

WITH repaired as (
SELECT *,
CASE WHEN geometry_valid then geom
        ELSE  ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
    END as geom_fixed
FROM {{ ref('stg_parcels') }}
)
SELECT
    parcel_uid,county_fips,county_name,parcel_id,parcel_id_raw,is_active,situs_address,sub_address,situs_city,
    situs_zip5,situs_zip4,landuse_code_source,landuse_desc_source,value_land_appraised,value_bldg_appraised,value_basis,
    acres_reported,source_layer_url,source_crs,ingested_at,
    geom_fixed as geom,
    COALESCE(ST_IsValid(geom_fixed), false) as geometry_valid,
    COALESCE(NOT geometry_valid, false) as geometry_repaired
FROM repaired