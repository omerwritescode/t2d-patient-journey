"""Kaplan-Meier persistency curves (no external dependencies beyond pandas/numpy)."""
from __future__ import annotations

import numpy as np
import pandas as pd


def km_curve(durations, events, max_day: int = 730) -> pd.DataFrame:
    """Daily Kaplan-Meier survival from day 0..max_day with Greenwood 95% CI."""
    d = np.asarray(durations, dtype=float)
    e = np.asarray(events, dtype=int)
    n0 = len(d)
    rows, s, var_sum = [], 1.0, 0.0
    for day in range(0, max_day + 1):
        at_risk = int((d >= day).sum())
        ev = int(((d == day) & (e == 1)).sum())
        cens = int(((d == day) & (e == 0)).sum())
        if at_risk > 0 and ev > 0:
            s *= 1 - ev / at_risk
            if at_risk > ev:
                var_sum += ev / (at_risk * (at_risk - ev))
        se = s * np.sqrt(var_sum)
        rows.append((day, at_risk, ev, cens, s, max(0.0, s - 1.96 * se), min(1.0, s + 1.96 * se)))
    out = pd.DataFrame(rows, columns=["day", "n_at_risk", "n_discontinued", "n_censored",
                                      "pct_persistent", "ci_low", "ci_high"])
    out["n_patients"] = n0
    return out


def km_by_segment(df: pd.DataFrame, segment_cols: list[str], max_day: int = 730) -> pd.DataFrame:
    """df needs days_on_therapy, discontinued plus the grouping columns."""
    parts = []
    # overall
    base_keys = [c for c in ["scenario", "level", "grace_days"] if c in df.columns]
    for keys, g in df.groupby(base_keys):
        keys = keys if isinstance(keys, tuple) else (keys,)
        k = dict(zip(base_keys, keys))
        c = km_curve(g["days_on_therapy"], g["discontinued"], max_day)
        parts.append(c.assign(segment_type="Overall", segment_value="All patients", **k))
        for seg in segment_cols:
            for val, gs in g.groupby(seg):
                c = km_curve(gs["days_on_therapy"], gs["discontinued"], max_day)
                parts.append(c.assign(segment_type=seg, segment_value=str(val), **k))
    return pd.concat(parts, ignore_index=True)
