{#  Quarantine roll-up: reason x county, with the registry’s own descriptions.

    Labels come from rejection_rules() rather than being restated here, so the
    registry stays the single source of truth for the CASE in
    int_parcels_validated, the vocabulary test, and this summary.

    A VALUES CTE rather than a CASE expression. A generated CASE is easy to get
    subtly wrong -- putting ELSE inside the {% raw %}{% for %}{% endraw %} loop emits one ELSE per
    rule and fails to parse -- and descriptions are free text that will
    eventually contain an apostrophe, so they need escaping wherever they are
    interpolated. As rows they are joinable data instead of generated syntax.
#}

with labels as (

    select * from (values
        {%- for r in rejection_rules() %}
        ('{{ r.rule_id }}', '{{ r.description | replace("'", "''") }}'){{ "," if not loop.last }}
        {%- endfor %}
    ) as v(rejection_reason, rejection_description)

)

select
    q.county_fips,
    q.county_name,
    q.rejection_reason,
    l.rejection_description,

    count(*)                        as rejected_records,

    {#  Not the same number as rejected_records. A quarantined row is a merged
        record, so it can stand for several source rows -- Spokane’s 2 rejected
        rows represent 3 UNKNOWN source records. Counting rows alone
        under-reports the failures, and this is the figure the A4 canary
        reconciles through. #}
    sum(q.source_record_count)      as rejected_source_rows

from {{ ref('parcels_rejected') }} q
left join labels l using (rejection_reason)
group by 1, 2, 3, 4
order by 1, 3
