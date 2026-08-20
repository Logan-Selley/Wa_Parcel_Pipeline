-- Runs once, on first creation of the warehouse_data volume.
-- To re-run: docker compose down -v && docker compose up -d

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;   -- levenshtein, soundex
CREATE EXTENSION IF NOT EXISTS pg_trgm;         -- trigram similarity for fuzzy matching

-- Medallion layers
CREATE SCHEMA IF NOT EXISTS raw;         -- bronze: county data exactly as landed
CREATE SCHEMA IF NOT EXISTS staging;     -- silver: conformed to common schema
CREATE SCHEMA IF NOT EXISTS marts;       -- gold: analytics-ready
CREATE SCHEMA IF NOT EXISTS quarantine;  -- records that failed validation

COMMENT ON SCHEMA raw IS 'Bronze — county source data, unmodified. One table per county per layer.';
COMMENT ON SCHEMA staging IS 'Silver — conformed to the common parcel schema, validated.';
COMMENT ON SCHEMA marts IS 'Gold — analytics-ready, deduplicated across counties.';
COMMENT ON SCHEMA quarantine IS 'Records rejected at validation, with rejection reason and source metadata.';
