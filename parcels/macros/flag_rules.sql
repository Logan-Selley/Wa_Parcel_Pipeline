{% macro flag_rules() %}
    {#  Each predicate is a boolean expression over the columns of the POST-REPAIR relation (int_parcels_repaired)
        and enriched with validation. Judging happens in int_parcels_validated; this macro only declares. #}
    {% set rules = [
        {'rule_id': 'area_mismatch',    'description': 'geometric area in acres does not match source reported acreage (within tolerance for projection)',       'predicate': 'abs(area_ratio - 1) > ' ~ var('area_tolerance', 0.1)},
        {'rule_id': 'zip_implausible',  'description': 'Zip5 is not valid for Washington State',        'predicate': "situs_zip5 IS NOT NULL AND situs_zip5 NOT BETWEEN '98000' AND '99499'"},
        {'rule_id': 'duplicate_uid',    'description': 'parcel uid appears more than once',             'predicate': 'duplicate_uid IS NOT NULL'},
    ] %}
    {% do return(rules) %}
{% endmacro %}