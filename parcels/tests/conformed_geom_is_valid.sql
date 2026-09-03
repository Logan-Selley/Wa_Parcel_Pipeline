-- Stored validity is a hard contract: repair happened upstream, so anything
-- invalid here is a pipeline bug. (The bi extract carries a warn-severity
-- variant instead -- simplification, not repair, is the last transform there.)
select *
from {{ ref('int_parcels_conformed') }}
where not st_IsValid(geom)