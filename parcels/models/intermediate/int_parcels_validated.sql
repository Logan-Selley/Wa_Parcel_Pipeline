with classified as (
    select r.*,
        case {% for r in rejection_rules() %}
            when {{ r.predicate }} then '{{ r.rule_id }}'
        {% endfor %} end as rejection_reason,
        f.source_file_date
    from {{ ref('int_parcels_records') }} r
    {# int_county_vintage rather than state_file_date directly: File_Date’s
       county_nm mixes unpadded FIPS codes with four bare county names, so a
       plain lpad silently drops vintage for Grays Harbor, Pend Oreille, San
       Juan and Walla Walla. See docs/design.md defect 7. #}
    left join {{ ref('int_county_vintage') }} f
    on f.county_fips = r.county_fips
),
survivors as (
    select parcel_uid as duplicate_uid
    from classified
    where rejection_reason is null and parcel_uid is not null
    group by parcel_uid having count(*) > 1
),
enriched as (
    select c.*, st_area(geom) / 43560.0 / nullif(acres_reported, 0) as area_ratio
    from classified c
)
select e.*,
    {% set flag_cols = [] %}
    {% for f in flag_rules() %}
        {% do flag_cols.append(f.predicate ~ ' as ' ~ f.rule_id) %}
    {% endfor %}
    {{ flag_cols | join(', ') }}
from enriched e left join survivors d on (parcel_uid = duplicate_uid)