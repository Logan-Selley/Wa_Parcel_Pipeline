WITH classified AS (
    SELECT r.*,
        CASE {% for r in rejection_rules() %}
            when {{ r.predicate }} then '{{ r.rule_id }}'
        {% endfor %} END AS rejection_reason,
        f.source_file_date
    FROM {{ ref('int_parcels_records') }} r
    {# int_county_vintage rather than state_file_date directly: File_Date's
       county_nm mixes unpadded FIPS codes with four bare county names, so a
       plain lpad silently drops vintage for Grays Harbor, Pend Oreille, San
       Juan and Walla Walla. See docs/design.md defect 7. #}
    LEFT JOIN {{ ref('int_county_vintage') }} f
    ON f.county_fips = r.county_fips
),
survivors as (
    SELECT parcel_uid as duplicate_uid
    FROM classified
    WHERE rejection_reason IS NULL AND parcel_uid IS NOT NULL
    GROUP BY parcel_uid HAVING COUNT(*) > 1
),
enriched as (
    SELECT c.*, st_area(geom) / 43560.0 / nullif(acres_reported, 0) as area_ratio
    from classified c
)
SELECT e.*,
    {% set flag_cols = [] %}
    {% for f in flag_rules() %}
        {% do flag_cols.append(f.predicate ~ ' as ' ~ f.rule_id) %}
    {% endfor %}
    {{ flag_cols | join(', ') }}
FROM enriched e LEFT JOIN survivors d ON (parcel_uid = duplicate_uid)