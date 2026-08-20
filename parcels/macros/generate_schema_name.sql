{#
    Override dbt's default schema naming.

    dbt's built-in generate_schema_name concatenates the target schema onto any
    custom schema, so a model configured with `+schema: marts` against a target
    schema of `staging` materializes into `staging_marts`. That behaviour exists
    to keep developers from colliding in a shared warehouse.

    This warehouse is single-tenant and local, and docker/initdb/01_init.sql
    already creates the four medallion schemas by their bare names
    (raw / staging / marts / quarantine). Prefixing would leave those four
    empty and build a parallel set beside them.

    So: use the custom schema verbatim when one is declared, and fall back to
    the target schema when one isn't.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}
