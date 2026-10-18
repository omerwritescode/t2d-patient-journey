"""
Local validation harness.

Runs the exact Databricks notebooks against the Synthea CSVs on a laptop, using
DuckDB in place of Spark. SQL notebooks are parsed cell by cell and a handful of
Spark-only constructs are translated (read_files, datediff, USE CATALOG, ...).
Python notebooks' logic lives in lib/ and is called directly.

usage: python local/run_local.py <synthea_csv_dir> [duckdb_cli_path]
"""
import os
import re
import subprocess
import sys

import pandas as pd

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)
from lib.refill_sim import build_fills  # noqa: E402
from lib.survival import km_by_segment  # noqa: E402

DATA = os.path.abspath(sys.argv[1])
DUCK = sys.argv[2] if len(sys.argv) > 2 else "duckdb"
WORK = os.path.join(ROOT, "local", "work")
os.makedirs(WORK, exist_ok=True)
DB = os.path.join(WORK, "t2d.duckdb")


def _replace_datediff(sql: str) -> str:
    """Spark datediff(end, start) -> DuckDB date_diff('day', start, end), paren-aware."""
    out, i, key = [], 0, "datediff("
    low = sql.lower()
    while True:
        j = low.find(key, i)
        if j == -1:
            out.append(sql[i:])
            return "".join(out)
        out.append(sql[i:j])
        k, depth, args, cur = j + len(key), 1, [], []
        while depth:
            ch = sql[k]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            if ch == "," and depth == 1:
                args.append("".join(cur)); cur = []
            else:
                cur.append(ch)
            k += 1
        args.append("".join(cur))
        end, start = (_replace_datediff(a) for a in args)
        out.append(f"date_diff('day', {start.strip()}, {end.strip()})")
        i = k + 1


def spark_to_duckdb(sql: str) -> str:
    sql = re.sub(r"(?im)^\s*USE CATALOG[^;]*;", "", sql)
    sql = re.sub(r"(?im)^\s*CREATE VOLUME[^;]*;", "", sql)
    sql = re.sub(r"(?i)\s+COMMENT\s+'[^']*'", "", sql)      # inline COMMENT '...' (not COMMENT ON)
    sql = re.sub(r"read_files\('/Volumes/[^']*/([a-z_]+\.csv\*?)'[^)]*\)",
                 lambda m: f"read_csv('{DATA}/{m.group(1)}', header=true, all_varchar=true)", sql)
    sql = sql.replace("_metadata.file_path", "'local'")
    sql = sql.replace("current_timestamp()", "now()")
    return _replace_datediff(sql)


def notebook_sql(path: str) -> str:
    cells = open(path).read().split("-- COMMAND ----------")
    keep = [c for c in cells if "-- MAGIC" not in c]
    return "\n".join(c.replace("-- Databricks notebook source", "") for c in keep)


def duck(sql: str, label: str) -> str:
    f = os.path.join(WORK, f"{label}.sql")
    open(f, "w").write("SET memory_limit='1.5GB'; SET threads=1;\n" + sql)
    r = subprocess.run([DUCK, "-bail", DB], stdin=open(f), capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-3000:], r.stderr[-3000:])
        raise SystemExit(f"FAILED in {label}")
    return r.stdout


def to_pd(query: str, name: str) -> pd.DataFrame:
    f = os.path.join(WORK, f"{name}.csv")
    duck(f"COPY ({query}) TO '{f}' (HEADER, DELIMITER ',');", f"export_{name}")
    return pd.read_csv(f)


def from_pd(df: pd.DataFrame, table: str, casts: str):
    f = os.path.join(WORK, f"{table.replace('.', '_')}.csv")
    df.to_csv(f, index=False)
    duck(f"CREATE OR REPLACE TABLE {table} AS SELECT {casts} FROM read_csv('{f}', header=true);", f"load_{table}")


def run_sql_notebook(name: str):
    print(f"== {name}")
    out = duck(spark_to_duckdb(notebook_sql(os.path.join(ROOT, "notebooks", name))), name.replace(".sql", ""))
    if out.strip():
        print(out[-4000:])


