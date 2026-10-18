"""
Refill-behaviour layer for Synthea medication records.

WHY THIS EXISTS
---------------
Synthea writes chronic prescriptions as back-to-back periods (STOP of one record
== START of the next). It does not simulate non-adherence, so persistency computed
on raw records is ~100% and the gap rule never fires.

This module turns each Synthea therapy episode into 30-day pharmacy fills:

* scenario = 'recorded'  -> perfect refills every 30 days (what Synthea implies)
* scenario = 'simulated' -> refills with late-refill noise, lapses (>60 day gaps),
                           some restarts, and a per-fill lapse hazard that depends on
                           drug class and on patient drivers taken from the Synthea
                           data itself (age band, out-of-pocket cost share, pill
                           burden, care engagement).

Everything is seeded (numpy PCG64, one stream per patient-episode), so the same
input gives the same fills on Databricks and locally. All parameters are ASSUMPTIONS, set to land in the range of
published real-world T2D persistency (roughly 40-65% on the index drug at 12 months,
injectables lower than orals). They are listed in PARAMS so they can be changed.

Only fills inside a Synthea episode are produced, so Synthea's own clinical events
(e.g. GLP-1 stopped when insulin starts, death) are preserved.
"""
from __future__ import annotations

import hashlib

import numpy as np
import pandas as pd

PARAMS = {
    "seed": 20261018,
    "days_supply": 30,
    # probability that a given refill is followed by a lapse (> grace gap)
    "base_lapse_per_fill": {
        "Biguanide": 0.052,
        "GLP-1 RA": 0.078,
        "SGLT2 inhibitor": 0.062,
        "Insulin (basal/premix)": 0.047,
        "Insulin (prandial)": 0.055,
    },
    # multiplicative drivers (applied to the per-fill lapse probability)
    "mult_age_18_44": 1.35,
    "mult_age_65_plus": 0.85,
    "mult_high_oop": 1.30,          # patient in top tertile of T2D drug out-of-pocket share
    "mult_high_pill_burden": 1.15,  # >= 5 other chronic meds active at index
    "mult_low_engagement": 1.25,    # fewer encounters than cohort median in year before dx
    "frailty_sigma": 0.35,          # patient-level random effect, lognormal
    # ordinary late refills (do not breach a 60-day grace)
    "p_late": 0.15,                 # share of refills that are late
    "late_days_small": (0, 7),      # on-time-ish refills: uniform extra days
    "late_days_large": (8, 45),     # late refills: uniform extra days
    # lapses
    "lapse_extra_days_lognorm": (4.0, 0.6),  # gap beyond supply = 61 + lognormal(mu, sigma)
    "p_restart_after_lapse": 0.35,
}


def _lapse_prob(row: pd.Series, drug_class: str, p: dict) -> float:
    h = p["base_lapse_per_fill"].get(drug_class, 0.045)
    if row["age_band"] == "18-44":
        h *= p["mult_age_18_44"]
    elif row["age_band"] == "65+":
        h *= p["mult_age_65_plus"]
    if row["high_oop"] == 1:
        h *= p["mult_high_oop"]
    if row["high_pill_burden"] == 1:
        h *= p["mult_high_pill_burden"]
    if row["low_engagement"] == 1:
        h *= p["mult_low_engagement"]
    return h


def build_fills(episodes: pd.DataFrame, drivers: pd.DataFrame, params: dict | None = None) -> pd.DataFrame:
    """
    episodes: patient_id, drug_class, episode_start (date), episode_end_eff (date)
              episode_end_eff = Synthea episode end, or the patient's censor date if ongoing.
    drivers : patient_id, age_band, high_oop, high_pill_burden, low_engagement
    returns : patient_id, drug_class, scenario, fill_seq, fill_date, days_supply
    """
    p = dict(PARAMS)
    if params:
        p.update(params)
    ds = p["days_supply"]

    ep = episodes.copy()
    ep["episode_start"] = pd.to_datetime(ep["episode_start"])
    ep["episode_end_eff"] = pd.to_datetime(ep["episode_end_eff"])
    ep = ep.sort_values(["patient_id", "drug_class", "episode_start"]).reset_index(drop=True)

    drv = drivers.drop_duplicates("patient_id").set_index("patient_id")

    def rng_for(*keys) -> np.random.Generator:
        # independent, reproducible stream per key: adding or removing a patient
        # never changes anyone else's simulated fills
        h = int(hashlib.sha256("|".join(map(str, keys)).encode()).hexdigest()[:16], 16)
        return np.random.default_rng([p["seed"], h])

    frailty = {pid: rng_for(pid, "frailty").lognormal(0.0, p["frailty_sigma"])
               for pid in ep["patient_id"].unique()}

    out = []
    for r in ep.itertuples(index=False):
        start, end = r.episode_start, r.episode_end_eff
        if pd.isna(start) or pd.isna(end) or end <= start:
            continue
        # recorded: perfect refills
        t, k = start, 0
        while t < end:
            out.append((r.patient_id, r.drug_class, "recorded", k, t))
            t += pd.Timedelta(days=ds)
            k += 1

        # simulated
        rng = rng_for(r.patient_id, r.drug_class, r.episode_start.date())
        h = min(0.9, _lapse_prob(drv.loc[r.patient_id], r.drug_class, p) * frailty[r.patient_id])
        t, k = start, 0
        while t < end:
            out.append((r.patient_id, r.drug_class, "simulated", k, t))
            k += 1
            if rng.random() < h:  # lapse
                mu, sg = p["lapse_extra_days_lognorm"]
                gap = 61 + int(rng.lognormal(mu, sg))
                if rng.random() < p["p_restart_after_lapse"]:
                    t = t + pd.Timedelta(days=ds + gap)
                else:
                    break  # stops refilling for the rest of this episode
            else:
                lo, hi = p["late_days_large"] if rng.random() < p["p_late"] else p["late_days_small"]
                t = t + pd.Timedelta(days=ds + int(rng.integers(lo, hi + 1)))

    fills = pd.DataFrame(out, columns=["patient_id", "drug_class", "scenario", "fill_seq", "fill_date"])
    fills["fill_date"] = fills["fill_date"].dt.date
    fills["days_supply"] = ds
    return fills
