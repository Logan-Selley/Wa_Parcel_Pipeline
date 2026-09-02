{% macro rejection_rules() %}
    {#  Ordered; list order IS the CASE precedence. Each predicate is a boolean
        expression over the columns of the POST-REPAIR relation (int_parcels_repaired).
        Judging happens in int_parcels_validated; this macro only declares. #}
    {% set rules = [
        {'rule_id': 'missing_parcel_uid',       'description': 'No Parcel ID provided. Unable to join to answer key or be referenced downstream',       'predicate': 'parcel_uid IS NULL'},
        {'rule_id': 'missing_geometry',         'description': 'The source published no geometry. A parcel without spatial information cannot be diffed against the state data',       'predicate': 'source_geom_missing'},
        {'rule_id': 'geometry_unrepairable',    'description': 'The source published geometry that ST_MakeValid could not resolve into any polygon. Distinct from missing_geometry: the county supplied something, we could not use it',       'predicate': 'geom IS NULL OR ST_IsEmpty(geom) OR NOT ST_IsValid(geom)'},
    ] %}
    {% do return(rules) %}
{% endmacro %}
