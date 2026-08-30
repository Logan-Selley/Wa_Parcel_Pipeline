{% macro rejection_rules() %}
    {#  Ordered; list order IS the CASE precedence. Each predicate is a boolean
        expression over the columns of the POST-REPAIR relation (int_parcels_repaired).
        Judging happens in int_parcels_validated; this macro only declares. #}
    {% set rules = [
        {'rule_id': 'missing_parcel_uid',       'description': 'No Parcel ID provided. Unable to join to answer key or be referenced downstream',       'predicate': 'parcel_uid IS NULL'},
        {'rule_id': 'missing_geometry',         'description': 'A parcel without spatial information cannot be a valid parcel or diffed against the state data',       'predicate': 'geom IS NULL OR ST_IsEmpty(geom)'},
        {'rule_id': 'geometry_unrepairable',    'description': 'A parcel with unrepairable geometry cannot survive spatial analysis',       'predicate': 'NOT ST_IsValid(ST_MakeValid(geom))'},
    ] %}
    {% do return(rules) %}
{% endmacro %}