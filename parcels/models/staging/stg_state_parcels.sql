{{ config(materialized='table') }}

{#  The answer key, conformed to our vocabulary so the reconciliation compares
    like with like.

    SCOPED TO INGESTED COUNTIES, DRIVEN BY THE MANIFEST. The state layer holds
    3.32M parcels across 38 counties; we have ingested four. Comparing against
    the other 34 is not a finding, it is noise -- every one of their parcels
    would classify as theirs_only. The county list is read from var(’counties’)
    rather than hardcoded, so adding a fifth county to the manifest brings its
    state rows into scope automatically and nothing here needs editing.

    parcel_uid IS parcel_id_nr, NOT fips_nr || ’-’ || parcel_id_nr. The state
    already prefixes it -- verified on all 3,278,890 non-null rows, zero
    exceptions. Concatenating again would produce ’033-033-6744700264’ and
    every reconciliation join would miss. (The original plan specified the
    concatenation; it was wrong.)

    Rows with a null parcel_id_nr are KEPT with a null uid. They belong to a
    county we ingested but cannot join to anything, so they are the
    ’theirs_unidentified’ bucket the reconciliation reports explicitly rather
    than dropping via an inner join.

    COUNTY IS RECOVERED, NOT ASSUMED. fips_nr is null on 13,629 rows -- but
    they are not orphans. Every one carries a populated parcel_id_nr prefixed
    ’003-’ and county_nm ’3’, and the layer contains ZERO rows with
    fips_nr = ’003’. So the state’s FIPS_NR is null for 100% of exactly one
    county, Asotin, and the value is recoverable from two other columns they do
    populate (design.md defect 1, corrected).

    Filtering on the raw fips_nr would drop all 13,629 silently, because SQL
    NULL never matches IN -- and the fact’s theirs_unidentified bucket would
    then hold only the null-parcel_id rows inside our counties, not the class
    the plan accounts for. Recovering first means they are excluded because
    they are ASOTIN, a county we have not ingested, and would be included
    automatically the day Asotin joins the manifest.
#}

{% set ingested = var('counties').keys() | list %}

select
    {#  coalesce, not fips_nr: see the header. The prefix is already
        zero-padded to three characters, so no lpad is needed. #}
    coalesce(fips_nr, substring(parcel_id_nr from '^([0-9]{3})-'))
                                                        as county_fips,
    {#  Provenance, in keeping with value_basis / landuse_cd_method /
        label_source: when a column’s value did not come from where it should
        have, say so rather than laundering it. #}
    (fips_nr is null)                                   as county_fips_recovered,

    {#  Already FIPS-prefixed. Null-safe: a null id yields a null uid, which
        classifies as theirs_unidentified rather than joining spuriously. #}
    nullif(trim(parcel_id_nr), '')                      as parcel_uid,
    nullif(trim(orig_parcel_id), '')                    as parcel_id_orig,

    nullif(trim(situs_address), '')                     as situs_address,
    nullif(trim(sub_address), '')                       as sub_address,
    nullif(trim(situs_city_nm), '')                     as situs_city,

    {#  The same anchored regex our staging layer applies to the counties, run
        here too so the comparison is symmetric. SITUS_ZIP_NR is String(10) and
        691,059 state rows carry a +4 (design.md 10, resolved) -- splitting only
        our side would have manufactured a coverage difference on every one. #}
    substring(trim(situs_zip_nr) from '^([0-9]{5})')     as situs_zip5,
    substring(trim(situs_zip_nr) from '^[0-9]{5}-([0-9]{4})$') as situs_zip4,

    landuse_cd                                          as landuse_cd,
    {#  Kept alongside landuse_cd so the fact can distinguish "the state has no
        mapping" from "the state mapped it differently". Their format is
        county-prefixed (53-9100) where ours is the bare county code, so it is
        context, not a directly comparable field. #}
    nullif(trim(orig_landuse_cd), '')                   as landuse_code_source,

    value_land                                          as value_land,
    value_bldg                                          as value_bldg,

    geom                                                as geom,
    nullif(trim(data_link), '')                         as data_link

from {{ source('raw', 'state_parcels') }}
where coalesce(fips_nr, substring(parcel_id_nr from '^([0-9]{3})-'))
      in ({% for f in ingested %}'{{ f }}'{% if not loop.last %}, {% endif %}{% endfor %})
