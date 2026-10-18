-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 06 · Gold — therapy episodes and persistency
-- MAGIC
-- MAGIC ## Persistency definition (assumption)
-- MAGIC * Each fill covers `days_supply` (30) days. Overlapping supply is not stockpiled; coverage runs to the latest supply end seen so far.
-- MAGIC * **Discontinuation** = the next fill comes more than **60 days** (the grace period) after the end of the supply on hand. The discontinuation date is the end of the last supply.
-- MAGIC * **Days on therapy** = index treatment date → discontinuation date, or → censor date (death or data cut-off) if the patient never breaches the grace period. Patients whose last supply runs out less than 60 days before the censor date are **censored**, not counted as discontinued, because we cannot see whether they would have refilled.
-- MAGIC * Two levels:
-- MAGIC   * `any_therapy` — persistent while on **any** T2D drug (an add-on or switch does not break persistency). **Primary measure.**
-- MAGIC   * `index_class` — persistent on the index drug class only (switching away counts as stopping).
-- MAGIC * Grace periods of **30 and 90 days** are also computed as a sensitivity analysis. The headline numbers use 60.
-- MAGIC * Share persistent at 90/180/365 days: crude share among patients whose outcome at that day is known, and Kaplan-Meier (notebook 07), which uses censored patients properly. **Kaplan-Meier is the headline.**

-- COMMAND ----------

USE CATALOG workspace;

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_gold.therapy_episodes AS
WITH f AS (
  SELECT c.patient_id, f.scenario, 'any_therapy' AS level, f.fill_date, f.days_supply
  FROM t2d_silver.t2d_fills f JOIN t2d_silver.t2d_cohort c ON f.patient_id = c.patient_id
  UNION ALL
  SELECT c.patient_id, f.scenario, 'index_class' AS level, f.fill_date, f.days_supply
  FROM t2d_silver.t2d_fills f JOIN t2d_silver.t2d_cohort c
    ON f.patient_id = c.patient_id AND f.drug_class = c.first_tx_class
), g AS (
  SELECT f.*, t.grace_days FROM f CROSS JOIN (VALUES (30), (60), (90)) AS t(grace_days)
), cover AS (
  SELECT *,
         MAX(fill_date + days_supply) OVER (
           PARTITION BY patient_id, scenario, level, grace_days ORDER BY fill_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_supply_end
  FROM g
), flagged AS (
  SELECT *, CASE WHEN prior_supply_end IS NULL OR fill_date > prior_supply_end + grace_days THEN 1 ELSE 0 END AS new_episode
  FROM cover
), numbered AS (
  SELECT *, SUM(new_episode) OVER (
           PARTITION BY patient_id, scenario, level, grace_days ORDER BY fill_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS episode_no
  FROM flagged
)
SELECT patient_id, scenario, level, grace_days, episode_no,
       MIN(fill_date) AS episode_start,
       MAX(fill_date + days_supply) AS supply_end,
       COUNT(*) AS n_fills
FROM numbered
GROUP BY patient_id, scenario, level, grace_days, episode_no;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### One row per patient × scenario × level × grace period
-- MAGIC Persistency is measured on the **first** episode, starting at the index treatment date.

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_gold.persistency_patient AS
WITH first_ep AS (
  SELECT * FROM t2d_gold.therapy_episodes WHERE episode_no = 1
), later AS (
  SELECT patient_id, scenario, level, grace_days, MIN(episode_start) AS restart_date
  FROM t2d_gold.therapy_episodes WHERE episode_no = 2
  GROUP BY patient_id, scenario, level, grace_days
), base AS (
  SELECT e.patient_id, e.scenario, e.level, e.grace_days,
         e.episode_start AS therapy_start, e.supply_end, e.n_fills,
         c.censor_date, l.restart_date,
         CASE WHEN e.supply_end + e.grace_days <= c.censor_date THEN 1 ELSE 0 END AS discontinued
  FROM first_ep e
  JOIN t2d_silver.t2d_cohort c ON e.patient_id = c.patient_id
  LEFT JOIN later l ON e.patient_id = l.patient_id AND e.scenario = l.scenario
                   AND e.level = l.level AND e.grace_days = l.grace_days
)
SELECT b.*,
       CASE WHEN b.discontinued = 1 THEN b.supply_end END AS discontinuation_date,
       datediff(CASE WHEN b.discontinued = 1 THEN LEAST(b.supply_end, b.censor_date) ELSE b.censor_date END, b.therapy_start) AS days_on_therapy,
       CASE WHEN b.discontinued = 1 AND b.restart_date IS NOT NULL THEN 1 ELSE 0 END AS restarted_later,
       j.gender, j.age_band, j.comorbidity_band, j.first_tx_class, j.race, j.time_to_tx_bucket,
       c.high_oop, c.high_pill_burden, c.low_engagement
FROM base b
JOIN t2d_gold.patient_journey j ON b.patient_id = j.patient_id
JOIN t2d_silver.t2d_cohort c ON b.patient_id = c.patient_id;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ### Crude persistent-at-day flags
-- MAGIC `1` = still on therapy at day N, `0` = discontinued before day N, `NULL` = censored before day N (outcome unknown, excluded from the crude share).

-- COMMAND ----------

CREATE OR REPLACE TABLE t2d_gold.persistency_flags AS
SELECT *,
  CASE WHEN days_on_therapy >= 90  THEN 1 WHEN discontinued = 1 THEN 0 END AS persistent_90d,
  CASE WHEN days_on_therapy >= 180 THEN 1 WHEN discontinued = 1 THEN 0 END AS persistent_180d,
  CASE WHEN days_on_therapy >= 365 THEN 1 WHEN discontinued = 1 THEN 0 END AS persistent_365d
FROM t2d_gold.persistency_patient;

SELECT scenario, level, grace_days, COUNT(*) AS patients,
       ROUND(AVG(persistent_90d)  * 100, 1) AS pct_90d,
       ROUND(AVG(persistent_180d) * 100, 1) AS pct_180d,
       ROUND(AVG(persistent_365d) * 100, 1) AS pct_365d,
       median(days_on_therapy) AS median_days_on_therapy
FROM t2d_gold.persistency_flags
GROUP BY scenario, level, grace_days
ORDER BY scenario DESC, level, grace_days;
