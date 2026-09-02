-- macros/conform_parcels.sql
--
-- Emits the full body of a per-county staging model. Every stg_parcels__<county>
-- model is a single call to this macro; all per-county knowledge lives in the
-- manifest under vars: in dbt_project.yml.

{#
    Resolve one target field to its SQL expression.

    map.get(target, default) is NOT sufficient: the default fires only when the
    key is ABSENT. A key present with a YAML null value returns Python None,
    which Jinja renders as the literal text "None" -- producing SQL that
    references a column called none. Explicit nulls are the documented way to
    say "this county does not publish the field", so that path has to work.
#}
{% macro field(map, target, default='null') -%}
    {%- set v = map.get(target) -%}
    {{- default if v is none else v -}}
{%- endmacro %}


{% macro conform_parcels(fips) %}

{%- set cfg        = var('counties')[fips] -%}
{%- set map        = cfg['map'] -%}
{%- set src        = 'parcels_' ~ cfg['name'] | lower -%}
{%- set target_crs = var('target_crs', 2927) -%}

{#
    Record identity (docs/build-plan.md A3). Two ids, each with one job:

    record_key_uid = parcel_uid + the county's declared record_key fields,
    legibly encoded ('053-123456|A|2' = parcel + unit + unit_type + level).
    Declares, per county, what makes two published records the same record.
    Null-safe: a null field encodes as '~', and a null parcel_uid (the
    quarantine path) yields a null record_key_uid.

    record_signature = md5 over every raw column NOT in the county's
    identity_exclude list. It discriminates variants the declared key does
    not (attribute differences) without putting volatile data in the key --
    values in a key would churn identity on every assessment update.

    identity_exclude reasons:
      system row ids / volatile timestamps: objectid, globalid, editdate
      geometry-derived metadata (functions of geom; excluding them lets
        geometry-distinct records of one parcel union):
        shape__area, shape__length, x/y/long/lat, maplegend
      geom is always excluded implicitly.

    The column set comes from the live source relation minus the county's
    identity_exclude, so a column the county adds later is absorbed on the
    next run (and the drift test flags the change loudly).
#}
{%- set identity_exclude = cfg.get('identity_exclude', []) + ['geom'] -%}
{%- set key_fields = cfg.get('record_key', {}).get('fields', []) -%}

{#  NOTE: key parts are accumulated via list append, NOT by re-binding a set
    variable inside the loop -- Jinja for-loops are scoped, and a `set` inside
    a loop resets when the loop exits (the loop-scoped-set gotcha from
    docs/design.md). sig_parts below works the same way. #}
{%- set key_parts = [] -%}
{%- for f in key_fields -%}
    {%- do key_parts.append("'|' || coalesce(nullif(trim(" ~ f ~ "::text), ''), '~')") -%}
{%- endfor -%}
{%- if key_parts | length > 0 -%}
    {%- set key_suffix = ' || ' ~ (key_parts | join(' || ')) -%}
{%- else -%}
    {%- set key_suffix = '' -%}
{%- endif -%}

{%- set sig_expr = 'cast(null as text)' -%}
{%- if execute -%}
    {%- set raw_cols = adapter.get_columns_in_relation(source('raw', src)) -%}
    {%- set sig_parts = [] -%}
    {%- for c in raw_cols -%}
        {%- if c.name not in identity_exclude -%}
            {%- do sig_parts.append("coalesce(nullif(trim(" ~ c.name ~ "::text), ''), '~')") -%}
        {%- endif -%}
    {%- endfor -%}
    {%- if sig_parts | length > 0 -%}
        {%- set sig_expr = "md5(concat_ws('|', " ~ sig_parts | join(', ') ~ "))" -%}
    {%- endif -%}
{%- endif -%}

with source as (

    select * from {{ source('raw', src) }}

),

prepared as (

    select
        *,

        -- st_setsrid before st_transform: transform errors outright on an
        -- unknown (0) SRID, which is how some load paths land geometry. When
        -- the SRID is already correct this only relabels, so it is idempotent
        -- and makes the manifest the single authority on source CRS.
        --
        -- st_multi is required because the target column typmod is
        -- MultiPolygon and st_transform returns Polygon for single-part input.
        st_multi(
            st_transform(
                st_setsrid(geom, {{ cfg['source_crs'] }}),
                {{ target_crs }}
            )
        ) as geom_conformed,

        -- Normalized once here so parcel_uid can be built from it below rather
        -- than repeating the expression. Blank-to-null matters: Spokane
        -- publishes whitespace-only values in identifier-shaped columns.
        nullif(trim({{ map['parcel_id'] }}::text), '') as parcel_id_norm

    from source

)

select
    -- Null-safe by construction: a null parcel_id yields a null parcel_uid
    -- rather than the string '061-'. Those rows survive staging and are
    -- quarantined downstream (Snohomish publishes 4,595 of them).
    case
        when parcel_id_norm is null then null
        else '{{ fips }}' || '-' || parcel_id_norm
    end                                                     as parcel_uid,

    -- Record identity: record_key_uid declares the county's own record grain;
    -- record_signature fingerprints the full published record. See the macro
    -- header. Null parcel_id (quarantine path) nulls both.
    case
        when parcel_id_norm is null then null
        else '{{ fips }}' || '-' || parcel_id_norm{{ key_suffix }}
    end                                                     as record_key_uid,

    {{ sig_expr }}                                          as record_signature,

    '{{ fips }}'::char(3)                                   as county_fips,
    '{{ cfg["name"] }}'::text                               as county_name,
    parcel_id_norm                                          as parcel_id,
    {{ map['parcel_id_raw'] }}::text                            as parcel_id_raw,
    ({{ field(map, 'is_active', 'true') }})::boolean          as is_active,

    {#  Whether this record is a vertical component sharing a plan-view
        footprint with siblings. Counties encode the same physical structure
        incompatibly -- Pierce by taxparcellevel on a shared parcel number,
        Snohomish by a STACKED flag on records that each carry their own
        PARCEL_ID -- so this normalises the concept, not the encoding.

        Explanatory, never a gate: int_parcel_overlaps classifies pairs by
        geometry overlap RATIO (>=0.8 coincident, <0.8 encroachment), because
        measurement showed stacking implies coincidence but coincidence does
        not imply a stacking flag (588 fully-contained pairs in one sample box
        had neither record flagged). Gating on this column would have reported
        those as errors; annotating with it makes them a named anomaly. #}
    ({{ field(map, 'is_stacked', 'false') }})::boolean        as is_stacked,

    nullif(trim({{ field(map, 'situs_address') }}), '')::text        as situs_address,
    nullif(trim({{ field(map, 'sub_address')   }}), '')::text        as sub_address,
    nullif(trim({{ field(map, 'situs_city')    }}), '')::text        as situs_city,
    nullif(trim({{ field(map, 'situs_zip5')    }}), '')::text        as situs_zip5,
    nullif(trim({{ field(map, 'situs_zip4')    }}), '')::text        as situs_zip4,

    nullif(trim(({{ field(map, 'landuse_code_source') }})::text), '')::text as landuse_code_source,
    nullif(trim(({{ field(map, 'landuse_desc_source') }})::text), '')::text as landuse_desc_source,

    -- landuse_cd and landuse_cd_method are deliberately absent: the crosswalk
    -- is derived from the state layer, so it is applied in int_landuse_crosswalk
    -- rather than here.

    ({{ field(map, 'value_land_appraised') }})::bigint         as value_land_appraised,
    ({{ field(map, 'value_bldg_appraised') }})::bigint         as value_bldg_appraised,
    ({{ field(map, 'value_basis') }})::text                    as value_basis,
    ({{ field(map, 'acres_reported') }})::numeric              as acres_reported,

    geom_conformed                                           as geom,

    '{{ cfg["service_url"] }}/{{ cfg["layer_id"] }}'::text   as source_layer_url,
    {{ cfg['source_crs'] }}::integer                         as source_crs,
    current_timestamp                                        as ingested_at,

    -- Validity of the geometry actually stored, not of the source geometry:
    -- reprojection can change the answer.
    st_isvalid(geom_conformed)                               as geometry_valid,

    -- No repair happens in staging; it belongs with the quarantine logic in
    -- int_parcels_conformed. Emitted here so the union has a stable column set.
    false                                                    as geometry_repaired

    -- source_file_date is joined in the intermediate layer -- it comes from the
    -- state's File_Date table keyed by FIPS, which is a different source.

from prepared

{% endmacro %}
