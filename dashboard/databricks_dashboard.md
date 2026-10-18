# Databricks AI/BI dashboard — fallback (≈20 min)

Use this if Power BI can't connect. *Dashboards → Create dashboard*, then add the datasets below on the **Data** tab and the widgets on the canvas.

## Datasets (Data tab → Create from SQL)

**ds_km**
```sql
SELECT scenario, level, grace_days, segment_type, segment_value, day,
       pct_persistent, ci_low, ci_high, n_at_risk
FROM workspace.t2d_gold.persistency_km
```

**ds_summary**
```sql
SELECT * FROM workspace.t2d_gold.persistency_summary
```

**ds_journey**
```sql
SELECT patient_id, gender, age_band, comorbidity_band, first_tx_class, days_to_first_tx,
       time_to_tx_bucket,
       CASE time_to_tx_bucket WHEN 'Same day / before dx' THEN 1 WHEN '1-30 days' THEN 2
            WHEN '31-90 days' THEN 3 WHEN '91-365 days' THEN 4 ELSE 5 END AS bucket_order,
       COALESCE(line2_type, 'No 2nd line yet') AS line2_type,
       journey_path, ever_insulin, n_switches
FROM workspace.t2d_gold.patient_journey
```

**ds_attrition**
```sql
SELECT step, rule, n_patients FROM workspace.t2d_silver.cohort_attrition ORDER BY step
```

## Filters (top row, apply to ds_km and ds_summary)
* `scenario` — single value, default **simulated**
* `level` — single value, default **any_therapy**
* `grace_days` — single value, default **60**
* `segment_type` — single value, default **Overall** (page 1) / **age_band** (page 2)

## Page 1 — Persistency
| Widget | Dataset | Settings |
|---|---|---|
| Counter: Cohort size | ds_journey | `COUNT(patient_id)` |
| Counter: % persistent 90 / 180 / 365 d | ds_summary | `pct_persistent_90d` etc., filter segment_type = Overall |
| **Line: persistency curve** | ds_km | X = `day`, Y = `AVG(pct_persistent)`, Color = `segment_value`; format Y as % |
| Table: recorded vs simulated | ds_summary | segment_type = Overall, grace_days = 60, columns scenario, level, 90/180/365 |

## Page 2 — Segments
| Widget | Dataset | Settings |
|---|---|---|
| Line: curve per segment | ds_km | as above, filter segment_type ≠ Overall via the page filter |
| Bar: % persistent at 365 d | ds_summary | X = `segment_value`, Y = `pct_persistent_365d`, tooltip `n_patients`, `ci_low_365d`, `ci_high_365d` |

## Page 3 — Patient journey
| Widget | Dataset | Settings |
|---|---|---|
| Bar: time to first treatment | ds_journey | X = `time_to_tx_bucket` (sort by `bucket_order`), Y = `COUNT(patient_id)` |
| Bar: top journey paths | ds_journey | Y = `journey_path`, X = `COUNT(patient_id)`, top 10 |
| Pie: 2nd-line type | ds_journey | `line2_type` |
| Table: cohort attrition | ds_attrition | all columns |

Publish → share the link or export a PDF for the portfolio.
