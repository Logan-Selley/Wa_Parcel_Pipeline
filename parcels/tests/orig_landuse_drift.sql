-- The crosswalk must stay a function: one state code per (county, county code).
-- A failure here means the state re-normalized a land use code -- source drift,
-- not a bug in this pipeline.
select county_fips, orig_landuse_cd
from {{ ref('int_landuse_crosswalk') }}
group by county_fips, orig_landuse_cd having count(*) > 1