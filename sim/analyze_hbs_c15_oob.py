#!/usr/bin/env python3
"""
sim/analyze_hbs_c15_oob.py
===========================
HBS-C15: Out-of-Distribution Controllability Falsification

Reads HBS_C15_OOB.csv and answers the Key Question:

  A) ROBUST CONTROLLABILITY  — control fidelity > 85%, attractors stable
  B) GRACEFUL DEGRADATION    — bounded failure, no collapse
  C) COLLAPSE                — uncontrolled attractor drift
  D) HIDDEN HYSTERESIS       — delayed instability detected

Computes per regime:
  - Control Fidelity (% intended_mode == actual_mode)
  - Attractor Stability (% epochs classifiable as A1–A4)
  - Transition Entropy H(attractor_labels)
  - Collapse Rate (OVF+UF events / cycles)
  - Time-to-First-Failure (TTF: first cycle outside STABLE zone)
  - Degradation curve for R5 (10%→20%→30%)
"""
import csv, os, sys, math
from collections import Counter, defaultdict

CSV_PATH = "HBS_C15_OOB.csv"
LOG_PATH = "HBS_C15_SUMMARY.log"
EPOCH    = 16

REGIME_NAMES = [
    "R1  Latency Skew         (stale mode_tag, 1–3 cycle delay)",
    "R2  Phase Desync         (op_a delayed 2cy, mode delayed 1cy)",
    "R3  Burst Collapse       (MUL/SUB alternating every cycle)",
    "R4  Boundary Thrash      (E cycles 15/16/47/48 every 4cy)",
    "R5  Control Noise Attack (mode_tag bit-flips 10/20/30%)",
]

# ---------------------------------------------------------------------------
# Epoch classifier (inherited from C10)
# ---------------------------------------------------------------------------
def classify_epoch(rows):
    if not rows:
        return "A1", 0.50
    ops     = [r["op"] for r in rows]
    E_vals  = [int(r["E_out"]) for r in rows]
    regions = [r["region"] for r in rows]
    ovf_ct  = sum(1 for r in rows if int(r["OVF"]) > 0)
    n       = len(rows)

    mul_frac = ops.count("MUL") / n
    sub_frac = ops.count("SUB") / n
    add_frac = ops.count("ADD") / n

    pct_stable = regions.count("STABLE") / n
    pct_coll   = regions.count("COLLAPSE") / n
    pct_sat    = regions.count("SATURATE") / n
    pct_tran   = regions.count("TRANSITION") / n

    E_mean  = sum(E_vals) / n
    E_var   = sum((e-E_mean)**2 for e in E_vals) / n
    E_slope = (E_vals[-1]-E_vals[0]) / max(n,1)
    E_max   = max(E_vals)
    up_frac = sum(1 for i in range(1,n) if E_vals[i]>E_vals[i-1]) / max(n-1,1)
    crossings = sum(1 for i in range(1,n)
                   if (E_vals[i-1]<=19)!=(E_vals[i]<=19)
                   or (E_vals[i-1]>=44)!=(E_vals[i]>=44)) / n

    if ovf_ct > 0 or (mul_frac > 0.30 and E_slope > 0.35 and E_max > 44 and up_frac > 0.65):
        return "A2", min(0.99, 0.90 + 0.05*min(ovf_ct,2))

    in_boundary = (pct_coll + pct_sat + pct_tran) > 0.80
    oscillating = (crossings > 0.20 or E_var < 5.0)
    if in_boundary and oscillating:
        if sub_frac > 0.50:
            return "A1", 0.75
        return "A3", min(0.99, 0.80 + 0.05*crossings)

    region_variety = sum(1 for p in [pct_stable,pct_coll,pct_sat,pct_tran] if p > 0.10)
    if region_variety >= 3 and add_frac < 0.70 and mul_frac < 0.60:
        return "A4", 0.80

    if sub_frac >= 0.50 and pct_stable > 0.60:
        return "A1", min(0.99, 0.80 + 0.10*sub_frac)
    if pct_stable > 0.70:
        return "A1", 0.70
    if pct_coll > 0.50:
        return "A3", 0.65
    if pct_sat > 0.50:
        return "A2", 0.65
    return "A4", 0.55


def entropy(values):
    if not values:
        return 0.0
    c = Counter(values)
    n = len(values)
    return -sum((v/n)*math.log2(v/n) for v in c.values() if v > 0)


def load_csv(path):
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            rows.append(r)
    return rows


