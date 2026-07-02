#!/usr/bin/env python3
"""
analyze_fidelity.py — Horus NFE Architectural Fidelity Analysis

Reads fidelity_benchmark.csv produced by tb_fidelity_benchmark.v and:
  • Computes Mean Relative Error (MRE) over the deep chain
  • Plots Horus running state vs FP64 golden model
  • Identifies the first cycle where relative error exceeds 1%

Usage:
    python3 analyze_fidelity.py [csv_path]

Outputs:
    fidelity_plot.png       — Horus vs Golden time series
    fidelity_error_plot.png — Relative error (%) vs cycle
    stdout summary          — MRE, 1%% threshold crossing, accum_reg note
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

EXP_BIAS = 32
THRESHOLD_PCT = 1.0
CSV_DEFAULT = Path("fidelity_benchmark.csv")


def nfe_decode(codeword: int) -> float:
    """Decode 13-bit NFE v3 codeword to float."""
    cw = int(codeword) & 0x1FFF
    s = (cw >> 12) & 1
    e = (cw >> 6) & 0x3F
    f = cw & 0x3F
    mag = (1.0 + f / 64.0) * (2.0 ** (e - EXP_BIAS))
    return -mag if s else mag


def load_csv(path: Path) -> dict[str, np.ndarray]:
    cycles, horus, golden, accum = [], [], [], []
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            cycles.append(int(row["cycle_number"]))
            horus.append(float(row["horus_output"]))
            golden.append(float(row["golden_fp64"]))
            accum.append(int(row["accum_reg"]))
    return {
        "cycle": np.array(cycles, dtype=np.int64),
        "horus": np.array(horus, dtype=np.float64),
        "golden": np.array(golden, dtype=np.float64),
        "accum_reg": np.array(accum, dtype=np.uint32),
    }


def relative_error_pct(horus: np.ndarray, golden: np.ndarray) -> np.ndarray:
    denom = np.abs(golden)
    denom = np.where(denom < 1e-30, 1.0, denom)
    err = 100.0 * np.abs(horus - golden) / denom
    return np.where(np.isfinite(err), err, np.nan)


def mre(error_pct: np.ndarray, skip_cycle0: bool = True) -> float:
    e = error_pct[1:] if skip_cycle0 and len(error_pct) > 1 else error_pct
    finite = e[np.isfinite(e)]
    return float(np.mean(finite)) if len(finite) else float("nan")


def first_threshold_crossing(cycles: np.ndarray, error_pct: np.ndarray,
                             threshold: float) -> int | None:
    mask = np.isfinite(error_pct) & (error_pct > threshold)
    if not np.any(mask):
        return None
    return int(cycles[np.argmax(mask)])


def accum_reg_float_proxy(accum_reg: np.ndarray, horus_state: np.ndarray) -> np.ndarray:
    """
    accum_reg holds integer sum of 13-bit result codewords, not a float.
    For drift visualization we compare golden state error against the
    per-cycle hardware state (horus_output) — the primary fidelity metric.
    This helper reports how far the raw integer sum deviates from a naive
    decode(accum_reg & 0x1FFF) misinterpretation (always invalid for
    multi-event sums, shown for documentation only).
    """
    naive_decode = np.array([nfe_decode(int(a) & 0x1FFF) for a in accum_reg])
    return naive_decode


def main() -> int:
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else CSV_DEFAULT
    if not csv_path.exists():
        print(f"ERROR: CSV not found: {csv_path}")
        print("Run: iverilog -Wall -g2012 -o sim_fidelity tb_fidelity_benchmark.v horus_nfe.v && vvp sim_fidelity")
        return 1

    data = load_csv(csv_path)
    cycles = data["cycle"]
    horus = data["horus"]
    golden = data["golden"]
    accum = data["accum_reg"]

    err_pct = relative_error_pct(horus, golden)
    mean_rel_err = mre(err_pct)
    cross = first_threshold_crossing(cycles, err_pct, THRESHOLD_PCT)

    print("=" * 60)
    print("  Horus NFE — Architectural Fidelity Report")
    print("=" * 60)
    print(f"  Source CSV     : {csv_path.resolve()}")
    print(f"  Chain depth    : {len(cycles) - 1} ADD cycles (+ baseline cycle 0)")
    print(f"  Final Horus    : {horus[-1]:.12g}")
    print(f"  Final Golden   : {golden[-1]:.12g}")
    print(f"  Final rel err  : {err_pct[-1]:.6f} %")
    print(f"  Mean Rel Error : {mean_rel_err:.6f} %  (MRE, cycles 1..N)")
    print(f"  Max rel err    : {float(np.nanmax(err_pct[1:])):.6f} %")
    print(f"  accum_reg (raw): {int(accum[-1])}  (0x{int(accum[-1]):08X})")
    print()
    if cross is not None:
        print(f"  *** 1% threshold crossed at cycle {cross} ***")
        idx = int(np.where(cycles == cross)[0][0])
        print(f"      Horus={horus[idx]:.10g}  Golden={golden[idx]:.10g}  err={err_pct[idx]:.4f}%")
    else:
        print(f"  1% threshold NOT crossed within {cycles[-1]} cycles.")
    print()
    print("  Note: accum_reg is an integer sum of 13-bit codewords.")
    print("        State fidelity is measured via decode(result) vs FP64 golden.")
    print("        Codeword-integer drift is a separate event-counter semantics.")
    print("=" * 60)

    # ── Plot 1: Horus vs Golden ──────────────────────────────────────────────
    fig, ax = plt.subplots(figsize=(11, 5))
    ax.plot(cycles, golden, label="Golden FP64 (ideal chain)", color="#2563eb", linewidth=1.5)
    ax.plot(cycles, horus, label="Horus (decode(result) feedback state)", color="#dc2626",
            linewidth=1.2, alpha=0.85)
    if cross is not None:
        ax.axvline(cross, color="#f59e0b", linestyle="--", linewidth=1.2,
                   label=f"1% error @ cycle {cross}")
    ax.set_xlabel("Cycle")
    ax.set_ylabel("Running state value")
    ax.set_title("Horus NFE Deep Chain — Running State Fidelity vs FP64 Golden")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig("fidelity_plot.png", dpi=150)
    print("  Wrote fidelity_plot.png")

    # ── Plot 2: Relative error over time ─────────────────────────────────────
    fig2, ax2 = plt.subplots(figsize=(11, 4))
    ax2.plot(cycles[1:], err_pct[1:], color="#7c3aed", linewidth=1.2)
    ax2.axhline(THRESHOLD_PCT, color="#f59e0b", linestyle="--", linewidth=1.0,
                label=f"{THRESHOLD_PCT:.0f}% threshold")
    if cross is not None:
        ax2.axvline(cross, color="#f59e0b", linestyle=":", linewidth=1.0)
    ax2.set_xlabel("Cycle")
    ax2.set_ylabel("Relative error (%)")
    ax2.set_title(f"Fidelity Drift — MRE = {mean_rel_err:.4f}%")
    ax2.legend()
    ax2.grid(True, alpha=0.3)
    fig2.tight_layout()
    fig2.savefig("fidelity_error_plot.png", dpi=150)
    print("  Wrote fidelity_error_plot.png")

    plt.close("all")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
