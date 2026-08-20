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
        nullif(upper(trim({{ map['parcel_id'] }}::text)), '') as parcel_id_norm

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

    '{{ fips }}'::char(3)                                   as county_fips,
    '{{ cfg["name"] }}'::text                               as county_name,
    parcel_id_norm                                          as parcel_id,
    {{ map['parcel_id'] }}::text                            as parcel_id_raw,
    {{ field(map, 'is_active', 'true') }}::boolean          as is_active,

    nullif(trim({{ field(map, 'situs_address') }}), '')::text        as situs_address,
    nullif(trim({{ field(map, 'sub_address')   }}), '')::text        as sub_address,
    nullif(trim({{ field(map, 'situs_city')    }}), '')::text        as situs_city,
    nullif(trim({{ field(map, 'situs_zip5')    }}), '')::text        as situs_zip5,
    nullif(trim({{ field(map, 'situs_zip4')    }}), '')::text        as situs_zip4,

    nullif(trim({{ field(map, 'landuse_code_source') }}::text), '')::text as landuse_code_source,
    nullif(trim({{ field(map, 'landuse_desc_source') }}::text), '')::text as landuse_desc_source,

    -- landuse_cd and landuse_cd_method are deliberately absent: the crosswalk
    -- is derived from the state layer, so it is applied in int_landuse_crosswalk
    -- rather than here.

    {{ field(map, 'value_land_appraised') }}::bigint         as value_land_appraised,
    {{ field(map, 'value_bldg_appraised') }}::bigint         as value_bldg_appraised,
    {{ field(map, 'value_basis') }}::text                    as value_basis,
    {{ field(map, 'acres_reported') }}::numeric              as acres_reported,

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
