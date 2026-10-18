-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 03 · Silver — T2D cohort definition
-- MAGIC
-- MAGIC ## Cohort rules (written down, applied in order)
-- MAGIC | # | Rule | Why |
-- MAGIC |---|---|---|
-- MAGIC | R1 | Patient has a type 2 diabetes diagnosis: SNOMED **44054006** *Diabetes mellitus type 2 (disorder)*. **Index diagnosis date** = earliest start date of that code. | Defines the disease cohort |
-- MAGIC | R2 | Index diagnosis between **2010-01-01** and **data cut-off − 365 days** | Modern drug era (GLP-1/SGLT2 available) and every patient has ≥ 1 year of potential follow-up |
-- MAGIC | R3 | Age ≥ 18 at index diagnosis | Adult T2D |
-- MAGIC | R4 | **New-user rule:** no T2D drug (see `ref_t2d_drugs`) started more than 30 days *before* the index diagnosis | Excludes prevalent users, mainly patients put on metformin for prediabetes, whose "first treatment" is not a response to the T2D diagnosis |
-- MAGIC | R5 | Starts a T2D drug on or after (index − 30 days), before cut-off | "Diagnosed **and** treated" cohort for journey and persistency |
-- MAGIC
-- MAGIC **Index treatment** = first T2D drug episode after R4/R5; its class is the *index class*.
-- MAGIC **Censor date** = earlier of death and data cut-off.
-- MAGIC **Baseline window** for comorbidities, engagement and pill burden = up to and including the index date.

-- COMMAND ----------

USE CATALOG workspace;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### T2D drug records and therapy episodes
-- MAGIC Synthea writes a chronic drug as many consecutive records. Records of the same class that touch or overlap (next start ≤ previous stop + 1 day) are merged into one **episode** (gaps-and-islands). An open-ended record (no stop date) means the episode is ongoing at the end of the data.

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_silver.t2d_rx AS
SELECT m.patient_id, m.start_date, m.stop_date, r.rxnorm_code, r.drug_class, r.route, r.guideline_step,
       m.total_cost, m.payer_coverage, m.dispenses, m.reason_description
FROM t2d_silver.medications m
JOIN t2d_silver.ref_t2d_drugs r ON m.rxnorm_code = r.rxnorm_code;

