# Databricks notebook source
# MAGIC %md
# MAGIC # 07 · Gold — Kaplan-Meier persistency curves
# MAGIC
# MAGIC Kaplan-Meier treats patients censored by death or data cut-off correctly, so it is the headline persistency measure.
# MAGIC
# MAGIC Outputs:
# MAGIC * `t2d_gold.persistency_km` — daily curve (day 0–730) by scenario, level, grace period and segment. **This feeds the dashboard persistency curve.**
# MAGIC * `t2d_gold.persistency_summary` — % persistent at 90 / 180 / 365 days and median days on therapy per segment.
# MAGIC
# MAGIC Segments are computed for the 60-day grace period; 30 and 90 days get the overall curve only (sensitivity).

# COMMAND ----------

import os, sys
repo_root = os.path.abspath(os.path.join(os.getcwd(), ".."))
if repo_root not in sys.path:
    sys.path.append(repo_root)

import pandas as pd
from lib.survival import km_by_segment

spark.sql("USE CATALOG workspace")
pp = spark.table("t2d_gold.persistency_patient").toPandas()

SEGMENTS = ["age_band", "gender", "comorbidity_band", "first_tx_class"]

km_60 = km_by_segment(pp[pp.grace_days == 60], SEGMENTS)
km_sens = km_by_segment(pp[pp.grace_days != 60], [])
km = pd.concat([km_60, km_sens], ignore_index=True)

# COMMAND ----------

def summarise(km: pd.DataFrame) -> pd.DataFrame:
    keys = ["scenario", "level", "grace_days", "segment_type", "segment_value"]
    rows = []
    for k, g in km.groupby(keys):
        g = g.set_index("day")
        below = g[g.pct_persistent <= 0.5]
        rows.append(dict(zip(keys, k),
                         n_patients=int(g.n_patients.iloc[0]),
                         pct_persistent_90d=round(g.loc[90, "pct_persistent"] * 100, 1),
                         pct_persistent_180d=round(g.loc[180, "pct_persistent"] * 100, 1),
                         pct_persistent_365d=round(g.loc[365, "pct_persistent"] * 100, 1),
                         ci_low_365d=round(g.loc[365, "ci_low"] * 100, 1),
                         ci_high_365d=round(g.loc[365, "ci_high"] * 100, 1),
                         median_days_on_therapy=float(below.index.min()) if len(below) else float("nan")))
    return pd.DataFrame(rows)

summary = summarise(km)

# COMMAND ----------

(spark.createDataFrame(km).write.mode("overwrite").option("overwriteSchema", "true")
      .saveAsTable("t2d_gold.persistency_km"))
# median is undefined when a curve never drops below 50% -> store NULL, not NaN
(spark.createDataFrame(summary)
      .selectExpr("*", "CASE WHEN isnan(median_days_on_therapy) THEN NULL "
                       "ELSE CAST(median_days_on_therapy AS INT) END AS median_days")
      .drop("median_days_on_therapy").withColumnRenamed("median_days", "median_days_on_therapy")
      .write.mode("overwrite").option("overwriteSchema", "true")
      .saveAsTable("t2d_gold.persistency_summary"))

display(spark.sql("""
  SELECT * FROM t2d_gold.persistency_summary
  WHERE level = 'any_therapy' AND grace_days = 60
  ORDER BY scenario DESC, segment_type, segment_value
"""))
