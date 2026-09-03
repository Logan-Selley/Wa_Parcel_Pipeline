{#  Parcel-grain reconciliation. Both sides aggregate to parcel_uid first:
    measured on Pierce, sum-to-sum tracks (corr 0.9548, 72% within 5%) --
    the symmetric-aggregation shape is validated, and the residual deltas
    are the findings this table exists to publish. #}

{%- set fields = comparable_fields() -%}

with ours as (

    select
        parcel_uid,
        {%- for f in fields %}
        {{ field_agg(f, f.ours) }}              as {{ f.field }},
        {%- if f.agg == 'mode' %}
        count(distinct {{ f.ours }})            as {{ f.field }}_variants,
        {%- endif %}
        {%- endfor %}
        count(*)                                as ours_records,
        min(county_fips)                        as county_fips,
        {#  Carried for provenance only -- the vintage gap is measured between
            the two SOURCES’ publish dates, not against our run time. See the
            `dated` CTE.

            Historical note: this was briefly source_file_date. Our source_file_date IS the
            state’s File_Date -- int_parcels_validated joins int_county_vintage
            to populate it -- so differencing the two sides’ file dates
            compares the table to itself and yields a constant zero for every
            parcel. Verified: all four counties match exactly (033 2026-02-26,
            053 2026-02-13, 061 2026-01-21, 063 2026-03-20).

            The meaningful question is how stale the ANSWER KEY is relative to
            the county data we pulled directly, so the gap is measured against
            our ingest timestamp. #}
        max(ingested_at)                        as our_ingested_at
    from {{ ref('dim_parcel') }}
    where parcel_uid is not null
    group by parcel_uid

),

theirs as (

    select
        parcel_uid,
        {%- for f in fields %}
        {{ field_agg(f, f.theirs) }}            as {{ f.field }},
        {%- if f.agg == 'mode' %}
        count(distinct {{ f.theirs }})          as {{ f.field }}_variants,
        {%- endif %}
        {%- endfor %}
        count(*)                                as theirs_records,
        min(county_fips)                        as county_fips
    from {{ ref('stg_state_parcels') }}
    where parcel_uid is not null
    group by parcel_uid

),

paired as (

    select
        coalesce(o.parcel_uid, t.parcel_uid)    as parcel_uid,
        (o.parcel_uid is null)                  as ours_absent,
        (t.parcel_uid is null)                  as theirs_absent,
        o.ours_records,
        t.theirs_records,
        coalesce(o.county_fips, t.county_fips)  as county_fips,
        {%- for f in fields %}
        o.{{ f.field }}                         as ours_{{ f.field }},
        t.{{ f.field }}                         as theirs_{{ f.field }},
        {%- if f.agg == 'mode' %}
        {#  The companion count the registry promises: min() picks one
            representative, so without these "we hold one address, they hold
            three" would be invisible. A parcel with variants > 1 on either
            side is multi-valued, and its status compares representatives
            rather than sets. #}
        o.{{ f.field }}_variants                as ours_{{ f.field }}_variants,
        t.{{ f.field }}_variants                as theirs_{{ f.field }}_variants,
        {%- endif %}
        {{ field_status(f) }}                   as {{ f.field }}_status,
        {%- endfor %}
        o.our_ingested_at
    from ours o
    full outer join theirs t
        on o.parcel_uid = t.parcel_uid

),

dated as (

    {#  The state publishes vintage per COUNTY, in the File_Date table -- not
        per parcel -- so this is a join, not an aggregate. int_county_vintage
        resolves it for all 39 counties, including the four whose COUNTY_NM
        holds a bare name rather than a FIPS code (design.md defect 7). #}
    select
        p.*,
        {#  The state’s own per-county File_Date. #}
        sv.source_file_date                     as state_published_at,
        {#  The county’s own editingInfo.lastEditDate. #}
        cv.source_published_at                  as county_published_at,
        {#  How far behind the county the ANSWER KEY is -- a property of the two
            sources, stable regardless of when we run. Measuring against
            our_ingested_at instead would grow this by a day every day without
            the data changing. #}
        (cv.source_published_at - sv.source_file_date) as vintage_gap_days
    from paired p
    left join {{ ref('int_county_vintage') }} sv
        on sv.county_fips = p.county_fips
    left join {{ ref('int_source_vintage') }} cv
        on cv.county_fips = p.county_fips

)

select
    *,
    case
        when ours_absent and theirs_absent then 'impossible'
        when ours_absent                   then 'theirs_only'
        when theirs_absent                 then 'ours_only'
        {#  classifying_fields(), not fields: assessed values are expected to
            differ against a 166-216 day stale answer key, so including them
            would mark nearly every parcel both_differ and hide the
            differences that are real findings. They are reported separately
            below. #}
        when 'disagree' in (
            {%- for f in classifying_fields() %}
            {{ f.field }}_status{{ ", " if not loop.last }}
            {%- endfor %}
        ) then 'both_differ'
        else 'both_match'
    end                                     as reconciliation_class,

    {#  Expected-drift disagreement, kept visible rather than suppressed. #}
    ({%- for f in fields if f.get('drift', false) %}
        {{ f.field }}_status = 'disagree'{{ " or " if not loop.last }}
    {%- endfor %})                          as value_drift
from dated