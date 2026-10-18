-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 08 · Analysis (SQL) — questions a brand team asks
-- MAGIC All queries run against Gold only. Headline persistency = `scenario = 'simulated'`, `level = 'any_therapy'`, `grace_days = 60`.

-- COMMAND ----------

USE CATALOG workspace;

-- COMMAND ----------

-- MAGIC %md ### Q1. How big is the treated cohort and who is in it?

-- COMMAND ----------

SELECT COUNT(*)                                                     AS patients,
       ROUND(AVG(age_at_dx), 1)                                     AS mean_age_at_dx,
       ROUND(100 * AVG(CASE WHEN gender = 'Female' THEN 1 ELSE 0 END), 1) AS pct_female,
       ROUND(100 * AVG(has_hypertension), 1)                        AS pct_hypertension,
       ROUND(100 * AVG(has_hyperlipidemia), 1)                      AS pct_hyperlipidemia,
       ROUND(100 * AVG(has_obesity), 1)                             AS pct_obesity,
       ROUND(100 * AVG(has_ckd), 1)                                 AS pct_ckd,
       ROUND(100 * AVG(has_cvd), 1)                                 AS pct_cvd,
       median(followup_days)                                        AS median_followup_days
FROM t2d_gold.patient_journey;

-- COMMAND ----------

-- MAGIC %md ### Q2. How long from diagnosis to first treatment, and does it differ by segment?

-- COMMAND ----------

SELECT time_to_tx_bucket, COUNT(*) AS patients,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM t2d_gold.patient_journey
GROUP BY time_to_tx_bucket
ORDER BY MIN(days_to_first_tx);

-- COMMAND ----------

SELECT 'age_band' AS segment_type, age_band AS segment, COUNT(*) AS patients,
       median(days_to_first_tx) AS median_days_to_tx,
       ROUND(100 * AVG(CASE WHEN days_to_first_tx <= 30 THEN 1 ELSE 0 END), 1) AS pct_treated_within_30d
FROM t2d_gold.patient_journey GROUP BY age_band
UNION ALL
SELECT 'gender', gender, COUNT(*), median(days_to_first_tx),
       ROUND(100 * AVG(CASE WHEN days_to_first_tx <= 30 THEN 1 ELSE 0 END), 1)
FROM t2d_gold.patient_journey GROUP BY gender
UNION ALL
SELECT 'comorbidities', comorbidity_band, COUNT(*), median(days_to_first_tx),
       ROUND(100 * AVG(CASE WHEN days_to_first_tx <= 30 THEN 1 ELSE 0 END), 1)
FROM t2d_gold.patient_journey GROUP BY comorbidity_band
ORDER BY segment_type, segment;

-- COMMAND ----------

-- MAGIC %md ### Q3. What do treatment journeys look like? (first line → second line)

-- COMMAND ----------

SELECT first_tx_class,
       COALESCE(line2_class, '(no 2nd line yet)') AS second_line,
       COALESCE(line2_type, '-')                  AS how,
       COUNT(*)                                   AS patients,
       median(days_to_line2)                      AS median_days_to_line2
FROM t2d_gold.patient_journey
GROUP BY first_tx_class, line2_class, line2_type
ORDER BY patients DESC;

-- COMMAND ----------

SELECT journey_path, COUNT(*) AS patients,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM t2d_gold.patient_journey
GROUP BY journey_path ORDER BY patients DESC LIMIT 10;

-- COMMAND ----------

-- MAGIC %md ### Q4. Headline persistency (Kaplan-Meier) — recorded vs simulated

-- COMMAND ----------

SELECT scenario, level, n_patients, pct_persistent_90d, pct_persistent_180d, pct_persistent_365d,
       ci_low_365d, ci_high_365d, median_days_on_therapy
FROM t2d_gold.persistency_summary
WHERE grace_days = 60 AND segment_type = 'Overall'
ORDER BY scenario DESC, level;

-- COMMAND ----------

-- MAGIC %md ### Q5. Persistency by segment (simulated, any therapy, 60-day grace)

-- COMMAND ----------

SELECT segment_type, segment_value, n_patients,
       pct_persistent_90d, pct_persistent_180d, pct_persistent_365d, ci_low_365d, ci_high_365d
FROM t2d_gold.persistency_summary
WHERE scenario = 'simulated' AND level = 'any_therapy' AND grace_days = 60
ORDER BY segment_type, segment_value;

-- COMMAND ----------

-- MAGIC %md ### Q6. How sensitive is the answer to the grace-period assumption?

-- COMMAND ----------

SELECT grace_days, level, pct_persistent_90d, pct_persistent_180d, pct_persistent_365d
FROM t2d_gold.persistency_summary
WHERE scenario = 'simulated' AND segment_type = 'Overall'
ORDER BY level, grace_days;

-- COMMAND ----------

-- MAGIC %md ### Q7. When do discontinuations happen, and how many patients come back?

-- COMMAND ----------

SELECT CASE WHEN days_on_therapy < 90 THEN '0-89 d' WHEN days_on_therapy < 180 THEN '90-179 d'
            WHEN days_on_therapy < 365 THEN '180-364 d' ELSE '365+ d' END AS discontinued_in,
       COUNT(*) AS patients,
       ROUND(100 * AVG(restarted_later), 1) AS pct_restarted_later
FROM t2d_gold.persistency_patient
WHERE scenario = 'simulated' AND level = 'any_therapy' AND grace_days = 60 AND discontinued = 1
GROUP BY 1 ORDER BY MIN(days_on_therapy);

-- COMMAND ----------

-- MAGIC %md ### Q8. Do the refill-layer drivers behave as designed? (validation check, not a finding)
-- MAGIC Out-of-pocket share, engagement and pill burden are **inputs** to the simulated refill layer, so differences here confirm the layer works. On real claims data, this same query becomes the driver analysis.

-- COMMAND ----------

SELECT 'High out-of-pocket share' AS driver, high_oop AS flag, COUNT(*) AS patients,
       ROUND(100 * AVG(CASE WHEN discontinued = 1 AND days_on_therapy < 180 THEN 1 ELSE 0 END), 1) AS pct_early_discontinuation
FROM t2d_gold.persistency_patient WHERE scenario = 'simulated' AND level = 'any_therapy' AND grace_days = 60 GROUP BY high_oop
UNION ALL
SELECT 'Low prior-year engagement', low_engagement, COUNT(*),
       ROUND(100 * AVG(CASE WHEN discontinued = 1 AND days_on_therapy < 180 THEN 1 ELSE 0 END), 1)
FROM t2d_gold.persistency_patient WHERE scenario = 'simulated' AND level = 'any_therapy' AND grace_days = 60 GROUP BY low_engagement
UNION ALL
SELECT 'High pill burden (3+ other drugs)', high_pill_burden, COUNT(*),
       ROUND(100 * AVG(CASE WHEN discontinued = 1 AND days_on_therapy < 180 THEN 1 ELSE 0 END), 1)
FROM t2d_gold.persistency_patient WHERE scenario = 'simulated' AND level = 'any_therapy' AND grace_days = 60 GROUP BY high_pill_burden
ORDER BY driver, flag;
