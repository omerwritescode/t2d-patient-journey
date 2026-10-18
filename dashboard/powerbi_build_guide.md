# Power BI dashboard — build guide (≈45 min)

Three pages: **Persistency**, **Segments**, **Patient journey**. Everything reads from the Gold tables.

## 1. Connect

**Option A — live to Databricks (preferred)**
1. In Databricks: *SQL Warehouses* → your warehouse (Free Edition has one *Serverless Starter Warehouse*) → *Connection details*. Copy **Server hostname** and **HTTP path**.
2. *Settings → Developer → Access tokens* → generate a personal access token.
3. Power BI Desktop → *Get data* → **Azure Databricks** (works for Databricks on AWS/GCP too) → paste hostname + HTTP path → *Import* mode → auth: *Personal Access Token*.
4. Navigator → catalog `workspace` → schema `t2d_gold` → tick:
   `persistency_km`, `persistency_summary`, `patient_journey`, `persistency_patient`, plus `t2d_silver.cohort_attrition`.

**Option B — CSV fallback (if the connection fails)**
Notebook 09 writes the same tables as CSVs to `/Volumes/workspace/t2d_bronze/raw/exports/`. Download them from Catalog Explorer (or use the copies in `dashboard/exports/` in this repo) → *Get data → Text/CSV*.

**Option C — Databricks AI/BI dashboard** — see `databricks_dashboard.md`.

## 2. Model
* No relationships are needed for pages 1–2 (`persistency_km` and `persistency_summary` are pre-aggregated).
* Page 3: relate `persistency_patient[patient_id]` → `patient_journey[patient_id]` (many-to-one, single direction).
* Set `persistency_km[day]` to *Whole number*, `pct_persistent`, `ci_low`, `ci_high` to *Decimal* and format as percentage.

## 3. DAX measures

```DAX
% Persistent = AVERAGE ( persistency_km[pct_persistent] )

% Persistent 90d  = CALCULATE ( [% Persistent], persistency_km[day] = 90 )
% Persistent 180d = CALCULATE ( [% Persistent], persistency_km[day] = 180 )
% Persistent 365d = CALCULATE ( [% Persistent], persistency_km[day] = 365 )

Patients at risk = SUM ( persistency_km[n_at_risk] )

Cohort size = DISTINCTCOUNT ( patient_journey[patient_id] )

Median days to treatment = MEDIAN ( patient_journey[days_to_first_tx] )

% Treated within 30d =
DIVIDE (
    CALCULATE ( [Cohort size], patient_journey[days_to_first_tx] <= 30 ),
    [Cohort size]
)

% Ever on insulin = AVERAGE ( patient_journey[ever_insulin] )

% with a switch =
DIVIDE ( CALCULATE ( [Cohort size], patient_journey[n_switches] > 0 ), [Cohort size] )
```

## 4. Pages

### Page 1 — Persistency
* **Slicers** (top row, single-select): `scenario` (default *simulated*), `level` (default *any_therapy*), `grace_days` (default 60).
* **KPI cards:** Cohort size · % Persistent 90d · 180d · 365d.
* **Line chart — the persistency curve:** X = `day`, Y = `% Persistent`, Legend = `segment_value`. Visual-level filter `segment_type = Overall`. Add `ci_low`/`ci_high` as an *error band* (Format → Error bars → Upper/Lower bound) if your Power BI version supports it. Add constant X-axis lines at 90, 180, 365.
* **Small table:** `persistency_summary` filtered to Overall, both scenarios side by side — this is the "as recorded vs simulated" story.

### Page 2 — Segments
* **Slicer:** `segment_type` (age_band, gender, comorbidity_band, first_tx_class) — single select.
* **Line chart:** same as page 1 but *without* the Overall filter, legend `segment_value` → one curve per segment.
* **Clustered bar:** Axis = `segment_value`, Values = `pct_persistent_90d`, `pct_persistent_180d`, `pct_persistent_365d` from `persistency_summary`. Tooltip: `n_patients`, `ci_low_365d`, `ci_high_365d`.
* Text box: "Segments with fewer than ~50 patients have wide confidence intervals — read direction, not size."

### Page 3 — Patient journey
* **Bar:** `time_to_tx_bucket` × Cohort size (sort by bucket order: add a sort column or use the order in `08_analysis_sql`).
* **Bar (horizontal):** top 10 `journey_path` × Cohort size.
* **Donut or 100% bar:** `line2_type` (ADD_ON / SWITCH / none yet).
* **Cards:** Median days to treatment · % Ever on insulin · % with a switch.
* **Table:** `cohort_attrition` (step, rule, n_patients) — shows the cohort rules were applied.

## 5. Colours
Use one colour per series, in this order, and keep it fixed across pages: `#2A78D6` (blue), `#EB6834` (orange), `#1BAF7A` (aqua). Grey `#52514E` for text, `#E4E3DF` for gridlines. No more than three curves on one chart — use the segment slicer instead.

## 6. Publish
File → Save as `T2D_Persistency.pbix`. Take screenshots of the three pages for the README and your portfolio (`dashboard/screenshots/`).
