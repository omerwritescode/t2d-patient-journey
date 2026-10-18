# T2D Patient Journey & Persistency — Insight Note

**For:** T2D brand team · **Data:** Synthea synthetic EHR, 15,814 adults; treated new-user cohort n = 479, diagnosed 2010–2025, followed to Oct 2026
**Persistency definition:** on any T2D drug; discontinuation = a gap of more than 60 days after supply runs out; Kaplan-Meier, censored at death or data cut-off.

## What we found

1. **The biggest leak is before treatment starts.** 42% of newly diagnosed adults had no T2D drug by the end of follow-up. Of those who were treated, half started on the day of diagnosis, but **48% waited more than a year** (median 3 years). Younger patients waited longest (median 2 years for ages 18–44 vs same day for 45–64).

2. **Patients stay on first-line therapy for years.** 80% start on metformin and 20% go straight to insulin. Only **15% ever add a second class**, a median of 3.8 years after starting. GLP-1 use is about 2% and SGLT2 use is zero; a third of patients end up on insulin.

3. **Half of treated patients are off therapy within a year.** 86% are still on therapy at 90 days, **70% at 180 days and 49% at 365 days**; the median time on therapy is 360 days. The steepest loss is between months 3 and 6. About 40% of those who stop come back later.

4. **The persistency number depends on the definition.** A 30-day grace period gives 25% at one year, 60 days gives 49% and 90 days gives 52%. Many "discontinuations" under 30 days are only late refills.

5. **Younger patients drop off faster.** 12-month persistency is 44% for ages 18–44 vs 57% for 65+. Gender (46% vs 53%) and comorbidity count show no clear difference; their confidence intervals overlap.

## What we recommend

| # | Action | Linked finding |
|---|---|---|
| 1 | **Treat initiation as a KPI alongside persistency.** Target delayed starters, especially under-45s with a diagnosis and no therapy. Use HCP education on early initiation and EHR prompts at the next visit. | 1 |
| 2 | **Put patient support in months 1–6, not year 2.** Use refill reminders at day 25 and a nurse or digital check-in around months 3–4, where the curve falls fastest. | 3 |
| 3 | **Run a win-back programme for lapsed patients.** About 4 in 10 restart on their own, so a structured outreach after 60 days without a refill is likely to convert more. | 3 |
| 4 | **Prioritise adults under 45** for adherence support; they start later and stop sooner. | 1, 5 |
| 5 | **Address the escalation gap.** Few patients move past monotherapy, which leaves room for GLP-1/SGLT2 messaging on timely intensification. | 2 |
| 6 | **Fix the metric before comparing.** Report 60-day-grace Kaplan-Meier persistency on any T2D therapy, and show 30/90-day results alongside, before benchmarking brands or regions. | 4 |

## Read with care
* **Synthetic data.** Treatment pathways follow Synthea's rule-based modules, so journeys are less varied than in real life.
* **Simulated refills.** Synthea never simulates a missed refill: as recorded, persistency is 100%. The persistency figures use a seeded refill-behaviour layer. Its assumptions include lower persistency for younger patients and those with higher out-of-pocket costs, so finding 5's age gap partly reflects those assumptions.
* **What comes straight from Synthea:** cohort size, initiation gap, time to treatment, treatment lines and insulin use.
* **On real claims data** the same pipeline runs with actual fills in place of the simulation, and every number above would be re-estimated.
