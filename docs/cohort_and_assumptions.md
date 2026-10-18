# Cohort rules and analytical assumptions

## Data
* **Source:** Synthea (open-source synthetic EHR generator), Massachusetts module, adults aged 30–85 at generation, full lifetime history exported (`exporter.years_of_history = 0`). Two seeded runs merged (seeds 2026 and 9999). Files used: `patients`, `conditions`, `medications`, `encounters`.
* **Data cut-off:** latest prescription start date in the extract (2026-10-18) (stored in `t2d_silver.study_params`).
* All records are synthetic. Identifier columns are still dropped in Silver, as they would be for real data.

## Silver cleaning rules
| Rule | Detail |
|---|---|
| Typing | ISO timestamps truncated to `DATE`; costs to `DECIMAL`; counts to `INT`; `try_cast` so bad values become `NULL` rather than failing |
| De-duplication | `patients` and `encounters` on Id; `conditions` on (patient, code, start); `medications` on (patient, code, start) |
| Required fields | rows without patient id or start date dropped |
| PII | SSN, driver's licence, passport, names, address, lat/lon not carried into Silver |

## Cohort (T2D, diagnosed and treated, new users)
| # | Rule |
|---|---|
| R1 | SNOMED **44054006** *Diabetes mellitus type 2*; index diagnosis = first occurrence |
| R2 | Index diagnosis from **2010-01-01** to **cut-off − 365 days** |
| R3 | Age ≥ 18 at index diagnosis |
| R4 | No T2D drug started more than 30 days before diagnosis (new users only) |
| R5 | Starts a T2D drug on/after diagnosis − 30 days and before cut-off/death |

**T2D drug classes** (all RxNorm codes Synthea's metabolic-syndrome module prescribes): metformin (biguanide), liraglutide (GLP-1 RA), canagliflozin (SGLT2 inhibitor), NPH/regular 70/30 insulin (basal/premix), insulin lispro (prandial).

**Baseline** (on or before index): comorbidities (hypertension, hyperlipidaemia, CKD, obesity BMI 30+, cardiovascular disease), encounters in the prior 365 days, other drugs active at first treatment.

## Journey definitions
* **Therapy episode:** consecutive Synthea records of one drug class merged when the next start is ≤ 1 day after the previous stop.
* **First treatment:** earliest episode start on/after diagnosis − 30 days. **Time to treatment** = first treatment − diagnosis (days).
* **Add-on:** a new class starts while the earlier classes continue.
* **Switch:** a new class starts within ±30 days of another class ending.
* **Same-day combo:** a second class starts on the first treatment date.
* **Stop:** a class episode ends before the censor date and is not restarted within 30 days.

## Persistency definitions
* **Fill:** 30-day supply. **Grace period:** **60 days** (headline); 30 and 90 days as sensitivity.
* **Discontinuation:** a gap of more than the grace period between the end of supply on hand and the next fill. Discontinuation date = end of last supply.
* **Censoring:** death or data cut-off. Patients whose supply runs out less than one grace period before censoring are censored, not discontinued.
* **Levels:** `any_therapy` (headline — add-ons/switches keep you persistent) and `index_class`.
* **Reporting:** Kaplan-Meier % persistent at 90 / 180 / 365 days with Greenwood 95% CIs; crude shares among patients with a known outcome are in `persistency_flags`.

## The refill-behaviour layer (important)
Synthea writes chronic prescriptions as back-to-back periods; it never simulates a missed refill. On the raw (**recorded**) data every patient is persistent until Synthea itself ends a drug or the patient dies, so persistency is ~100%.

To make the persistency method meaningful, `lib/refill_sim.py` converts each episode into 30-day fills with seeded refill behaviour (**simulated** scenario):

| Parameter | Value | Note |
|---|---|---|
| Lapse probability per fill (base) | metformin 5.2%, GLP-1 7.8%, SGLT2 6.2%, basal insulin 4.7%, prandial 5.5% | Injectable GLP-1 highest, insulin lowest |
| Age 18–44 / 65+ | × 1.35 / × 0.85 | |
| Top tertile out-of-pocket share (from Synthea costs) | × 1.30 | |
| ≥ 3 other drugs at first treatment (pill burden) | × 1.15 | |
| Fewer encounters than cohort median in prior year | × 1.25 | |
| Patient random effect | lognormal, σ = 0.35 | |
| Late refills (not lapses) | 15% of refills, 8–45 days late; others 0–7 days | Drives the grace-period sensitivity |
| Lapse length | 61 + lognormal(4.0, 0.6) days | |
| Restart after lapse | 35% | |
| Seed | 20261018 | |

These are **assumptions**, tuned so 12-month persistency lands in the broad range reported for real-world T2D therapy. Consequences:
* Overall persistency levels and the **age** and **driver** gradients in the simulated scenario are produced by these parameters and should be read as a demonstration of the method, not as evidence.
* **Gender** and **comorbidity** have no direct parameter; any difference there comes indirectly through correlated drivers (pill burden, engagement, age).
* Cohort size, time to treatment, treatment lines, switches, insulin progression and the recorded scenario come straight from Synthea.
* On real pharmacy-claims data, drop notebook 04 and feed actual fills into `t2d_silver.t2d_fills`; notebooks 05–09 run unchanged.
