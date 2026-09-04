{{ config(materialized='table') }}

{#
    County x check x outcome: the long-format quality scorecard.

    One row per county per check per outcome, carrying the parcel count and
    the county total alongside so rates are COMPUTED, not stored. Checks come
    from three places:

      1. flag_rules() -- the per-record quality flags, unpivoted: one block
         per flag (flagged / clear / not_measurable counts per county).
         Names and descriptions arrive from the registry, keeping it the
         single source of truth (fourth consumer of the pattern).
      2. hand-written county checks -- geometry validity, area-check
         coverage (share of parcels with an independent roll figure),
         landuse crosswalk coverage, attribute completeness, merge
         provenance, stacked components.
      3. rejection + overlap + state-side rows -- rejection outcomes from
         parcels_rejected (descriptions via rejection_rules()), overlap
         classes from the four per-county overlap models, and state-side
         duplicate groups + unidentified parcels so ours-vs-theirs reads in
         one place.

    SEMANTICS before querying:

      * `parcels` is the row count for that (county, check, outcome);
        `total_parcels` is the county’s conformed row count. Rates are
        parcels / total_parcels -- EXCEPT the state_copy_vintage row (a
        county-level fact) and the rejection/overlap rows, whose
        denominators are the rejected/overlap universes described in their
        check_description.
      * area_mismatch on MERGED records (source_record_count > 1) is the
        explained parcel-vs-component grain class, not a defect -- see
        docs/design-history.md A3b and the merge_provenance check below.
      * state_duplicate groups use the recovered county (Asotin’s 13,629
        rows carry no FIPS_NR but well-formed ’003-’ prefixed ids).
#}

{%- set flags = flag_rules() -%}

with county_totals as (

    select county_fips, county_name, count(*) as total_parcels
    from {{ ref('dim_parcel') }}
    group by 1, 2

),

{#  ---------------------------------------------------------------- flags #
    One unpivoted block per registry flag. Outcomes: flagged / clear, with
    not_measurable reserved for the tri-state flags (a null flag means the
    measurement had no inputs -- e.g. area_ratio on a record with no roll
    figure). #}
{% set flag_blocks = [] %}
{% for f in flags %}
    {% do flag_blocks.append("
select
    county_fips,
    '" ~ f.rule_id ~ "'                          as check_name,
    '" ~ f.description ~ "'                      as check_description,
    case when " ~ f.rule_id ~ " then 'flagged'
         when " ~ f.rule_id ~ " is null then 'not_measurable'
         else 'clear' end                        as outcome,
    count(*)                                     as parcels
from " ~ ref('int_parcels_conformed') ~ "
group by 1, 4") %}
{% endfor %}

checks as (

    {{ flag_blocks | join(' union all ') }}

    union all

    {# ------------------------------------------------ geometry validity #}
    select
        county_fips,
        'geometry_valid'                            as check_name,
        'stored geometry passes st_isvalid (post-repair, post-union)' as check_description,
        case when geometry_valid then 'valid' else 'invalid' end as outcome,
        count(*)                                    as parcels
    from {{ ref('int_parcels_conformed') }}
    group by 1, 4

    union all

    {# ------------------------------------------- area-check coverage #
        Share of parcels with an INDEPENDENT county acreage to validate
        geometry against. Snohomish is the known gap: 50,515 active rows
        report tab_acres = 0 (measured; gis_acres is circular and excluded),
        so ~17% of Snohomish has no area check by design. #}
    select
        county_fips,
        'area_check_coverage'                       as check_name,
        'parcel carries an independent county acreage (roll figure > 0) to validate geometry against' as check_description,
        case when acres_reported > 0 then 'measurable' else 'no_roll_figure' end as outcome,
        count(*)                                    as parcels
    from {{ ref('int_parcels_conformed') }}
    group by 1, 4

    union all

    {# ------------------------------------------------ landuse coverage #}
    select
        county_fips,
        'landuse_coverage'                          as check_name,
        'state landuse taxonomy derived via the crosswalk (unmapped = the state publishes no mapping for this code; Spokane has none at all)' as check_description,
        coalesce(landuse_cd_method, 'unmapped')     as outcome,
        count(*)                                    as parcels
    from {{ ref('int_parcels_conformed') }}
    group by 1, 4

    union all

    {# ------------------------------------------ attribute completeness #
        The King tracts decision: attribute-less records are kept in the
        dimension (a parcel registry includes what exists), and their share
        is published rather than hidden. complete = any of address / land
        value / building value present. #}
    select
        county_fips,
        'attribute_completeness'                    as check_name,
        'complete = at least one of situs address, land value, building value present; sparse records are the zero-value component and tract classes' as check_description,
        case
            when situs_address is not null
                 or value_land_appraised is not null
                 or value_bldg_appraised is not null then 'complete'
            else 'attribute_sparse'
        end                                         as outcome,
        count(*)                                    as parcels
    from {{ ref('int_parcels_conformed') }}
    group by 1, 4

    union all

    {# ------------------------------------------------ merge provenance #
        How many published rows each record absorbed (A3b). Pierce’s merged
        records are the condo component groups; their area_ratio is the
        explained parcel-vs-component grain class. #}
    select
        county_fips,
        'merge_provenance'                          as check_name,
        'merged = record absorbed >1 published row (A3b record-integration); single = published as one row' as check_description,
        case when source_record_count > 1 then 'merged' else 'single' end as outcome,
        count(*)                                    as parcels
    from {{ ref('int_parcels_conformed') }}
    group by 1, 4

    union all

    {# ------------------------------------------------ stacked components #
        Vertical components sharing a plan-view footprint. Snohomish flags
        them with STACKED; Pierce via taxparcellevel; both normalised into
        is_stacked. Stacked pairs are EXCLUDED from int_parcel_overlaps
        (both-stacked shortcut, measured 0/352,281 encroachments), so this
        count is where stacking appears in the scorecard. #}
    select
        county_fips,
        'stacked_components'                        as check_name,
        'records flagged by the county as vertically stacked components (Snohomish STACKED, Pierce level <> 0)' as check_description,
        case when is_stacked then 'stacked' else 'not_stacked' end as outcome,
        count(*)                                    as parcels
    from {{ ref('int_parcels_conformed') }}
    group by 1, 4

    union all

    {# ------------------------------------------------------ rejections #
        One row per county per rejection reason. Descriptions come from
        rejection_rules() -- fifth consumer of the registry. #}
    select
        r.county_fips,
        'rejection'                                 as check_name,
        coalesce(descr.description, 'unregistered rejection reason') as check_description,
        r.rejection_reason                          as outcome,
        count(*)                                    as parcels
    from {{ ref('parcels_rejected') }} r
    left join (
        select * from (values
            {%- for r in rejection_rules() %}
            ('{{ r.rule_id }}', '{{ r.description }}'){{ "," if not loop.last }}
            {%- endfor %}
        ) as t(rejection_reason, description)
    ) descr on descr.rejection_reason = r.rejection_reason
    group by 1, 2, 3, 4

    union all

    {# -------------------------------------------------- overlap classes #
        Pair counts from the per-county overlap models. Outcomes:
        coincident (near-total footprint sharing -- vertical stacks, condo
        units), coincident_unflagged (the subset neither record flagged),
        encroachment (partial overlap -- the boundary-defect signal).
        Denominator note: pairs, not parcels; the both-stacked pairs are
        excluded upstream, so stack-internal pairs are absent by design. #}
    {%- for fips, cfg in var('counties').items() %}
    select
        '{{ fips }}'::char(3)                       as county_fips,
        'geometry_overlap'                          as check_name,
        'pairs of distinct parcels whose geometries intersect by more than the minimum area; both-stacked pairs excluded (measured always-coincident)' as check_description,
        case
            when unflagged_coincident then 'coincident_unflagged'
            else overlap_class
        end                                         as outcome,
        count(*)                                    as parcels
    from {{ ref('int_parcel_overlaps__' ~ (cfg['name'] | lower)) }}
    group by 1, 4
    {% if not loop.last %}union all{% endif %}
    {%- endfor %}

    union all

    {# ------------------------------------- state duplicate uid groups #
        The state’s own duplicate PARCEL_ID_NR groups per recovered county --
        the symmetric counterpart of our merge ledger. The state carries
        49,426 such groups with no explanation; ours are all classified. #}
    select
        county_fips,
        'state_duplicate_groups'                    as check_name,
        'distinct PARCEL_ID_NR groups carrying multiple rows in the state answer key, WITHIN THE INGESTED COUNTIES only -- the in-scope slice of 49,426 statewide. Unlike ours, the state discards the fields that would resolve them: across 6,769 Pierce groups, zero are distinguished by sub_address or situs_address' as check_description,
        'state_collision_groups'                    as outcome,
        count(*)                                    as parcels
    from (
        select parcel_uid, min(county_fips) as county_fips
        from {{ ref('stg_state_parcels') }}
        where parcel_uid is not null
        group by 1
        having count(*) > 1
    ) d
    group by 1

    union all

    {# ------------------------------------------- state unidentified #
        State rows with no PARCEL_ID_NR at all -- the theirs_unidentified
        bucket of fct_parcel_reconciliation. #}
    select
        county_fips,
        'state_unidentified'                        as check_name,
        'state rows with no PARCEL_ID_NR; unjoinable to any county parcel (theirs_unidentified in the fact)' as check_description,
        'no_parcel_id'                              as outcome,
        count(*)                                    as parcels
    from {{ ref('stg_state_parcels') }}
    where parcel_uid is null
    group by 1

    union all

    {# ------------------------------------------------ state copy vintage #
        County-level fact: the vintage of the state’s copy of this county
        (File_Date, resolved for all 39 counties by int_county_vintage).
        Span measured 2026-01-09 to 2026-03-20 -- stale by up to ten weeks
        relative to our pull. parcels carries the county’s dim row count for
        join convenience; the outcome IS the vintage date. #}
    select
        v.county_fips,
        'state_copy_vintage'                        as check_name,
        'vintage of the state''s copy of this county per File_Date; counties are NOT the same vintage (design.md defect list)' as check_description,
        v.source_file_date::text                    as outcome,
        count(distinct d.record_key_uid)            as parcels
    from {{ ref('int_county_vintage') }} v
    left join {{ ref('dim_parcel') }} d on d.county_fips = v.county_fips
    group by 1, 2, 4

    union all

    {# --------------------------------------------------- reconciliation #
        THE headline check: how our conformed parcels compare to the answer
        key, per class. both_differ is the unexplained-delta count this whole
        build exists to produce -- differences that survive after case
        normalisation and after excluding fields the stale answer key is
        EXPECTED to disagree on (design.md 5.5, 5.6).

        Added here rather than joined straight into agg_scorecard_wide so the
        wide view stays a pure projection of this table: one definition per
        check, no second implementation to keep honest. #}
    select
        f.county_fips,
        'reconciliation'                            as check_name,
        'comparison against the state answer key per parcel_uid; both_differ is the unexplained delta after case normalisation and drift exclusion' as check_description,
        f.reconciliation_class                      as outcome,
        count(*)                                    as parcels
    from {{ ref('fct_parcel_reconciliation') }} f
    group by 1, 2, 4

    union all

    {# ------------------------------------------------------- value drift #
        Parcels whose assessed values differ. NOT counted as disagreement --
        the answer key is 167-216 days stale and WA counties revalue annually,
        so a delta is expected. Published so the expectation is visible rather
        than silently suppressed. #}
    select
        f.county_fips,
        'value_drift'                               as check_name,
        'parcels whose assessed value differs from the answer key; expected given the vintage gap, so excluded from reconciliation_class (design.md 5.5)' as check_description,
        'drifted'                                   as outcome,
        count(*)                                    as parcels
    from {{ ref('fct_parcel_reconciliation') }} f
    where f.value_drift
    group by 1, 2

    union all

    {# --------------------------------------------- county source vintage #
        The county’s OWN publish date (editingInfo.lastEditDate), the
        counterpart to state_copy_vintage above. Both are publisher
        statements, so the gap between them is a property of the two sources
        rather than of when we happened to run -- see int_source_vintage. #}
    select
        sv.county_fips,
        'county_source_vintage'                     as check_name,
        'the county''s own last-publish date per editingInfo.lastEditDate; paired with state_copy_vintage this gives a run-independent staleness measure' as check_description,
        sv.source_published_at::text                as outcome,
        count(distinct d.record_key_uid)            as parcels
    from {{ ref('int_source_vintage') }} sv
    left join {{ ref('dim_parcel') }} d on d.county_fips = sv.county_fips
    group by 1, 2, 4

    union all

    {# ------------------------------------------------- field coverage #
        Coverage advantage and deficit against the answer key, per field --
        the measurable half of the ours_better / theirs_better ledger.

        theirs_absent = we publish a value they do not (Pierce ZIP+4, which
        their conformance dropped). ours_absent = they publish one we do not
        (King situs_city on 42,659 parcels, Spokane landuse_cd where no
        crosswalk is derivable). Both are coverage, NOT disagreement -- which
        is exactly why field_status() is four-way rather than boolean. #}
    {%- for f in comparable_fields() %}
    select
        f.county_fips,
        'field_coverage'                            as check_name,
        'per-field coverage against the answer key; ours_only means we publish a value the state lacks, theirs_only the reverse' as check_description,
        '{{ f.field }}:' || f.{{ f.field }}_status  as outcome,
        count(*)                                    as parcels
    from {{ ref('fct_parcel_reconciliation') }} f
    where f.{{ f.field }}_status in ('ours_absent', 'theirs_absent')
    group by 1, 2, 4
    union all
    {%- endfor %}

    {# ------------------------------------------------ geometry repaired #
        Geometry we FIXED rather than merely flagged: invalid on arrival,
        resolved by ST_MakeValid into a valid polygon. The state publishes no
        validity assessment at all, so every one of these is a defect we
        corrected and they carry uncorrected. #}
    select
        d.county_fips,
        'geometry_repaired'                         as check_name,
        'geometry invalid as published and repaired by ST_MakeValid; the answer key publishes no validity assessment' as check_description,
        'repaired'                                  as outcome,
        count(*)                                    as parcels
    from {{ ref('dim_parcel') }} d
    where d.geometry_repaired
    group by 1, 2

)

select
    t.county_fips,
    t.county_name,
    ch.check_name,
    ch.check_description,
    ch.outcome,
    ch.parcels,
    t.total_parcels,

    {#  WHICH OUTCOME IS THE BAD ONE -- stated here, not inferred downstream.

        Every check has its own outcome vocabulary: 'flagged' for the
        flag_rules() checks, but 'no_roll_figure', 'attribute_sparse',
        'unmapped' and 'missing_parcel_uid' elsewhere. Without this column a
        BI tool cannot build "adverse rate by check" without re-encoding that
        vocabulary in its own CASE statement -- a second source of truth that
        goes stale silently the first time a check is added or an outcome
        renamed, and that nothing in this repo would turn red about.

        Deliberately FALSE for outcomes that are properties or resolutions
        rather than defects:
          repaired    geometry we FIXED. A correction, not a fault.
          merged      records resolved by a declared record key -- the A3b
                      merge working as designed.
          stacked     a vertical component. The shape of condominium data.
          drifted     assessed values differing from a 167-216 day stale
                      answer key, which they MUST. Excluded from disagreement
                      for the same reason.
          both_match  agreement.

        Also FALSE for the two state-side checks: state_collision_groups and
        no_parcel_id are defects in the ANSWER KEY, not in our conformance,
        and colouring them on a heatmap of our quality would misattribute
        them. They have their own place in the scorecard. #}
    ch.outcome in (
        'flagged',              {#- area_mismatch, duplicate_uid, zip_implausible -#}
        'no_roll_figure',       {#- area_check_coverage: no independent acreage to check against -#}
        'attribute_sparse',     {#- attribute_completeness -#}
        'unmapped',             {#- landuse_coverage: no derivable crosswalk -#}
        'missing_parcel_uid'    {#- rejection: quarantined -#}
    )                                               as is_adverse
from checks ch
join county_totals t on t.county_fips = ch.county_fips
order by ch.county_fips, ch.check_name, ch.outcome
