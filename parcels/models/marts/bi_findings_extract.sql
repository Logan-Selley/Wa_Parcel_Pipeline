{{ config(
    materialized='table',
    post_hook="create index if not exists idx_bi_findings_geom on {{ this }} using gist (geom)"
) }}

{#
    The map-facing extract: every record this pipeline has something to SAY
    about, reprojected to WGS84 and simplified for browser-side rendering.

    WHY THIS REPLACED A FULL-PARCEL EXTRACT

    The previous bi_parcel_extract carried all 1,504,693 published records and
    produced a 590 MB FlatGeobuf whose tile archive could not fit in a git
    repository (GitHub rejects files over 100 MB). Two reasons to cut it, and
    the size was the lesser one:

      * Washington already publishes a statewide parcel map. Re-publishing 1.5M
        polygons duplicates the state's work and asserts nothing. The finding
        set is the part that does not exist anywhere else.
      * A map of everything cannot be read. At 55,589 features every polygon on
        screen is a claim this project is making, which is the point. (At the
        build that shipped this model: 49,175 from our side, 1,816 theirs_only,
        4,598 quarantined.)

    The full extract was not a second contract and losing it costs nothing:
    dim_parcel is still exported to parquet at full grain for analysis, and
    this model is reproducible from it at any time.

    THREE GEOMETRY SOURCES, DECLARED

    Findings do not all live on our side of the join, so neither does the
    geometry. geom_source records which, in keeping with value_basis,
    landuse_cd_method and county_fips_recovered -- when a column's value came
    from somewhere other than the obvious place, say so:

      'county'      dim_parcel. Our conformed geometry.
      'state'       stg_state_parcels. Used for theirs_only -- parcels the
                    answer key publishes and we do not. Showing only our own
                    side would make the map argue one direction, so the 1,739
                    records where THEY have coverage and we do not are drawn
                    from their geometry and labelled as such.
      'quarantine'  parcels_rejected. All 4,598 rejected records carry valid
                    geometry; every one fails for missing_parcel_uid, so they
                    are shapes without a usable identifier. They cannot be
                    matched to the state layer -- there is no key to match ON --
                    and they do not need to be.

    SIMPLIFICATION -- unchanged, and st_simplifypreservetopology is load
    bearing. Plain st_simplify collapses polygons whose vertices all fall
    inside the tolerance and returns NULL for the ring: measured, 1,060 tiny
    parcels (6-261 sqft, 4-6 vertices) silently vanished from the extract on
    the first build. PreserveTopology returns the original instead. If a null
    geom ever appears in this table, a simplification function changed
    underneath us -- bi_geom_validity asserts it.
#}

with

{#  Which of our published records have a finding, and which kind. Built as
    one pass over the three sources rather than a filter over dim, so a record
    carrying several findings still yields exactly one row. #}
overlapping as (
    {#  int_parcel_overlaps is PAIR-grain; this extract is FEATURE-grain. Each
        pair is emitted twice, once from each side, so a record can be found
        whichever end of the overlap it sits on -- and each row carries the
        COUNTERPART's parcel_uid, which is what lets the map say "overlaps
        053-1234" instead of just "overlaps something".

        Coincident-and-flagged pairs are excluded: two stacked condo units
        sharing a footprint is the expected shape of the data, not a defect.
        Encroachments and coincident pairs where NEITHER record is flagged are
        the signal.

        Deliberately NOT aggregated here -- the counterpart rows are needed
        individually so overlap_flags can rank them by area. #}
    select record_key_a as record_key_uid,
           parcel_uid_b as other_uid,
           overlap_class,
           unflagged_coincident,
           overlap_sqft,
           overlap_ratio
    from {{ ref('int_parcel_overlaps') }}
    where overlap_class = 'encroachment' or unflagged_coincident
    union all
    select record_key_b,
           parcel_uid_a,
           overlap_class,
           unflagged_coincident,
           overlap_sqft,
           overlap_ratio
    from {{ ref('int_parcel_overlaps') }}
    where overlap_class = 'encroachment' or unflagged_coincident
),

{#  NOT named `overlaps`. OVERLAPS is a RESERVED keyword in PostgreSQL -- the
    SQL temporal operator, (s1,e1) OVERLAPS (s2,e2) -- so a bare CTE alias of
    that name is a syntax error, reported unhelpfully at the line AFTER the
    preceding CTE closes. The int_parcel_overlaps models are unaffected because
    dbt always emits relation names fully quoted; only an unquoted alias like
    this one collides. #}
overlap_by_counterpart as (
    {#  COLLAPSE TO ONE ROW PER COUNTERPART PARCEL FIRST.

        int_parcel_overlaps is record-grain on BOTH sides, so a single
        counterpart parcel yields one pair row per record it holds -- and a
        stacked condo holds many. Aggregating straight to the record would list
        the same parcel_uid five times with identical numbers, which reads as a
        rendering bug rather than as the stacking it actually reflects
        (measured: 053-9010480070 listed 053-9010480130 four times).

        It also made overlap_count count PAIRS while the popup label said
        "parcels" -- a number that disagreed with its own noun.

        max() on the measures, not sum(): the pair rows describe the same
        physical overlap seen from different records, so summing would inflate
        the area by the stack depth. #}
    select record_key_uid,
           other_uid,
           bool_or(overlap_class = 'encroachment')  as is_encroachment,
           bool_or(unflagged_coincident)            as is_unflagged_coincident,
           max(overlap_sqft)                        as overlap_sqft,
           max(overlap_ratio)                       as overlap_ratio
    from overlapping
    group by 1, 2
),

overlap_flags as (
    {#  One row per record, collapsing every counterpart PARCEL it overlaps.

        overlaps_with is capped at the 5 LARGEST by area, because a parcel in a
        dense block can overlap a dozen neighbours and a popup listing all of
        them is unreadable. overlap_count reports the true total alongside it,
        so the cap is visible rather than a silent truncation -- the same rule
        the map's multi-feature popup follows.

        Ordered by overlap_sqft descending: the biggest encroachment is the one
        worth investigating, and a 4 sqft slice of surveyor noise should never
        push a 900 sqft conflict off the list. #}
    {#  bool_or over the ALREADY-aggregated booleans from
        overlap_by_counterpart -- overlap_class was consumed there and no
        longer exists at this level. #}
    select record_key_uid,
           bool_or(is_encroachment)                 as is_encroachment,
           bool_or(is_unflagged_coincident)         as is_unflagged_coincident,
           {#  Distinct counterpart PARCELS -- the noun the popup uses. #}
           count(*)                                 as overlap_count,
           array_to_string(
               (array_agg(
                   coalesce(other_uid, '(unidentified)')
                   || ' (' || round(overlap_sqft)::bigint::text || ' sqft'
                   || coalesce(', ' || round(overlap_ratio * 100)::text || '%', '')
                   || ')'
                   order by overlap_sqft desc
               ))[1:5], '; ')                       as overlaps_with
    from overlap_by_counterpart
    group by 1
),

recon as (
    {#  Parcel-grain, so it joins to dim on parcel_uid rather than
        record_key_uid. both_match records are dropped here -- agreement is
        not a finding.

        WHICH FIELD DISAGREED, NOT JUST THAT ONE DID. attribute_disagreement is
        the largest class on the map by a wide margin, and a popup that says
        only "attribute disagreement" names a category rather than a finding --
        the reader still has to go to the warehouse to learn anything. The fct
        already holds ours_<field>, theirs_<field> and <field>_status per
        comparable field, so the evidence just needs carrying.

        Built from classifying_fields(), the same registry that decides
        reconciliation_class, so this list can never disagree with the label it
        explains. That deliberately excludes:
          - drift fields (value_land, value_bldg), which MUST differ against an
            answer key 167-216 days stale, and would swamp every real finding
          - sub_address, which is incomparable: ours is a unit designator,
            theirs is a condominium complex name

        concat_ws skips nulls, so only the fields that actually disagree
        appear. nullif('') keeps a parcel with no classifying disagreement --
        an ours_only row, say -- null rather than an empty string. #}
    select
        parcel_uid,
        reconciliation_class,
        nullif(concat_ws('; '
        {%- for f in classifying_fields() %},
            case when {{ f.field }}_status = 'disagree'
                 then '{{ f.field }}: '
                      || coalesce(nullif(trim(ours_{{ f.field }}::text), ''), '(none)')
                      || ' ≠ '
                      || coalesce(nullif(trim(theirs_{{ f.field }}::text), ''), '(none)')
            end
        {%- endfor %}
        ), '')                                          as disagreements
    from {{ ref('fct_parcel_reconciliation') }}
    where reconciliation_class in ('both_differ', 'ours_only')
),

ours as (
    select
        {#  feature_id, not record_key_uid. NO SINGLE COLUMN identifies a
            feature across the three sources: theirs_only rows have no
            record_key_uid (they are not ours), and quarantined rows have
            neither record_key_uid NOR parcel_uid -- being unidentifiable is
            precisely why they were rejected. record_signature is what stands
            in for them, verified distinct on all 4,598.

            Prefixing with the source keeps the namespaces from colliding and
            makes a feature id self-describing in a browser dev console. #}
        'county:' || d.record_key_uid                    as feature_id,
        d.record_key_uid,
        d.parcel_uid,
        d.county_fips,
        d.county_name,
        d.situs_address,
        d.situs_city,
        d.landuse_cd,
        d.value_land_appraised,
        d.value_bldg_appraised,
        d.acres_reported,

        'county'                                        as geom_source,
        coalesce(o.is_encroachment, false)              as is_encroachment,
        coalesce(o.is_unflagged_coincident, false)      as is_unflagged_coincident,
        (r.reconciliation_class = 'both_differ')        as disagrees_with_state,
        (r.reconciliation_class = 'ours_only')          as absent_from_state,
        false                                           as absent_from_ours,
        d.geometry_repaired,
        false                                           as is_quarantined,
        false                                           as state_duplicate_id,
        null::text                                      as rejection_reason,
        r.disagreements                                 as disagreements,
        o.overlaps_with                                 as overlaps_with,
        o.overlap_count                                 as overlap_count,

        d.geom
    from {{ ref('dim_parcel') }} d
    left join overlap_flags o on o.record_key_uid = d.record_key_uid
    left join recon    r on r.parcel_uid     = d.parcel_uid
    {#  The filter that makes this model what it is. A record earns a place on
        the map by carrying at least one finding; everything else is the 97%
        the state already publishes. #}
    where coalesce(o.is_encroachment, false)
       or coalesce(o.is_unflagged_coincident, false)
       or r.reconciliation_class is not null
       or d.geometry_repaired
),

theirs_raw as (
    {#  Parcels the answer key has and we do not. Their geometry, said so.

        THE STATE PUBLISHES SOME PARCEL IDS TWICE. Two Pierce ids arrive here
        with two DISTINCT shapes each -- the same defect design.md records for
        their duplicate handling, reaching the map. Collapsing them to one
        feature would delete the evidence, which is the opposite of what this
        map is for, so both are kept and the id carries a #n discriminator.
        state_duplicate_id marks them so a viewer is told rather than left to
        notice two stacked polygons. #}
    select
        s.*,
        count(*)     over (partition by s.parcel_uid) as uid_rows,
        row_number() over (partition by s.parcel_uid order by st_area(s.geom) desc) as uid_seq
    from {{ ref('stg_state_parcels') }} s
    join {{ ref('fct_parcel_reconciliation') }} f
      on f.parcel_uid = s.parcel_uid
     and f.reconciliation_class = 'theirs_only'
    where s.geom is not null
),

theirs as (
    select
        'state:' || s.parcel_uid
            || case when s.uid_rows > 1 then '#' || s.uid_seq else '' end
                                                        as feature_id,
        null::text                                      as record_key_uid,
        s.parcel_uid,
        s.county_fips,
        null::text                                      as county_name,
        s.situs_address,
        s.situs_city,
        s.landuse_cd,
        s.value_land                                    as value_land_appraised,
        s.value_bldg                                    as value_bldg_appraised,
        null::numeric                                   as acres_reported,

        'state'                                         as geom_source,
        false, false, false, false,
        true                                            as absent_from_ours,
        false                                           as geometry_repaired,
        false                                           as is_quarantined,
        (s.uid_rows > 1)                                as state_duplicate_id,
        null::text                                      as rejection_reason,
        {#  No field comparison exists for a parcel we do not carry, and
            overlaps are computed on our geometry, not theirs. #}
        null::text                                      as disagreements,
        null::text                                      as overlaps_with,
        null::bigint                                    as overlap_count,

        s.geom
    from theirs_raw s
),

quarantined as (
    {#  Valid shapes with no usable identifier. Carried with their rejection
        reason so the map can say WHY rather than just flagging them. #}
    select
        'quarantine:' || q.record_signature             as feature_id,
        q.record_key_uid,
        q.parcel_uid,
        q.county_fips,
        q.county_name,
        q.situs_address,
        q.situs_city,
        null::smallint                                  as landuse_cd,
        q.value_land_appraised,
        q.value_bldg_appraised,
        q.acres_reported,

        'quarantine'                                    as geom_source,
        false, false, false, false, false,
        q.geometry_repaired,
        true                                            as is_quarantined,
        false                                           as state_duplicate_id,
        q.rejection_reason,
        {#  Rejected before reconciliation and before overlap detection, which
            runs on int_parcels_conformed -- quarantined rows never reach it. #}
        null::text                                      as disagreements,
        null::text                                      as overlaps_with,
        null::bigint                                    as overlap_count,

        q.geom
    from {{ ref('parcels_rejected') }} q
    where q.geom is not null
),

unioned as (
    select * from ours
    union all select * from theirs
    union all select * from quarantined
)

select
    feature_id,
    record_key_uid,
    parcel_uid,
    county_fips,
    county_name,
    situs_address,
    situs_city,
    landuse_cd,
    value_land_appraised,
    value_bldg_appraised,
    acres_reported,

    geom_source,
    is_encroachment,
    is_unflagged_coincident,
    disagrees_with_state,
    absent_from_state,
    absent_from_ours,
    geometry_repaired,
    is_quarantined,
    state_duplicate_id,
    rejection_reason,
    disagreements,
    overlaps_with,
    overlap_count,

    {#  ONE categorical for map styling. A feature can carry several findings
        and the flags above preserve all of them; this picks the one to colour
        by. Ordered by how much explaining the finding needs, not by severity --
        a quarantined record and an encroachment are both worth a click, but
        only one of them is a shape with no identity. #}
    case
        when is_quarantined            then 'quarantined'
        when is_encroachment           then 'encroachment'
        when is_unflagged_coincident   then 'unflagged_coincident'
        when absent_from_ours          then 'theirs_only'
        when absent_from_state         then 'ours_only'
        when disagrees_with_state      then 'attribute_disagreement'
        when geometry_repaired         then 'geometry_repaired'
    end                                                 as finding_primary,

    st_simplifypreservetopology(
        st_transform(geom, 4326),
        {{ var('simplify_tolerance', 0.00001) }}
    )                                                   as geom

from unioned
