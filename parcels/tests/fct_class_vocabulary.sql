{#  Class vocabulary: the fact publishes exactly four reconciliation
    classes. Two guards make this more than a vocabulary check:

      * 'impossible' is the full-outer-join guard -- its presence would mean
        a row matched on both sides' absence, i.e. the join key collapsed.
      * 'theirs_unidentified' is deliberately ABSENT: the 4,587 state rows
        with no PARCEL_ID_NR never enter the fact (they are filtered in
        stg_state_parcels and counted in agg_quality_scorecard's
        state_unidentified check instead). One appearing here would mean a
        null uid leaked into the join.

    Both would also fail accepted_values in models/marts/schema.yml -- this
    singular test exists so the failures carry their explanation. #}

select reconciliation_class, count(*) as rows
from {{ ref('fct_parcel_reconciliation') }}
where reconciliation_class not in ('both_match', 'both_differ', 'ours_only', 'theirs_only')
group by 1
