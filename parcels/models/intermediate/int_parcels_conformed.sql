{{ config(
    materialized='table',
    post_hook=[
      "drop index if exists staging.idx_conformed_geom",
      "create index idx_conformed_geom on {{ this }} using gist (geom)",
      "analyze {{ this }}",
    ]
) }}

{#  INDEX POST-HOOK: DROP then CREATE, never CREATE IF NOT EXISTS.

    dbt's table materialization builds into a __dbt_tmp relation and renames it
    over the old one, which takes the old table's indexes with it. An
    IF NOT EXISTS guard makes index creation history-dependent and silent -- a
    rebuild can leave this table unindexed with nothing in the dbt output
    saying so.

    Not hypothetical: a routine rebuild dropped this index and the next hour of
    overlap measurement ran against an unindexed table. Spokane went from 12.7s
    to a 300s timeout and King timed out at 9 minutes, each attributed to the
    wrong cause, because EXPLAIN showed Seq Scan and the natural reading was
    that the planner was rejecting the index rather than that none existed.

    tests/conformed_geom_index_exists.sql asserts it now. The analyze matters
    too: the GiST join's plan choice is statistics-sensitive and a freshly
    built table has none until autovacuum catches up.
#}

{#  Materialized as a table: this is what every downstream model and test reads,
    and as a view the joins plus ST_Area recomputed on each query (26-52s per
    test against 1.5M rows). #}

SELECT v.*,landuse_cd,
CASE WHEN c.landuse_cd is not NULL THEN 'derived' ELSE 'unmapped' END as landuse_cd_method
FROM {{ ref('int_parcels_validated') }} v
LEFT JOIN {{ ref('int_landuse_crosswalk') }} c
{#  county_fips is zero-padded ('061'), the prefix inside orig_landuse_cd is not
    ('61-111'). ltrim rather than substr(...,2): substr assumes exactly one
    leading zero, so it is correct for 033/053/061/063 and wrong for every FIPS
    below 100 ('007' -> '07', but the state writes '7-'). #}
ON ltrim(v.county_fips,'0') || '-' || landuse_code_source = orig_landuse_cd
WHERE rejection_reason IS NULL
