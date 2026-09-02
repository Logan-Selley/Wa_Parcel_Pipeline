-- depends_on: {{ ref('int_parcels_conformed') }}
{#  The overlap models are only tractable with this index -- without it the
    planner falls back to a Seq Scan nested loop and a county self-join goes
    from seconds to hours. It has been silently lost to a rebuild once
    already, so it is asserted rather than assumed. #}
select 'idx_conformed_geom missing on int_parcels_conformed' as failure
where not exists (
    select 1 from pg_indexes
    where schemaname = 'staging'
      and tablename  = 'int_parcels_conformed'
      and indexname  = 'idx_conformed_geom'
)
