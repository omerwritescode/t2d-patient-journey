-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 01 · Bronze — raw Synthea CSVs into Unity Catalog
-- MAGIC
-- MAGIC **What this does:** creates the schemas and a UC volume, then lands each raw Synthea CSV as a Delta table with every column kept as a string (no type changes in Bronze), plus two lineage columns.
-- MAGIC
-- MAGIC **Before running:** upload `patients`, `conditions`, `medications`, `encounters` (`.csv` or the shipped `.csv.gz` — the `.csv*` pattern reads either, gzip is decompressed automatically; upload one format only, not both) to
-- MAGIC `/Volumes/workspace/t2d_bronze/raw/synthea/` (Catalog Explorer → the volume → *Upload to this volume*).
-- MAGIC Run cell 2 first so the volume exists, upload, then run the rest.
-- MAGIC
-- MAGIC Catalog `workspace` is the default in Databricks Free Edition. Change it in the `USE CATALOG` line if yours differs (and in the volume paths).

-- COMMAND ----------

USE CATALOG workspace;

CREATE SCHEMA IF NOT EXISTS t2d_bronze COMMENT 'Raw Synthea extracts, all columns as strings';
CREATE SCHEMA IF NOT EXISTS t2d_silver COMMENT 'Typed, de-duplicated tables and the T2D cohort';
CREATE SCHEMA IF NOT EXISTS t2d_gold   COMMENT 'Patient journey and persistency marts';

CREATE VOLUME IF NOT EXISTS t2d_bronze.raw COMMENT 'Landing zone for Synthea CSV files';

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Land the four files
-- MAGIC `inferSchema => false` keeps everything as STRING so Bronze is a faithful copy of the source. Typing happens in Silver.

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_bronze.patients AS
SELECT *, _metadata.file_path AS _source_file, current_timestamp() AS _ingested_at
FROM read_files('/Volumes/workspace/t2d_bronze/raw/synthea/patients.csv*',
                format => 'csv', header => true, inferSchema => false);

CREATE OR REPLACE TABLE t2d_bronze.conditions AS
SELECT *, _metadata.file_path AS _source_file, current_timestamp() AS _ingested_at
FROM read_files('/Volumes/workspace/t2d_bronze/raw/synthea/conditions.csv*',
                format => 'csv', header => true, inferSchema => false);

CREATE OR REPLACE TABLE t2d_bronze.medications AS
SELECT *, _metadata.file_path AS _source_file, current_timestamp() AS _ingested_at
FROM read_files('/Volumes/workspace/t2d_bronze/raw/synthea/medications.csv*',
                format => 'csv', header => true, inferSchema => false);

CREATE OR REPLACE TABLE t2d_bronze.encounters AS
SELECT *, _metadata.file_path AS _source_file, current_timestamp() AS _ingested_at
FROM read_files('/Volumes/workspace/t2d_bronze/raw/synthea/encounters.csv*',
                format => 'csv', header => true, inferSchema => false);

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Row counts (sanity check)

-- COMMAND ----------

SELECT 'patients' AS table_name, COUNT(*) AS n_rows FROM t2d_bronze.patients
UNION ALL SELECT 'conditions', COUNT(*) FROM t2d_bronze.conditions
UNION ALL SELECT 'medications', COUNT(*) FROM t2d_bronze.medications
UNION ALL SELECT 'encounters', COUNT(*) FROM t2d_bronze.encounters;
