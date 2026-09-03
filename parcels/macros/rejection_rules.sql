{% macro rejection_rules() %}
    {#  Ordered; list order IS the CASE precedence. Each predicate is a boolean
        expression over the columns of the POST-REPAIR relation (int_parcels_repaired).
        Judging happens in int_parcels_validated; this macro only declares. #}
    {% set rules = [
        {'rule_id': 'missing_parcel_uid',       'description': 'No parcel ID published; cannot join to the answer key or be referenced downstream',       'predicate': 'parcel_uid IS NULL'},
        {'rule_id': 'missing_geometry',         'description': 'The source published no geometry, so there is nothing to diff against the answer key',       'predicate': 'source_geom_missing'},
        {'rule_id': 'geometry_unrepairable',    'description': 'Geometry was published but ST_MakeValid could not resolve it into any polygon; distinct from missing_geometry, where the county supplied nothing at all',       'predicate': 'geom IS NULL OR ST_IsEmpty(geom) OR NOT ST_IsValid(geom)'},
    ] %}
    {% do return(rules) %}
{% endmacro %}