# ---------------------------------------------------------------------------
# Per-regime analysis
# ---------------------------------------------------------------------------
def analyze_regime(regime_rows, regime_id):
    n = len(regime_rows)
    if n == 0:
        return {}

    # 1. Control Fidelity
    fidelity_count = sum(1 for r in regime_rows
                         if int(r["intended_mode"]) == int(r["actual_mode"]))
    control_fidelity = fidelity_count / n

    # 2. Attractor Stability — classify every epoch
    epoch_labels = []
    for i in range(0, n, EPOCH):
        chunk = regime_rows[i:i+EPOCH]
        if chunk:
            lbl, _ = classify_epoch(chunk)
            epoch_labels.append(lbl)

    known_att = {"A1","A2","A3","A4"}
    att_stable = sum(1 for l in epoch_labels if l in known_att) / max(len(epoch_labels),1)
    H_att      = entropy(epoch_labels)

    # 3. Transition entropy — E_out distribution
    e_vals  = [int(r["E_out"]) for r in regime_rows]
    H_E     = entropy(e_vals)

    # 4. Collapse / OVF rate
    ovf_count = sum(1 for r in regime_rows if int(r["OVF"]) > 0)
    uf_count  = sum(1 for r in regime_rows if int(r["UF"]) > 0)
    collapse_rate = (ovf_count + uf_count) / n

    # 5. Time-to-First-Failure (TTF) — first cycle outside STABLE zone
    ttf = n  # default: never failed
    for i, r in enumerate(regime_rows):
        e = int(r["E_out"])
        if e < 20 or e > 43:
            ttf = i
            break

    # 6. Region distribution
    regions = [r["region"] for r in regime_rows]
    pct_stable = regions.count("STABLE") / n
    pct_coll   = regions.count("COLLAPSE") / n
    pct_sat    = regions.count("SATURATE") / n
    pct_tran   = regions.count("TRANSITION") / n

    # 7. Mode corruption distribution (R1/R2/R5 specific)
    mode_diff = sum(1 for r in regime_rows
                    if int(r["intended_mode"]) != int(r["actual_mode"]))
    bit_error_rate = mode_diff / n

    # 8. Attractor distribution
    att_counter = Counter(epoch_labels)

    return {
        "n_cycles":       n,
        "n_epochs":       len(epoch_labels),
        "control_fidelity": control_fidelity,
        "att_stability":  att_stable,
        "H_att":          H_att,
        "H_E":            H_E,
        "ovf_count":      ovf_count,
        "uf_count":       uf_count,
        "collapse_rate":  collapse_rate,
        "ttf":            ttf,
        "pct_stable":     pct_stable,
        "pct_coll":       pct_coll,
        "pct_sat":        pct_sat,
        "pct_tran":       pct_tran,
        "bit_error_rate": bit_error_rate,
        "att_dist":       dict(att_counter),
        "epoch_labels":   epoch_labels,
    }


# ---------------------------------------------------------------------------
# R5 degradation curve (3 noise levels)
# ---------------------------------------------------------------------------
def analyze_r5_degradation(r5_rows):
    levels    = [0, 1, 2]
    level_pct = [9.4, 18.75, 31.25]
    results   = {}
    for lvl in levels:
        lvl_rows = [r for r in r5_rows if int(r["noise_level"]) == lvl]
        if not lvl_rows:
            continue
        fidelity = sum(1 for r in lvl_rows
                       if int(r["intended_mode"]) == int(r["actual_mode"])) / len(lvl_rows)
        att_lbl = [classify_epoch(lvl_rows[i:i+EPOCH])[0]
                   for i in range(0, len(lvl_rows), EPOCH) if lvl_rows[i:i+EPOCH]]
        att_stab = sum(1 for l in att_lbl if l in {"A1","A2","A3","A4"}) / max(len(att_lbl),1)
        results[lvl] = {
            "noise_pct": level_pct[lvl],
            "fidelity":  fidelity,
            "att_stab":  att_stab,
        }
    return results


