# Databricks notebook source
# MAGIC %md
# MAGIC # 04 · Silver — pharmacy fills (recorded vs refill-simulated)
# MAGIC
# MAGIC **The data problem:** Synthea writes chronic prescriptions as contiguous periods. It never simulates a patient missing a refill, so a gap-based persistency rule never fires on the raw data.
# MAGIC
# MAGIC **What this notebook does:** expands each T2D therapy episode (from notebook 03) into 30-day fills, twice:
# MAGIC
# MAGIC | scenario | meaning |
# MAGIC |---|---|
# MAGIC | `recorded` | a fill every 30 days for the whole Synthea episode — persistency exactly as Synthea implies |
# MAGIC | `simulated` | the same episodes with seeded refill behaviour: late refills, lapses longer than the grace period, some restarts |
# MAGIC
# MAGIC In the simulated scenario the chance of a lapse after each fill is a class base rate × drivers taken from the Synthea record (age band, out-of-pocket share, pill burden, prior-year engagement) × a patient-level random effect. Parameters live in `lib/refill_sim.py → PARAMS` and are **assumptions**, tuned so 12-month persistency lands in the range typically reported for real-world T2D therapy. Segment differences in the simulated scenario partly reflect these assumptions; that is stated in the insight note.
# MAGIC
# MAGIC Fills only fall **inside** Synthea episodes, so Synthea's own clinical events (GLP-1 and SGLT2 stopped when insulin starts, deaths) are kept.

# COMMAND ----------

import os, sys
# lib/ sits next to notebooks/ in the repo (Git folder or workspace files)
repo_root = os.path.abspath(os.path.join(os.getcwd(), ".."))
if repo_root not in sys.path:
    sys.path.append(repo_root)

from lib.refill_sim import build_fills, PARAMS
PARAMS

# COMMAND ----------

spark.sql("USE CATALOG workspace")

episodes = spark.sql("""
    SELECT e.patient_id, e.drug_class, e.episode_start,
           LEAST(COALESCE(e.episode_end, c.censor_date), c.censor_date) AS episode_end_eff
    FROM t2d_silver.t2d_rx_episodes e
    JOIN t2d_silver.t2d_cohort c ON e.patient_id = c.patient_id
    WHERE e.episode_start >= c.first_tx_date
""").toPandas()

drivers = spark.table("t2d_silver.t2d_cohort") \
    .select("patient_id", "age_band", "high_oop", "high_pill_burden", "low_engagement").toPandas()

fills = build_fills(episodes, drivers)
print(f"{len(episodes):,} episodes -> {len(fills):,} fills")
fills.groupby("scenario").size()

# COMMAND ----------

(spark.createDataFrame(fills)
      .selectExpr("patient_id", "drug_class", "scenario", "CAST(fill_seq AS INT) AS fill_seq",
                  "CAST(fill_date AS DATE) AS fill_date", "CAST(days_supply AS INT) AS days_supply")
      .write.mode("overwrite").option("overwriteSchema", "true")
      .saveAsTable("t2d_silver.t2d_fills"))

spark.sql("""COMMENT ON TABLE t2d_silver.t2d_fills IS
  '30-day fills per T2D therapy episode. scenario=recorded: perfect refills as Synthea implies; scenario=simulated: seeded refill behaviour layer (lib/refill_sim.py).'""")

display(spark.sql("""
    SELECT scenario, drug_class, COUNT(DISTINCT patient_id) AS patients, COUNT(*) AS fills
    FROM t2d_silver.t2d_fills GROUP BY scenario, drug_class ORDER BY scenario, drug_class
"""))
