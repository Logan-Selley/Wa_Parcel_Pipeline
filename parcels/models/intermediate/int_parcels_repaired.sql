{{ config(materialized='table') }}

SELECT
    parcel_uid,county_fips,county_name,parcel_id,parcel_id_raw,is_active,situs_address,sub_address,situs_city,
    situs_zip5,situs_zip4,landuse_code_source,landuse_desc_source,value_land_appraised,value_bldg_appraised,value_basis,
    acres_reported,source_layer_url,source_crs,ingested_at,
    CASE WHEN geometry_valid then geom
        ELSE  ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
    END as geom,
    COALESCE(ST_IsValid(CASE WHEN geometry_valid then geom
                            ELSE  ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
                    END), false) as geometry_valid,
    NOT geometry_valid as geometry_repaired
FROM {{ ref('stg_parcels') }}