"""Static charts for notebook 09 and the README (matplotlib)."""
from __future__ import annotations

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

SERIES = ["#2a78d6", "#eb6834", "#1baf7a"]   # validated categorical slots 1-3
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"


def _style(ax, title, xlabel, ylabel):
    ax.set_facecolor(SURFACE)
    ax.figure.set_facecolor(SURFACE)
    for s in ["top", "right"]:
        ax.spines[s].set_visible(False)
    for s in ["left", "bottom"]:
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    ax.set_title(title, loc="left", color=INK, fontsize=12, fontweight="bold", pad=12)
    ax.set_xlabel(xlabel, color=INK2, fontsize=9)
    ax.set_ylabel(ylabel, color=INK2, fontsize=9)


def km_plot(km: pd.DataFrame, title: str, path: str, ci: bool = True, max_day: int = 730):
    """km: rows for <=3 curves; needs columns label, day, pct_persistent, ci_low, ci_high."""
    fig, ax = plt.subplots(figsize=(8, 4.9))
    used_y = []
    for i, (label, g) in enumerate(km.groupby("label", sort=False)):
        g = g[g.day <= max_day]
        c = SERIES[i % 3]
        ax.step(g.day, g.pct_persistent * 100, where="post", color=c, linewidth=2, label=label)
        if ci:
            ax.fill_between(g.day, g.ci_low * 100, g.ci_high * 100, step="post", color=c, alpha=0.10, linewidth=0)
        end = g.iloc[-1]
        used_y.append((end.pct_persistent * 100, end.day))
    # end labels, highest first, nudged down so they never overlap and keep their order
    last = None
    for v, day in sorted(used_y, reverse=True):
        y = v if last is None else min(v, last - 4)
        last = y
        ax.annotate(f"{v:.0f}%", (day, y), xytext=(6, 0), textcoords="offset points",
                    color=INK2, fontsize=9, va="center")
    for d in (90, 180, 365):
        ax.axvline(d, color=GRID, linewidth=1, linestyle="--", zorder=0)
        ax.text(d, 104, f"{d}d", color=INK2, fontsize=8, ha="center")
    ax.set_ylim(0, 108)
    ax.set_yticks([0, 20, 40, 60, 80, 100])
    ax.set_xlim(0, max_day + 60)
    _style(ax, title, "Days since first T2D treatment", "% still on therapy")
    ax.legend(frameon=False, fontsize=9, labelcolor=INK2, loc="upper center",
              bbox_to_anchor=(0.5, -0.14), ncol=3)
    fig.tight_layout()
    fig.savefig(path, dpi=160)
    plt.close(fig)


def bar_plot(df: pd.DataFrame, x: str, y: str, title: str, path: str, ylabel: str, fmt: str = "{:.0f}%"):
    fig, ax = plt.subplots(figsize=(8, 4.2))
    bars = ax.bar(df[x].astype(str), df[y], color=SERIES[0], width=0.6)
    for b, v in zip(bars, df[y]):
        ax.text(b.get_x() + b.get_width() / 2, b.get_height(), fmt.format(v), ha="center", va="bottom",
                color=INK2, fontsize=9)
    _style(ax, title, "", ylabel)
    fig.tight_layout()
    fig.savefig(path, dpi=160)
    plt.close(fig)