CREATE OR REPLACE TABLE t2d_silver.t2d_rx_episodes AS
WITH ordered AS (
  SELECT *,
         MAX(COALESCE(stop_date, DATE'2999-12-31')) OVER (
           PARTITION BY patient_id, drug_class ORDER BY start_date, stop_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_stop
  FROM t2d_silver.t2d_rx
), flagged AS (
  SELECT *, CASE WHEN prev_max_stop IS NULL OR start_date > prev_max_stop + 1 THEN 1 ELSE 0 END AS new_episode
  FROM ordered
), numbered AS (
  SELECT *, SUM(new_episode) OVER (
           PARTITION BY patient_id, drug_class ORDER BY start_date, stop_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS episode_no
  FROM flagged
)
SELECT patient_id, drug_class,
       MIN(route)            AS route,
       MIN(guideline_step)   AS guideline_step,
       episode_no,
       MIN(start_date)       AS episode_start,
       CASE WHEN MAX(CASE WHEN stop_date IS NULL THEN 1 ELSE 0 END) = 1 THEN NULL ELSE MAX(stop_date) END AS episode_end,
       COUNT(*)              AS n_records,
       SUM(total_cost)       AS total_cost,
       SUM(payer_coverage)   AS payer_coverage
FROM numbered
GROUP BY patient_id, drug_class, episode_no;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Apply the rules and keep an attrition table

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_silver.cohort_candidates AS
WITH dx AS (
  SELECT patient_id, MIN(start_date) AS dx_date
  FROM t2d_silver.conditions
  WHERE snomed_code = '44054006'
  GROUP BY patient_id
), first_rx AS (
  SELECT patient_id, MIN(episode_start) AS first_any_rx_date
  FROM t2d_silver.t2d_rx_episodes
  GROUP BY patient_id
)
SELECT d.patient_id, d.dx_date, p.birth_date, p.death_date, p.gender, p.race, p.ethnicity, p.income,
       CAST(FLOOR(datediff(d.dx_date, p.birth_date) / 365.25) AS INT) AS age_at_dx,
       f.first_any_rx_date,
       sp.data_cutoff_date,
       CASE WHEN d.dx_date >= sp.index_window_start AND d.dx_date <= sp.data_cutoff_date - 365 THEN 1 ELSE 0 END AS r2_window,
       CASE WHEN FLOOR(datediff(d.dx_date, p.birth_date) / 365.25) >= 18 THEN 1 ELSE 0 END AS r3_adult,
       CASE WHEN f.first_any_rx_date IS NULL OR f.first_any_rx_date >= d.dx_date - 30 THEN 1 ELSE 0 END AS r4_new_user,
       CASE WHEN f.first_any_rx_date IS NOT NULL AND f.first_any_rx_date <= sp.data_cutoff_date
                 AND (p.death_date IS NULL OR f.first_any_rx_date <= p.death_date) THEN 1 ELSE 0 END AS r5_treated
FROM dx d
JOIN t2d_silver.patients p ON d.patient_id = p.patient_id
LEFT JOIN first_rx f ON d.patient_id = f.patient_id
CROSS JOIN t2d_silver.study_params sp;

CREATE OR REPLACE TABLE t2d_silver.cohort_attrition AS
SELECT 0 AS step, 'All synthetic patients'                                   AS rule, (SELECT COUNT(*) FROM t2d_silver.patients) AS n_patients
UNION ALL SELECT 1, 'R1 T2D diagnosis (SNOMED 44054006)',                     COUNT(*) FROM t2d_silver.cohort_candidates
UNION ALL SELECT 2, 'R2 Index dx 2010-01-01 to cut-off minus 365d',           SUM(r2_window) FROM t2d_silver.cohort_candidates
UNION ALL SELECT 3, 'R3 Age 18+ at index dx',                                 SUM(r2_window * r3_adult) FROM t2d_silver.cohort_candidates
UNION ALL SELECT 4, 'R4 New user (no T2D drug > 30d before dx)',              SUM(r2_window * r3_adult * r4_new_user) FROM t2d_silver.cohort_candidates
UNION ALL SELECT 5, 'R5 Started a T2D drug (final cohort)',                   SUM(r2_window * r3_adult * r4_new_user * r5_treated) FROM t2d_silver.cohort_candidates;

-- COMMAND ----------

SELECT * FROM t2d_silver.cohort_attrition ORDER BY step;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Final cohort with baseline features
-- MAGIC * **Comorbidities** (active on the index diagnosis date): hypertension, hyperlipidaemia, chronic kidney disease, obesity (BMI 30+), cardiovascular disease (ischaemic heart disease, MI, stroke, heart failure, AF).
-- MAGIC * **Engagement:** encounters in the 365 days before diagnosis.
-- MAGIC * **Pill burden:** distinct non-T2D drugs active on the index treatment date.
-- MAGIC * **Out-of-pocket share:** 1 − payer coverage ÷ total cost across the patient's T2D drug records.
-- MAGIC
-- MAGIC The last three feed the refill-behaviour layer in notebook 04 as `high_oop` (top tertile), `high_pill_burden` (≥ 3 drugs) and `low_engagement` (below cohort median).

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_silver.t2d_cohort AS
WITH c AS (
  SELECT * FROM t2d_silver.cohort_candidates
  WHERE r2_window = 1 AND r3_adult = 1 AND r4_new_user = 1 AND r5_treated = 1
), idx AS (   -- index treatment = earliest episode; ties broken by guideline step
  SELECT patient_id, drug_class AS first_tx_class, route AS first_tx_route, episode_start AS first_tx_date
  FROM t2d_silver.t2d_rx_episodes
  QUALIFY ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY episode_start, guideline_step) = 1
), comorb AS (
  SELECT c.patient_id,
    MAX(CASE WHEN lower(k.description) LIKE '%hypertension%' THEN 1 ELSE 0 END) AS has_hypertension,
    MAX(CASE WHEN lower(k.description) LIKE '%hyperlipidemia%' OR lower(k.description) LIKE '%hypertriglyceridemia%' THEN 1 ELSE 0 END) AS has_hyperlipidemia,
    MAX(CASE WHEN lower(k.description) LIKE '%chronic kidney disease%' THEN 1 ELSE 0 END) AS has_ckd,
    MAX(CASE WHEN lower(k.description) LIKE '%body mass index 30+%' OR lower(k.description) LIKE '%obesity%' THEN 1 ELSE 0 END) AS has_obesity,
    MAX(CASE WHEN lower(k.description) LIKE '%ischemic heart disease%' OR lower(k.description) LIKE '%myocardial infarction%'
              OR lower(k.description) LIKE '%stroke%' OR lower(k.description) LIKE '%heart failure%'
              OR lower(k.description) LIKE '%atrial fibrillation%' THEN 1 ELSE 0 END) AS has_cvd
  FROM c
  LEFT JOIN t2d_silver.conditions k
    ON k.patient_id = c.patient_id AND k.start_date <= c.dx_date
   AND (k.stop_date IS NULL OR k.stop_date >= c.dx_date)
  GROUP BY c.patient_id
), engage AS (
  SELECT c.patient_id, COUNT(e.encounter_id) AS baseline_encounters_365
  FROM c LEFT JOIN t2d_silver.encounters e
    ON e.patient_id = c.patient_id AND e.start_date < c.dx_date AND e.start_date >= c.dx_date - 365
  GROUP BY c.patient_id
), other_meds AS (
  SELECT m.* FROM t2d_silver.medications m
  LEFT JOIN t2d_silver.ref_t2d_drugs r ON m.rxnorm_code = r.rxnorm_code
  WHERE r.rxnorm_code IS NULL
), pills AS (
  SELECT i.patient_id, COUNT(DISTINCT m.rxnorm_code) AS pill_burden
  FROM idx i LEFT JOIN other_meds m
    ON m.patient_id = i.patient_id AND m.start_date <= i.first_tx_date
   AND (m.stop_date IS NULL OR m.stop_date > i.first_tx_date)
  GROUP BY i.patient_id
), oop AS (
  SELECT patient_id,
         CASE WHEN SUM(total_cost) > 0 THEN 1 - SUM(payer_coverage) / SUM(total_cost) END AS oop_share
  FROM t2d_silver.t2d_rx GROUP BY patient_id
), assembled AS (
  SELECT c.patient_id, c.dx_date, c.age_at_dx,
         CASE WHEN c.age_at_dx < 45 THEN '18-44' WHEN c.age_at_dx < 65 THEN '45-64' ELSE '65+' END AS age_band,
         c.gender, c.race, c.ethnicity, c.income, c.death_date, c.data_cutoff_date,
         LEAST(COALESCE(c.death_date, c.data_cutoff_date), c.data_cutoff_date) AS censor_date,
         i.first_tx_date, i.first_tx_class, i.first_tx_route,
         datediff(i.first_tx_date, c.dx_date) AS days_to_first_tx,
         m.has_hypertension, m.has_hyperlipidemia, m.has_ckd, m.has_obesity, m.has_cvd,
         m.has_hypertension + m.has_hyperlipidemia + m.has_ckd + m.has_obesity + m.has_cvd AS n_comorbidities,
         e.baseline_encounters_365, p.pill_burden, o.oop_share
  FROM c
  JOIN idx i    ON c.patient_id = i.patient_id
  JOIN comorb m ON c.patient_id = m.patient_id
  JOIN engage e ON c.patient_id = e.patient_id
  JOIN pills p  ON c.patient_id = p.patient_id
  LEFT JOIN oop o ON c.patient_id = o.patient_id
)
SELECT a.*,
       CASE WHEN n_comorbidities <= 1 THEN '0-1' WHEN n_comorbidities = 2 THEN '2' ELSE '3+' END AS comorbidity_band,
       CASE WHEN NTILE(3) OVER (ORDER BY COALESCE(oop_share, 0), patient_id) = 3 THEN 1 ELSE 0 END AS high_oop,
       CASE WHEN pill_burden >= 3 THEN 1 ELSE 0 END AS high_pill_burden,
       CASE WHEN baseline_encounters_365 < (SELECT median(baseline_encounters_365) FROM assembled) THEN 1 ELSE 0 END AS low_engagement
FROM assembled a;

-- COMMAND ----------

SELECT COUNT(*) AS cohort_n,
       ROUND(AVG(age_at_dx), 1) AS mean_age,
       ROUND(AVG(CASE WHEN gender = 'Female' THEN 1.0 ELSE 0 END), 3) AS pct_female,
       ROUND(AVG(n_comorbidities), 2) AS mean_comorbidities,
       median(days_to_first_tx) AS median_days_to_tx
FROM t2d_silver.t2d_cohort;