if __name__ == "__main__":
    if os.path.exists(DB):
        os.remove(DB)
    for nb in ["01_bronze_ingest.sql", "02_silver_clean.sql", "03_silver_cohort.sql"]:
        run_sql_notebook(nb)

    print("== 04_silver_refills (python)")
    episodes = to_pd("""
        SELECT e.patient_id, e.drug_class, e.episode_start,
               LEAST(COALESCE(e.episode_end, c.censor_date), c.censor_date) AS episode_end_eff
        FROM t2d_silver.t2d_rx_episodes e JOIN t2d_silver.t2d_cohort c ON e.patient_id = c.patient_id
        WHERE e.episode_start >= c.first_tx_date""", "episodes")
    drivers = to_pd("SELECT patient_id, age_band, high_oop, high_pill_burden, low_engagement FROM t2d_silver.t2d_cohort", "drivers")
    fills = build_fills(episodes, drivers)
    print(f"{len(episodes):,} episodes -> {len(fills):,} fills")
    from_pd(fills, "t2d_silver.t2d_fills",
            "patient_id, drug_class, scenario, CAST(fill_seq AS INT) fill_seq, CAST(fill_date AS DATE) fill_date, CAST(days_supply AS INT) days_supply")

    for nb in ["05_gold_journey.sql", "06_gold_persistency.sql"]:
        run_sql_notebook(nb)

    print("== 07_gold_km_curves (python)")
    exec_ns = {"pd": pd}
    src = open(os.path.join(ROOT, "notebooks", "07_gold_km_curves.py")).read()
    summarise_src = src[src.index("def summarise"):src.index("summary = summarise(km)")]
    exec(summarise_src, exec_ns)
    pp = to_pd("SELECT * FROM t2d_gold.persistency_patient", "persistency_patient")
    segs = ["age_band", "gender", "comorbidity_band", "first_tx_class"]
    km = pd.concat([km_by_segment(pp[pp.grace_days == 60], segs), km_by_segment(pp[pp.grace_days != 60], [])],
                   ignore_index=True)
    summary = exec_ns["summarise"](km)
    from_pd(km, "t2d_gold.persistency_km", "*")
    from_pd(summary, "t2d_gold.persistency_summary", "*")
    print(summary[(summary.level == "any_therapy") & (summary.grace_days == 60)].to_string())

    print("== 09 exports + charts")
    from lib.plots import km_plot, bar_plot
    exp = os.path.join(ROOT, "dashboard", "exports"); img = os.path.join(ROOT, "docs", "img")
    os.makedirs(exp, exist_ok=True); os.makedirs(img, exist_ok=True)
    for t in ["t2d_gold.patient_journey", "t2d_gold.journey_events", "t2d_gold.persistency_patient",
              "t2d_gold.persistency_km", "t2d_gold.persistency_summary", "t2d_silver.cohort_attrition"]:
        to_pd(f"SELECT * FROM {t}", t.split(".")[1]).to_csv(os.path.join(exp, t.split(".")[1] + ".csv"), index=False)
    kmx = pd.read_csv(os.path.join(exp, "persistency_km.csv"))

    def curve(scn, lvl, seg, grace=60):
        d = kmx[(kmx.scenario == scn) & (kmx.level == lvl) & (kmx.grace_days == grace) & (kmx.segment_type == seg)]
        return d.assign(label=d.segment_value)
    km_plot(pd.concat([curve("simulated", "any_therapy", "Overall").assign(label="With refill-behaviour layer"),
                       curve("recorded", "any_therapy", "Overall").assign(label="As recorded by Synthea")]),
            "Persistency on any T2D therapy (60-day grace)", os.path.join(img, "km_overall.png"))
    km_plot(curve("simulated", "any_therapy", "age_band"), "Persistency by age at diagnosis", os.path.join(img, "km_age.png"))
    km_plot(curve("simulated", "any_therapy", "comorbidity_band").assign(label=lambda d: d.label + " comorbidities"),
            "Persistency by comorbidity count", os.path.join(img, "km_comorbidity.png"))
    sens = pd.concat([curve("simulated", "any_therapy", "Overall", g).assign(label=f"{g}-day grace") for g in (30, 60, 90)])
    km_plot(sens, "Sensitivity: how the grace period changes the answer", os.path.join(img, "km_grace.png"), ci=False)
    j = pd.read_csv(os.path.join(exp, "patient_journey.csv"))
    order = ["Same day / before dx", "1-30 days", "31-90 days", "91-365 days", ">1 year"]
    ttt = j.time_to_tx_bucket.value_counts(normalize=True).mul(100).reindex(order).fillna(0).rename_axis("bucket").reset_index(name="pct")
    bar_plot(ttt, "bucket", "pct", "Time from T2D diagnosis to first treatment", os.path.join(img, "time_to_tx.png"), "% of cohort")
    print("DONE")
