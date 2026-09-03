{% macro flag_rules() %}
    {#  Each predicate is a boolean expression over the post-repair, post-validation
        columns of int_parcels_validated. Judging happens there; this macro only declares. #}
    {% set rules = [
        {'rule_id': 'area_mismatch',    'description': 'geometry-derived acreage differs from the county-reported figure beyond the projection tolerance',       'predicate': 'abs(area_ratio - 1) > ' ~ var('area_tolerance', 0.1)},
        {'rule_id': 'zip_implausible',  'description': 'situs_zip5 falls outside the Washington range (98000-99499)',        'predicate': "situs_zip5 IS NOT NULL AND situs_zip5 NOT BETWEEN '98000' AND '99499'"},
        {'rule_id': 'duplicate_uid',    'description': 'the same parcel_uid passed validation on more than one record',             'predicate': 'duplicate_uid IS NOT NULL'},
    ] %}
    {% do return(rules) %}
{% endmacro %}