-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 05 · Gold — patient journey
-- MAGIC
-- MAGIC Two tables:
-- MAGIC * `journey_events` — one row per event: `DIAGNOSIS`, `FIRST_TREATMENT`, `ADD_ON`, `SWITCH`, `STOP`.
-- MAGIC * `patient_journey` — one row per patient: diagnosis, first treatment, time to treatment, 2nd/3rd line, insulin, path string, segments.
-- MAGIC
-- MAGIC **Switch vs add-on rule.** When a new drug class starts after the index treatment:
-- MAGIC * **SWITCH** if another class's episode ends within ±30 days of the new start (the new drug replaces something);
-- MAGIC * **ADD_ON** otherwise (the new drug is stacked on what the patient is already taking).
-- MAGIC * **COMBO_START** (patient table only) when a second class starts on the same day as the first treatment.
-- MAGIC
-- MAGIC Journey events use the **recorded** Synthea episodes (the clinical decisions), not the simulated fills.

-- COMMAND ----------

USE CATALOG workspace;

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_gold.journey_events AS
WITH ep AS (
  SELECT e.patient_id, e.drug_class, e.episode_start,
         LEAST(COALESCE(e.episode_end, c.censor_date), c.censor_date) AS episode_end_eff,
         CASE WHEN e.episode_end IS NOT NULL AND e.episode_end < c.censor_date THEN 1 ELSE 0 END AS ended_before_censor,
         c.first_tx_date, c.dx_date
  FROM t2d_silver.t2d_rx_episodes e
  JOIN t2d_silver.t2d_cohort c ON e.patient_id = c.patient_id
  WHERE e.episode_start >= c.first_tx_date
), new_class_starts AS (   -- first time each class appears after index
  SELECT * FROM ep
  QUALIFY ROW_NUMBER() OVER (PARTITION BY patient_id, drug_class ORDER BY episode_start) = 1
), starts_typed AS (
  SELECT s.patient_id, s.episode_start AS event_date, s.drug_class,
         CASE
           WHEN s.episode_start = s.first_tx_date THEN 'FIRST_TREATMENT'
           WHEN MAX(CASE WHEN o.patient_id IS NOT NULL THEN 1 ELSE 0 END) = 1 THEN 'SWITCH'
           ELSE 'ADD_ON'
         END AS event_type
  FROM new_class_starts s
  LEFT JOIN ep o                 -- another class ending within +/-30 days of this start
    ON o.patient_id = s.patient_id AND o.drug_class <> s.drug_class
   AND o.ended_before_censor = 1
   AND o.episode_end_eff BETWEEN s.episode_start - 30 AND s.episode_start + 30
  GROUP BY s.patient_id, s.episode_start, s.drug_class, s.first_tx_date
), stops AS (   -- a class stops and is not restarted within 30 days
  SELECT e.patient_id, e.episode_end_eff AS event_date, e.drug_class, 'STOP' AS event_type
  FROM ep e
  LEFT JOIN ep n
    ON n.patient_id = e.patient_id AND n.drug_class = e.drug_class
   AND n.episode_start > e.episode_start AND n.episode_start <= e.episode_end_eff + 30
  WHERE e.ended_before_censor = 1 AND n.patient_id IS NULL
), dx AS (
  SELECT patient_id, dx_date AS event_date, CAST(NULL AS STRING) AS drug_class, 'DIAGNOSIS' AS event_type
  FROM t2d_silver.t2d_cohort
), allev AS (
  SELECT * FROM dx UNION ALL SELECT * FROM starts_typed UNION ALL SELECT * FROM stops
)
SELECT a.patient_id, a.event_date, a.event_type, a.drug_class,
       datediff(a.event_date, c.dx_date) AS days_from_dx,
       ROW_NUMBER() OVER (PARTITION BY a.patient_id
                          ORDER BY a.event_date,
                                   CASE a.event_type WHEN 'DIAGNOSIS' THEN 0 WHEN 'FIRST_TREATMENT' THEN 1
                                                     WHEN 'STOP' THEN 2 ELSE 3 END,
                                   a.drug_class) AS event_seq