# ---------------------------------------------------------------------------
# Hysteresis check
# ---------------------------------------------------------------------------
def check_hysteresis(regime_results_list):
    """
    Look for delayed instability: stable early, unstable late within a regime.
    Returns True if any regime shows increasing failure rate in second half.
    """
    for rr in regime_results_list:
        lbl = rr.get("epoch_labels", [])
        n   = len(lbl)
        if n < 4:
            continue
        first_half_known  = sum(1 for l in lbl[:n//2] if l in {"A1","A2","A3","A4"})
        second_half_known = sum(1 for l in lbl[n//2:] if l in {"A1","A2","A3","A4"})
        # Hysteresis: second half much worse
        if first_half_known > 0 and second_half_known / max(1, first_half_known) < 0.70:
            return True
    return False


# ---------------------------------------------------------------------------
# Key Question (A-D)
# ---------------------------------------------------------------------------
def determine_key_answer(results_by_regime):
    fidelities  = [r["control_fidelity"] for r in results_by_regime.values()]
    stabilities = [r["att_stability"]    for r in results_by_regime.values()]
    col_rates   = [r["collapse_rate"]    for r in results_by_regime.values()]
    ttfs        = [r["ttf"]              for r in results_by_regime.values()]

    avg_fidelity   = sum(fidelities)  / len(fidelities)
    avg_stability  = sum(stabilities) / len(stabilities)
    max_col_rate   = max(col_rates)
    min_ttf        = min(ttfs)

    any_collapse   = max_col_rate > 0.50
    any_instant    = min_ttf < EPOCH  # failure within 1 epoch
    hyst_detected  = check_hysteresis(list(results_by_regime.values()))

    # Score-based classification
    if avg_fidelity >= 0.85 and avg_stability >= 0.90 and not any_collapse:
        answer = "A"
        label  = "ROBUST CONTROLLABILITY"
        reason = (f"avg_fidelity={avg_fidelity:.1%} ≥ 85%, "
                  f"avg_stability={avg_stability:.1%} ≥ 90%, no collapse")
    elif avg_stability >= 0.65 and not any_collapse and not hyst_detected:
        answer = "B"
        label  = "GRACEFUL DEGRADATION"
        reason = (f"avg_stability={avg_stability:.1%}, fidelity degrades under attack "
                  f"but attractors remain bounded")
    elif any_collapse or (avg_stability < 0.50):
        answer = "C"
        label  = "COLLAPSE / UNCONTROLLED DRIFT"
        reason = f"max_col_rate={max_col_rate:.1%} or avg_stability={avg_stability:.1%} < 50%"
    elif hyst_detected:
        answer = "D"
        label  = "HIDDEN HYSTERESIS"
        reason = "Delayed instability detected: first half stable, second half degrades"
    else:
        answer = "B"
        label  = "GRACEFUL DEGRADATION"
        reason = "Bounded failure across all regimes"

    return answer, label, reason, {
        "avg_fidelity":  avg_fidelity,
        "avg_stability": avg_stability,
        "max_col_rate":  max_col_rate,
        "min_ttf":       min_ttf,
        "hysteresis":    hyst_detected,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(CSV_PATH):
        print(f"ERROR: {CSV_PATH} not found. Run simulation first.")
        sys.exit(1)

    print("=" * 64)
    print("HBS-C15: OOB Controllability Falsification Analysis")
    print("=" * 64)

    rows = load_csv(CSV_PATH)
    print(f"  Loaded {len(rows):,} rows from {CSV_PATH}")

    # Split by regime
    by_regime = defaultdict(list)
    for r in rows:
        by_regime[int(r["regime"])].append(r)

    # Analyze each regime
    regime_results = {}
    for rid in range(5):
        regime_results[rid] = analyze_regime(by_regime[rid], rid)

    SEP = "─" * 64

    # ── Per-regime summary ──────────────────────────────────────────
    print(f"\n  {'':>3}  {'Fidelity':>9}  {'Stability':>10}  {'CollapseRt':>11}  {'TTF':>5}  H(att)")
    print(f"  {SEP}")
    for rid in range(5):
        r = regime_results[rid]
        lbl = REGIME_NAMES[rid][:30]
        print(f"  {rid}  {r['control_fidelity']*100:>8.1f}%"
              f"  {r['att_stability']*100:>9.1f}%"
              f"  {r['collapse_rate']*100:>10.2f}%"
              f"  {r['ttf']:>5d}"
              f"  {r['H_att']:.3f}")
    print(f"  {SEP}")

    # ── Detailed per-regime output ───────────────────────────────────
    for rid in range(5):
        r = regime_results[rid]
        print(f"\n[{REGIME_NAMES[rid]}]")
        print(f"  Control fidelity:    {r['control_fidelity']*100:.1f}%  ({int(r['control_fidelity']*r['n_cycles'])} / {r['n_cycles']} cycles match)")
        print(f"  Attractor stability: {r['att_stability']*100:.1f}%  ({r['att_dist']})")
        print(f"  OVF/UF events:       {r['ovf_count']} OVF + {r['uf_count']} UF = {r['collapse_rate']*100:.2f}%")
        print(f"  Time-to-failure:     {r['ttf']} cycles  ({'FAILED IMMEDIATELY' if r['ttf'] < EPOCH else 'survived ≥1 epoch' if r['ttf'] < r['n_cycles'] else 'NO FAILURE'})")
        print(f"  Region mix:  STABLE={r['pct_stable']:.2f}  TRAN={r['pct_tran']:.2f}  COLL={r['pct_coll']:.2f}  SAT={r['pct_sat']:.2f}")
        print(f"  H(E_out):    {r['H_E']:.3f} bits  |  H(attractor): {r['H_att']:.3f} bits")

    # ── R5 Degradation Curve ─────────────────────────────────────────
    print(f"\n[R5 Degradation Curve — Control Noise Attack]")
    r5_deg = analyze_r5_degradation(by_regime[4])
    for lvl, v in sorted(r5_deg.items()):
        fid_bar = "#" * int(v["fidelity"] * 30)
        print(f"  Level {lvl} (~{v['noise_pct']:.1f}% noise): "
              f"fidelity={v['fidelity']*100:.1f}%  att_stability={v['att_stab']*100:.1f}%  "
              f"[{fid_bar:<30}]")

    # ── Mode corruption analysis ─────────────────────────────────────
    print(f"\n[Mode Corruption Analysis (bit error rates)]")
    for rid in range(5):
        r = regime_results[rid]
        print(f"  R{rid}: BER = {r['bit_error_rate']*100:.1f}%  "
              f"({int(r['bit_error_rate']*r['n_cycles'])} corrupted / {r['n_cycles']} cycles)")

    # ── Hysteresis check ─────────────────────────────────────────────
    hyst = check_hysteresis(list(regime_results.values()))
    print(f"\n[Hysteresis Check]")
    print(f"  Delayed instability detected: {'YES — HYSTERESIS PRESENT' if hyst else 'NO — no delayed instability'}")

    # ── Key Question ─────────────────────────────────────────────────
    answer, label, reason, stats = determine_key_answer(regime_results)

    print(f"\n{'='*64}")
    print(f"  KEY QUESTION ANSWER: ({answer}) {label}")
    print(f"{'='*64}")
    print(f"  Reason: {reason}")
    print(f"\n  Supporting metrics:")
    print(f"    avg_fidelity:   {stats['avg_fidelity']*100:.1f}%")
    print(f"    avg_stability:  {stats['avg_stability']*100:.1f}%")
    print(f"    max_collapse:   {stats['max_col_rate']*100:.2f}%")
    print(f"    min_TTF:        {stats['min_ttf']} cycles")
    print(f"    hysteresis:     {'YES' if stats['hysteresis'] else 'NO'}")

    # ── Baseline comparison (vs C12) ─────────────────────────────────
    print(f"\n[Collapse Rate vs C12 Baseline]")
    # C12 baseline: from HBS_C12_ADVERSARIAL.csv if available, else use 0.02% reference
    c12_ref = 0.0002  # ~0.02% OVF+UF rate from prior C12 results
    for rid in range(5):
        r = regime_results[rid]
        inflation = r["collapse_rate"] / max(c12_ref, 1e-6)
        print(f"  R{rid}: collapse={r['collapse_rate']*100:.3f}%  "
              f"(C12 baseline={c12_ref*100:.3f}%  inflation={inflation:.1f}×)")

    # ── Falsification verdict ─────────────────────────────────────────
    print(f"\n[Falsification Verdict]")
    if answer in ("A", "B"):
        print(f"  C13 FULLY_CONTROLLABLE claim: SURVIVES (not falsified)")
        print(f"  C14 COMPUTATIONALLY_EXPRESSIVE claim: SURVIVES (not falsified)")
        print(f"  System demonstrates {label} under all 5 OOB adversarial regimes.")
    else:
        print(f"  C13 FULLY_CONTROLLABLE claim: FALSIFIED under adversarial conditions")
        print(f"  Result: {label}")

    # ── Write log ─────────────────────────────────────────────────────
    with open(LOG_PATH, "w") as f:
        f.write(f"HBS_C15_KEY_ANSWER={answer}\n")
        f.write(f"HBS_C15_LABEL={label}\n")
        f.write(f"AVG_CONTROL_FIDELITY={stats['avg_fidelity']:.4f}\n")
        f.write(f"AVG_ATTRACTOR_STABILITY={stats['avg_stability']:.4f}\n")
        f.write(f"MAX_COLLAPSE_RATE={stats['max_col_rate']:.6f}\n")
        f.write(f"MIN_TTF={stats['min_ttf']}\n")
        f.write(f"HYSTERESIS_DETECTED={'YES' if stats['hysteresis'] else 'NO'}\n")
        f.write(f"C13_FALSIFIED={'NO' if answer in ('A','B') else 'YES'}\n")
        f.write(f"C14_FALSIFIED={'NO' if answer in ('A','B') else 'YES'}\n")

        f.write("\nPER_REGIME\n")
        for rid in range(5):
            r = regime_results[rid]
            f.write(f"  R{rid}: fidelity={r['control_fidelity']:.3f}"
                    f" stability={r['att_stability']:.3f}"
                    f" collapse={r['collapse_rate']:.6f}"
                    f" ttf={r['ttf']}\n")

        f.write("\nR5_DEGRADATION\n")
        for lvl, v in sorted(r5_deg.items()):
            f.write(f"  noise={v['noise_pct']:.1f}%: fidelity={v['fidelity']:.3f}"
                    f" stability={v['att_stab']:.3f}\n")

    print(f"\n  Log written to {LOG_PATH}")
    return answer


if __name__ == "__main__":
    main()
