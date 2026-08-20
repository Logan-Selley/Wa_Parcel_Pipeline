{{ config(materialized='table') }}

/*
    One label per DOR land use code, with its provenance recorded.

    The statewide layer publishes a DOR_Land_Use_Codes domain covering 83 codes,
    captured into raw.source_domains at ingest. But the data uses 89 distinct
    values -- [0, 9, 10, 20, 60, 70, 80, 90] appear without any definition, which
    is roughly 9% of the values in their own normalized column falling outside
    their own declared vocabulary (docs/design.md defect 8).

    Six of those eight are round decades, i.e. SLUCM group headers rather than
    specific uses, presumably assigned where a county reported only at the coarse
    level. The seed supplies those from SLUCM.

    Two things this model is careful about:

    1. Published labels always win. The fallback applies only where the domain is
       silent, so if DOR later defines code 80, label_source flips to dor_domain
       on the next run and the seed steps aside without intervention.

    2. label_source is not decoration. DOR codes are NOT pure SLUCM -- code 83 is
       "Agriculture classified under current use chapter 84.34 RCW", a Washington
       statutory classification with no SLUCM equivalent. So applying SLUCM group
       names to the undefined codes is an inference, not a lookup, and anything
       built on a slucm_fallback label carries that caveat. Same pattern as
       value_basis and landuse_cd_method: when meaning varies by provenance,
       carry a column that says which.
*/

with latest_capture as (

    select max(captured_at) as captured_at
    from {{ source('raw', 'source_domains') }}
    where domain_name = 'DOR_Land_Use_Codes'

),

published as (

    select
        d.code::int          as landuse_cd,
        d.label              as label,
        'dor_domain'         as label_source,
        null::text           as note
    from {{ source('raw', 'source_domains') }} d
    join latest_capture l on l.captured_at = d.captured_at
    where d.domain_name = 'DOR_Land_Use_Codes'

),

fallback as (

    select
        code::int            as landuse_cd,
        label                as label,
        'slucm_fallback'     as label_source,
        note                 as note
    from {{ ref('landuse_code_fallback_labels') }}

),

combined as (

    select * from published

    union all

    select f.*
    from fallback f
    where not exists (
        select 1 from published p where p.landuse_cd = f.landuse_cd
    )

)

select
    landuse_cd,
    -- as published, for fidelity against the source
    label,
    -- DOR labels are prefixed with their own code ('65 - Professional services')
    -- while the SLUCM fallbacks are not. Strip it so one column formats
    -- consistently -- a chart axis mixing both styles looks like a defect.
    regexp_replace(label, '^[0-9]+\s*-\s*', '') as label_short,
    label_source,
    note
from combined
