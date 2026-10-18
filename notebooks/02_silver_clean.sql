-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 02 · Silver — type, de-duplicate, drop PII
-- MAGIC
-- MAGIC | Rule | Applied to |
-- MAGIC |---|---|
-- MAGIC | Cast date strings to `DATE` (timestamps are truncated to the calendar day — day-level precision is all persistency needs) | all |
-- MAGIC | Cast costs to `DECIMAL(12,2)` and counts to `INT`; bad values become `NULL` via `try_cast` instead of failing the job | medications, encounters, patients |
-- MAGIC | Remove exact business-key duplicates with `QUALIFY ROW_NUMBER() = 1` | all |
-- MAGIC | Drop direct identifiers (SSN, licence, passport, names, street address, lat/lon) — the data are synthetic, but the pipeline is built as if they were real | patients |
-- MAGIC | Rows with no patient id or no start date are dropped | all |

-- COMMAND ----------

USE CATALOG workspace;

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_silver.patients AS
SELECT
  Id                                          AS patient_id,
  try_cast(BIRTHDATE AS DATE)                 AS birth_date,
  try_cast(DEATHDATE AS DATE)                 AS death_date,
  CASE GENDER WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END AS gender,
  RACE                                        AS race,
  ETHNICITY                                   AS ethnicity,
  COUNTY                                      AS county,
  try_cast(INCOME AS INT)                     AS income,
  try_cast(HEALTHCARE_EXPENSES AS DECIMAL(14,2)) AS lifetime_healthcare_expenses,
  try_cast(HEALTHCARE_COVERAGE AS DECIMAL(14,2)) AS lifetime_healthcare_coverage
FROM t2d_bronze.patients
WHERE Id IS NOT NULL AND try_cast(BIRTHDATE AS DATE) IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY Id ORDER BY _ingested_at DESC) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_silver.conditions AS
SELECT
  PATIENT                                     AS patient_id,
  ENCOUNTER                                   AS encounter_id,
  try_cast(START AS DATE)                     AS start_date,
  try_cast(STOP  AS DATE)                     AS stop_date,
  CODE                                        AS snomed_code,
  DESCRIPTION                                 AS description
FROM t2d_bronze.conditions
WHERE PATIENT IS NOT NULL AND try_cast(START AS DATE) IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY PATIENT, CODE, START ORDER BY STOP DESC NULLS FIRST) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_silver.medications AS
SELECT
  PATIENT                                     AS patient_id,
  ENCOUNTER                                   AS encounter_id,
  PAYER                                       AS payer_id,
  try_cast(substr(START, 1, 10) AS DATE)      AS start_date,
  try_cast(substr(STOP,  1, 10) AS DATE)      AS stop_date,
  CODE                                        AS rxnorm_code,
  DESCRIPTION                                 AS description,
  try_cast(BASE_COST      AS DECIMAL(12,2))   AS base_cost,
  try_cast(PAYER_COVERAGE AS DECIMAL(12,2))   AS payer_coverage,
  try_cast(DISPENSES      AS INT)             AS dispenses,
  try_cast(TOTALCOST      AS DECIMAL(14,2))   AS total_cost,
  REASONCODE                                  AS reason_code,
  REASONDESCRIPTION                           AS reason_description
FROM t2d_bronze.medications
WHERE PATIENT IS NOT NULL AND try_cast(substr(START, 1, 10) AS DATE) IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY PATIENT, CODE, START ORDER BY STOP DESC NULLS FIRST) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_silver.encounters AS
SELECT
  Id                                          AS encounter_id,
  PATIENT                                     AS patient_id,
  try_cast(substr(START, 1, 10) AS DATE)      AS start_date,
  ENCOUNTERCLASS                              AS encounter_class,
  CODE                                        AS snomed_code,
  DESCRIPTION                                 AS description,
  try_cast(TOTAL_CLAIM_COST AS DECIMAL(14,2)) AS total_claim_cost,
  try_cast(PAYER_COVERAGE   AS DECIMAL(14,2)) AS payer_coverage
FROM t2d_bronze.encounters
WHERE Id IS NOT NULL AND PATIENT IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY Id ORDER BY START) = 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Reference tables
-- MAGIC `ref_t2d_drugs` maps the RxNorm codes Synthea's metabolic-syndrome module prescribes to a drug class.
-- MAGIC `study_params` holds the data cut-off (latest prescription date) used for censoring.

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_silver.ref_t2d_drugs AS
SELECT * FROM (VALUES
  ('860975',  'Metformin ER 500 mg',        'Biguanide',              'Oral',       1),
  ('897122',  'Liraglutide 6 mg/mL pen',    'GLP-1 RA',               'Injectable', 2),
  ('1373463', 'Canagliflozin 100 mg',       'SGLT2 inhibitor',        'Oral',       3),
  ('106892',  'Insulin NPH/regular 70/30',  'Insulin (basal/premix)', 'Injectable', 4),
  ('865098',  'Insulin lispro (Humalog)',   'Insulin (prandial)',     'Injectable', 5)
) AS t(rxnorm_code, drug_name, drug_class, route, guideline_step);

-- cut-off = last prescription date (the persistency data source); a couple of encounters
-- carry dates a few days past the generation date and are ignored for censoring
CREATE OR REPLACE TABLE t2d_silver.study_params AS
SELECT MAX(start_date) AS data_cutoff_date,
       DATE'2010-01-01' AS index_window_start
FROM t2d_silver.medications;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Data-quality report: rows in Bronze vs Silver

-- COMMAND ----------

SELECT 'patients' AS table_name, (SELECT COUNT(*) FROM t2d_bronze.patients) AS bronze_rows, (SELECT COUNT(*) FROM t2d_silver.patients) AS silver_rows
UNION ALL SELECT 'conditions',  (SELECT COUNT(*) FROM t2d_bronze.conditions),  (SELECT COUNT(*) FROM t2d_silver.conditions)
UNION ALL SELECT 'medications', (SELECT COUNT(*) FROM t2d_bronze.medications), (SELECT COUNT(*) FROM t2d_silver.medications)
UNION ALL SELECT 'encounters',  (SELECT COUNT(*) FROM t2d_bronze.encounters),  (SELECT COUNT(*) FROM t2d_silver.encounters);
