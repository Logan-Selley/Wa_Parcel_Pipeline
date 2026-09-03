-- The quarantine: every validated row carrying a rejection reason, kept with
-- full source metadata rather than dropped. The row_counts_match canary
-- balances this side against conformed through source_record_count.
select *
from {{ ref('int_parcels_validated') }}
where rejection_reason is not null