FROM allev a JOIN t2d_silver.t2d_cohort c ON a.patient_id = c.patient_id;

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_gold.patient_journey AS
WITH ranked AS (  -- treatment lines = class starts in order (first treatment, add-ons, switches)
  SELECT patient_id, event_date, event_type, drug_class,
         ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY event_seq) AS line_no
  FROM t2d_gold.journey_events
  WHERE event_type IN ('FIRST_TREATMENT', 'ADD_ON', 'SWITCH')
), lines AS (     -- a 2nd class started on the same day as the first = combination start
  SELECT patient_id, event_date, drug_class, line_no,
         CASE WHEN line_no > 1 AND event_type = 'FIRST_TREATMENT' THEN 'COMBO_START' ELSE event_type END AS event_type
  FROM ranked
), short_name AS (
  SELECT *, CASE drug_class WHEN 'Biguanide' THEN 'Metformin' WHEN 'GLP-1 RA' THEN 'GLP-1'
                            WHEN 'SGLT2 inhibitor' THEN 'SGLT2' WHEN 'Insulin (basal/premix)' THEN 'Basal insulin'
                            WHEN 'Insulin (prandial)' THEN 'Prandial insulin' ELSE drug_class END
             || CASE event_type WHEN 'ADD_ON' THEN ' (add-on)' WHEN 'SWITCH' THEN ' (switch)' WHEN 'COMBO_START' THEN ' (same-day combo)' ELSE '' END AS step_label
  FROM lines
), line_pivot AS (
  SELECT patient_id,
    MAX(CASE WHEN line_no = 2 THEN event_date END) AS line2_date,
    MAX(CASE WHEN line_no = 2 THEN drug_class END) AS line2_class,
    MAX(CASE WHEN line_no = 2 THEN event_type END) AS line2_type,
    MAX(CASE WHEN line_no = 3 THEN event_date END) AS line3_date,
    MAX(CASE WHEN line_no = 3 THEN drug_class END) AS line3_class,
    MAX(CASE WHEN drug_class LIKE 'Insulin%' THEN 1 ELSE 0 END) AS ever_insulin,
    MIN(CASE WHEN drug_class LIKE 'Insulin%' THEN event_date END) AS first_insulin_date,
    SUM(CASE WHEN event_type = 'SWITCH' THEN 1 ELSE 0 END) AS n_switches,
    SUM(CASE WHEN event_type = 'ADD_ON' THEN 1 ELSE 0 END) AS n_add_ons,
    COUNT(*) AS n_classes_used,
    concat_ws(' > ',
      MAX(CASE WHEN line_no = 1 THEN step_label END), MAX(CASE WHEN line_no = 2 THEN step_label END),
      MAX(CASE WHEN line_no = 3 THEN step_label END), MAX(CASE WHEN line_no = 4 THEN step_label END),
      MAX(CASE WHEN line_no = 5 THEN step_label END)) AS journey_path
  FROM short_name GROUP BY patient_id
)
SELECT c.patient_id, c.gender, c.age_at_dx, c.age_band, c.race, c.ethnicity,
       c.n_comorbidities, c.comorbidity_band,
       c.has_hypertension, c.has_hyperlipidemia, c.has_ckd, c.has_obesity, c.has_cvd,
       c.dx_date, YEAR(c.dx_date) AS dx_year,
       c.first_tx_date, c.first_tx_class, c.days_to_first_tx,
       CASE WHEN c.days_to_first_tx <= 0 THEN 'Same day / before dx'
            WHEN c.days_to_first_tx <= 30 THEN '1-30 days'
            WHEN c.days_to_first_tx <= 90 THEN '31-90 days'
            WHEN c.days_to_first_tx <= 365 THEN '91-365 days'
            ELSE '>1 year' END AS time_to_tx_bucket,
       p.line2_date, p.line2_class, p.line2_type, datediff(p.line2_date, c.first_tx_date) AS days_to_line2,
       p.line3_date, p.line3_class,
       p.ever_insulin, p.first_insulin_date, datediff(p.first_insulin_date, c.dx_date) AS days_dx_to_insulin,
       p.n_switches, p.n_add_ons, p.n_classes_used, p.journey_path,
       c.censor_date, datediff(c.censor_date, c.dx_date) AS followup_days,
       CASE WHEN c.death_date IS NOT NULL AND c.death_date <= c.data_cutoff_date THEN 1 ELSE 0 END AS died_in_followup
FROM t2d_silver.t2d_cohort c
JOIN line_pivot p ON c.patient_id = p.patient_id;

-- COMMAND ----------

SELECT journey_path, COUNT(*) AS patients,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM t2d_gold.patient_journey
GROUP BY journey_path ORDER BY patients DESC LIMIT 15;
