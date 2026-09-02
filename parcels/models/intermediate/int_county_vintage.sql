{{ config(materialized='table') }}

/*
    County -> vintage of the state's copy, one row per county.

    File_Date.COUNTY_NM is not a usable join key on its own. 35 of 39 rows hold
    an unpadded FIPS code ('1', '11'); the other four hold a NAME --
    GraysHarbor, PendOreille, SanJuan, Walla Walla. Those are exactly
    Washington's four multi-word county names, all of them, which is the
    signature of a name -> FIPS lookup that fails on names containing spaces
    and lets the raw value fall through (docs/design.md defect 7). The fallback
    is not even self-consistent: three have their spaces stripped, Walla Walla
    keeps its own.

    Resolved against the County_Name coded-value domain captured from the layer
    metadata at ingest, matching on space-stripped names. No hand-authored
    county seed is needed -- the state publishes the crosswalk, just not in a
    table.

    Our four counties are all numeric, so a plain lpad works today and would
    silently drop vintage for those four at statewide scope.
*/

with county_names as (

    select code, label
    from {{ source('raw', 'source_domains') }}
    where domain_name = 'County_Name'
      and captured_at = (
          select max(captured_at)
          from {{ source('raw', 'source_domains') }}
          where domain_name = 'County_Name'
      )

)

select
    case
        when f.county_nm ~ '^[0-9]+$' then lpad(f.county_nm, 3, '0')
        else lpad(n.code, 3, '0')
    end                                             as county_fips,
    f.county_nm                                     as county_nm_raw,
    (f.county_nm !~ '^[0-9]+$')                     as resolved_from_name,
    to_timestamp(f.file_date / 1000.0)::date        as source_file_date
from {{ source('raw', 'state_file_date') }} f
left join county_names n
    on replace(lower(n.label), ' ', '') = replace(lower(f.county_nm), ' ', '')
