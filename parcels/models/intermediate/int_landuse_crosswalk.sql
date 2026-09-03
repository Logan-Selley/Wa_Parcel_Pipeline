{{ config(materialized='table') }}

-- (county, county land use code) -> state DOR code, derived from the answer key
-- itself: wherever the state preserved a county's orig_landuse_cd it also
-- published its normalized landuse_cd, so distinct over that pair is the whole
-- crosswalk. No hand-authored mapping anywhere. tests/orig_landuse_drift.sql
-- guards the grain -- if the state re-normalizes a code, this fails.

select distinct fips_nr as county_fips, orig_landuse_cd, landuse_cd
from {{ source('raw', 'state_parcels') }}
where orig_landuse_cd is not null and landuse_cd is not null