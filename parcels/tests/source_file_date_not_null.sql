-- Every published record must carry the answer key vintage. The reconciliation
-- and both scorecard vintage checks state staleness per county, and a null
-- here would make that gap unmeasurable for the row.
select *
from {{ ref('int_parcels_conformed') }}
where source_file_date is null