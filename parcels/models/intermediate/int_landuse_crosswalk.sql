{{ config(materialized='table') }}

select distinct fips_nr as county_fips, orig_landuse_cd, landuse_cd
from {{ source('raw', 'state_parcels') }}
where orig_landuse_cd is not null and landuse_cd is not null