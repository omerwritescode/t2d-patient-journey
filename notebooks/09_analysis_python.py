# Databricks notebook source
# MAGIC %md
# MAGIC # 09 · Analysis (Python) — charts and Power BI extracts
# MAGIC
# MAGIC 1. Persistency curves (Kaplan-Meier) and segment charts from the Gold tables.
# MAGIC 2. Segment curves carry 95% Greenwood confidence bands, so small segments read as uncertain rather than as findings.
# MAGIC 3. Writes the Gold tables the dashboard needs as CSVs to the volume, for the Power BI CSV fallback.

# COMMAND ----------

import os, sys
repo_root = os.path.abspath(os.path.join(os.getcwd(), ".."))
if repo_root not in sys.path:
    sys.path.append(repo_root)

import pandas as pd
from lib.plots import km_plot, bar_plot

spark.sql("USE CATALOG workspace")
km = spark.table("t2d_gold.persistency_km").toPandas()
journey = spark.table("t2d_gold.patient_journey").toPandas()
out_dir = "/Volumes/workspace/t2d_bronze/raw/exports"
os.makedirs(out_dir, exist_ok=True)

def curve(scenario, level, seg_type, grace=60):
    d = km[(km.scenario == scenario) & (km.level == level) & (km.grace_days == grace) & (km.segment_type == seg_type)]
    return d.assign(label=d.segment_value)

# COMMAND ----------

# 1. Recorded vs simulated, any therapy
a = curve("recorded", "any_therapy", "Overall").assign(label="As recorded by Synthea")
b = curve("simulated", "any_therapy", "Overall").assign(label="With refill-behaviour layer")
km_plot(pd.concat([b, a]), "Persistency on any T2D therapy (60-day grace)", f"{out_dir}/km_overall.png")

# COMMAND ----------

# 2. By age band and by comorbidity burden (simulated)
km_plot(curve("simulated", "any_therapy", "age_band"), "Persistency by age at diagnosis", f"{out_dir}/km_age.png")
km_plot(curve("simulated", "any_therapy", "comorbidity_band"), "Persistency by comorbidity count", f"{out_dir}/km_comorbidity.png")

# COMMAND ----------

# 3. Time to first treatment
order = ["Same day / before dx", "1-30 days", "31-90 days", "91-365 days", ">1 year"]
ttt = (journey.time_to_tx_bucket.value_counts(normalize=True).mul(100)
       .reindex(order).fillna(0).rename_axis("bucket").reset_index(name="pct"))
bar_plot(ttt, "bucket", "pct", "Time from T2D diagnosis to first treatment", f"{out_dir}/time_to_tx.png", "% of cohort")

# COMMAND ----------

from IPython.display import Image, display as idisplay
for f in ["km_overall", "km_age", "km_comorbidity", "time_to_tx"]:
    idisplay(Image(filename=f"{out_dir}/{f}.png"))

# COMMAND ----------

# MAGIC %md ### CSV extracts for the Power BI fallback

# COMMAND ----------

for t in ["patient_journey", "journey_events", "persistency_patient", "persistency_km", "persistency_summary"]:
    spark.table(f"t2d_gold.{t}").toPandas().to_csv(f"{out_dir}/{t}.csv", index=False)
spark.table("t2d_silver.cohort_attrition").toPandas().to_csv(f"{out_dir}/cohort_attrition.csv", index=False)
os.listdir(out_dir)
