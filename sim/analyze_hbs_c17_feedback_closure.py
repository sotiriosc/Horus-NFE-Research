#!/usr/bin/env python3
"""
sim/analyze_hbs_c17_feedback_closure.py
==========================================
HBS-C17: Accumulation Feedback Closure Falsification Analysis

Reads HBS_C17_FEEDBACK_CLOSURE.csv and proves (or disproves) that the
HORUS v3 ALU is strictly feedforward — i.e., accum_reg NEVER influences
mant_sum, scale_reg, or computed.

Sub-tests:
  0 A1_BASE   accum_en=1 (growing accum)
  1 A1_ALT    accum_en=0 (accum stays 0)
  2 A2_CLR    accum_clr every 16 cycles
  3 A2_NOCLR  no clears (accum grows freely)
  4 A3_HIGH   accum_reg forced to 0xFFFFF000
  5 A3_LOW    accum_reg forced to 0x00000001
  6 A4_ONTIME accum_clr at 0,16,32,...
  7 A4_LATE   accum_clr at 1,17,33,... (1 cycle late)
  8 A5_LONG   5,000-cycle long horizon

Metrics computed:
  CIS  — Computation Invariance Score: variance of computed across sub-tests
  ASI  — ALU Sensitivity Index: Pearson ρ(accum_reg, {mant_sum, computed})
  FLD  — Feedback Leakage Detector: any cycle where computed differs across sub-tests
  TLC  — Time-lag coupling: cross-correlation at lag 1..10
  RER  — Reset entropy recovery: entropy change after accum_clr events

Classification:
  A — STRICTLY FEEDFORWARD    : CIS=0, ASI≈0, FLD=0, no lag coupling
  B — WEAK STATISTICAL COUPLING: tiny but nonzero correlation
  C — DELAYED FEEDBACK LOOP   : coupling appears at specific lag N
  D — STRATIFIED FEEDBACK     : multiple interacting loops
"""
import csv, os, sys, math
from collections import defaultdict

CSV_PATH = "HBS_C17_FEEDBACK_CLOSURE.csv"
LOG_PATH = "HBS_C17_SUMMARY.log"

SUB_NAMES = {
    0: "A1_BASE  (accum_en=1, gate=63)",
    1: "A1_ALT   (accum_en=0, accum=0)",
    2: "A2_CLR   (clr every 16 cycles)",
    3: "A2_NOCLR (no clears, free growth)",
    4: "A3_HIGH  (forced accum=0xFFFFF000)",
    5: "A3_LOW   (forced accum=0x00000001)",
    6: "A4_ONTIME(clr at 0,16,32,...)",
    7: "A4_LATE  (clr at 1,17,33,...)",
    8: "A5_LONG  (5,000 cy long horizon)",
}

COMPARISON_PAIRS = [
    (0, 1, "A1: accum-ON vs accum-OFF"),
    (2, 3, "A2: clr-periodic vs no-clr"),
    (4, 5, "A3: forced-high vs forced-low"),
    (6, 7, "A4: on-time clr vs late clr"),
]

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------
def load_csv(path):
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            rows.append({
                "cycle":          int(r["cycle"]),
                "sub_id":         int(r["sub_id"]),
                "local_cycle":    int(r["local_cycle"]),
                "accum_reg_pre":  int(r["accum_reg_pre"]),
                "accum_word":     int(r["accum_word"]),
                "accum_reg_post": int(r["accum_reg_post"]),
                "mant_sum":       int(r["mant_sum"]),
                "scale_reg":      int(r["scale_reg"]),
                "computed":       int(r["computed"]),
                "result":         int(r["result"]),
                "UF":             int(r["UF"]),
                "OVF":            int(r["OVF"]),
                "accum_en_act":   int(r["accum_en_act"]),
            })
    return rows


# ---------------------------------------------------------------------------
# Metric 1: Computation Invariance Score (CIS)
# ---------------------------------------------------------------------------
def compute_cis(by_sub, field="computed"):
    """
    Variance of `field` across ALL sub-tests (pooled).
    CIS = 0 → perfectly invariant (feedforward confirmed).
    CIS > 0 → some sub-test produces a different value.
    """
    all_vals = []
    for sub_id, rows in by_sub.items():
        all_vals.extend(r[field] for r in rows)
    if not all_vals:
        return 0.0, 0.0
    mu  = sum(all_vals) / len(all_vals)
    var = sum((v - mu) ** 2 for v in all_vals) / len(all_vals)
    return var, mu


def compute_per_sub_stats(by_sub, field="computed"):
    stats = {}
    for sub_id, rows in by_sub.items():
        vals = [r[field] for r in rows]
        mu   = sum(vals) / len(vals)
        var  = sum((v - mu) ** 2 for v in vals) / len(vals)
        stats[sub_id] = {"mean": mu, "variance": var, "min": min(vals), "max": max(vals)}
    return stats


# ---------------------------------------------------------------------------
# Metric 2: ALU Sensitivity Index (ASI)
# ---------------------------------------------------------------------------
def pearson_r(xs, ys):
    n = min(len(xs), len(ys))
    if n < 2:
        return 0.0
    xs, ys = xs[:n], ys[:n]
    mx = sum(xs) / n;  my = sum(ys) / n
    num = sum((x-mx)*(y-my) for x,y in zip(xs,ys))
    dx  = math.sqrt(sum((x-mx)**2 for x in xs))
    dy  = math.sqrt(sum((y-my)**2 for y in ys))
    if dx < 1e-9 or dy < 1e-9:
        return float("nan")
    return num / (dx * dy)


def compute_asi(all_rows, x_field="accum_reg_post", y_fields=None):
    """
    Pearson ρ between accum_reg state and each ALU field.
    A5_LONG provides the most variation in accum_reg.
    """
    if y_fields is None:
        y_fields = ["mant_sum", "scale_reg", "computed"]

    a5_rows = [r for r in all_rows if r["sub_id"] == 8]
    if not a5_rows:
        return {}

    accum_vals = [r[x_field] for r in a5_rows]
    results = {}
    for yf in y_fields:
        y_vals = [r[yf] for r in a5_rows]
        rho = pearson_r(accum_vals, y_vals)
        results[yf] = rho
    return results


# ---------------------------------------------------------------------------
# Metric 3: Feedback Leakage Detector (FLD)
# ---------------------------------------------------------------------------
def compute_fld(by_sub, field="computed"):
    """
    For each comparison pair, count cycles where field differs.
    FLD = 0 → no leakage detected.
    """
    leakage = {}
    for sid_a, sid_b, desc in COMPARISON_PAIRS:
        if sid_a not in by_sub or sid_b not in by_sub:
            continue
        ra = by_sub[sid_a]
        rb = by_sub[sid_b]
        n  = min(len(ra), len(rb))
        diff_count = sum(1 for i in range(n) if ra[i][field] != rb[i][field])
        leakage[(sid_a, sid_b)] = {
            "desc":        desc,
            "n_compared":  n,
            "n_different": diff_count,
            "leakage_rate": diff_count / n if n > 0 else 0.0,
        }
    return leakage


# ---------------------------------------------------------------------------
# Metric 4: Time-lag coupling (cross-correlation with lag)
# ---------------------------------------------------------------------------
def time_lag_coupling(all_rows, max_lag=10, sub_id=8):
    """
    Compute cross-correlation between accum_reg(t) and computed(t+lag)
    for lag = 0..max_lag. Uses A5_LONG for maximal accum variation.
    """
    rows = [r for r in all_rows if r["sub_id"] == sub_id]
    if not rows:
        return {}

    accum = [r["accum_reg_post"] for r in rows]
    comp  = [r["computed"]       for r in rows]

    results = {}
    for lag in range(max_lag + 1):
        if lag == 0:
            rho = pearson_r(accum, comp)
        else:
            rho = pearson_r(accum[:-lag], comp[lag:])
        results[lag] = rho
    return results


# ---------------------------------------------------------------------------
# Metric 5: Reset entropy recovery
# ---------------------------------------------------------------------------
def reset_entropy_recovery(by_sub, sub_id=2):
    """
    After each accum_clr pulse (A2_CLR: every 16 cycles),
    does computed change? Entropy of computed before/after clear.
    """
    rows   = by_sub.get(sub_id, [])
    if not rows:
        return {}

    pre_clr  = []
    post_clr = []
    for i, r in enumerate(rows):
        lc = r["local_cycle"]
        if (lc % 16) == 15:          # cycle just before clr
            pre_clr.append(r["computed"])
        elif (lc % 16) == 0:         # cycle just after clr fires
            post_clr.append(r["computed"])

    def entropy(vals):
        from collections import Counter
        c = Counter(vals); n = len(vals)
        return -sum((v/n)*math.log2(v/n) for v in c.values() if v > 0) if n > 0 else 0.0

    return {
        "H_pre_clr":  entropy(pre_clr),
        "H_post_clr": entropy(post_clr),
        "n_transitions": len(pre_clr),
    }


# ---------------------------------------------------------------------------
# A5 long horizon: accum range vs computed range
# ---------------------------------------------------------------------------
def long_horizon_profile(all_rows):
    rows = [r for r in all_rows if r["sub_id"] == 8]
    if not rows:
        return {}

    accum_vals    = [r["accum_reg_post"] for r in rows]
    computed_vals = [r["computed"]       for r in rows]

    return {
        "accum_min":    min(accum_vals),
        "accum_max":    max(accum_vals),
        "accum_range":  max(accum_vals) - min(accum_vals),
        "computed_min": min(computed_vals),
        "computed_max": max(computed_vals),
        "computed_range": max(computed_vals) - min(computed_vals),
        "n_cycles":     len(rows),
    }


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------
def classify(cis_computed, fld_results, asi_results, lag_results):
    """
    A — STRICTLY FEEDFORWARD
    B — WEAK STATISTICAL COUPLING
    C — DELAYED FEEDBACK LOOP
    D — STRATIFIED FEEDBACK
    """
    # Check FLD: any leakage at all?
    total_leakage = sum(v["n_different"] for v in fld_results.values())
    leakage_detected = total_leakage > 0

    # Check CIS: any variance in computed across sub-tests?
    cis_nonzero = cis_computed > 0.0

    # Check ASI: any significant correlation?
    valid_asis = [v for v in asi_results.values() if not math.isnan(v)]
    max_asi = max(abs(v) for v in valid_asis) if valid_asis else 0.0
    asi_significant = max_asi > 0.05

    # Check lag coupling
    valid_lags = {k: v for k, v in lag_results.items() if not math.isnan(v)}
    max_lag_rho = max(abs(v) for v in valid_lags.values()) if valid_lags else 0.0
    lag_coupling = max_lag_rho > 0.10

    if not leakage_detected and not cis_nonzero and not lag_coupling:
        if asi_significant:
            return ("B",
                    "WEAK STATISTICAL COUPLING",
                    f"ASI max|ρ|={max_asi:.4f} marginally above 0.05 threshold")
        return ("A",
                "STRICTLY FEEDFORWARD",
                "CIS=0, FLD=0, ASI≈0, no lag coupling — full causal closure confirmed")

    if leakage_detected or cis_nonzero:
        if lag_coupling:
            return ("C",
                    "DELAYED FEEDBACK LOOP",
                    f"Lag coupling detected at ρ={max_lag_rho:.4f}")
        return ("D",
                "STRATIFIED FEEDBACK SYSTEM",
                f"Multiple divergence indicators: FLD={total_leakage}, CIS={cis_computed:.2e}")

    if lag_coupling:
        return ("C",
                "DELAYED FEEDBACK LOOP",
                f"No direct leakage but lag coupling at ρ={max_lag_rho:.4f}")

    return ("A",
            "STRICTLY FEEDFORWARD",
            "All metrics within feedforward bounds")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(CSV_PATH):
        print(f"ERROR: {CSV_PATH} not found. Run simulation first.")
        sys.exit(1)

    print("=" * 64)
    print("HBS-C17: Accumulation Feedback Closure Analysis")
    print("=" * 64)

    rows = load_csv(CSV_PATH)
    print(f"  Loaded {len(rows):,} rows from {CSV_PATH}")

    by_sub = defaultdict(list)
    for r in rows:
        by_sub[r["sub_id"]].append(r)

    # ── Per-sub-test stats ──────────────────────────────────────────────────
    print(f"\n[Sub-test Summary]")
    print(f"  {'Sub':<12}  {'Cycles':>7}  {'accum_range':>13}  {'computed_mean':>14}  {'computed_var':>13}")
    print(f"  {'-'*12}  {'-'*7}  {'-'*13}  {'-'*14}  {'-'*13}")
    for sid in sorted(by_sub):
        sub_rows     = by_sub[sid]
        accum_vals   = [r["accum_reg_post"] for r in sub_rows]
        comp_vals    = [r["computed"]        for r in sub_rows]
        mu_c  = sum(comp_vals) / len(comp_vals)
        var_c = sum((v-mu_c)**2 for v in comp_vals) / len(comp_vals)
        accum_range = max(accum_vals) - min(accum_vals)
        print(f"  {sid:<12}  {len(sub_rows):>7}  {accum_range:>13,}  {mu_c:>14.2f}  {var_c:>13.2f}")

    # ── CIS ────────────────────────────────────────────────────────────────
    print(f"\n[Metric 1: Computation Invariance Score (CIS)]")
    for field in ["mant_sum", "scale_reg", "computed", "result"]:
        var, mu = compute_cis(by_sub, field)
        verdict = "INVARIANT" if var == 0.0 else f"VAR={var:.4e}"
        print(f"  {field:<12}: mean={mu:.2f}  variance={var:.4e}  → {verdict}")

    # ── FLD ────────────────────────────────────────────────────────────────
    print(f"\n[Metric 2: Feedback Leakage Detector (FLD)]")
    for field in ["mant_sum", "computed", "result"]:
        fld = compute_fld(by_sub, field)
        any_leakage = any(v["n_different"] > 0 for v in fld.values())
        status = "LEAKAGE DETECTED" if any_leakage else "NO LEAKAGE"
        print(f"\n  field={field}  →  {status}")
        for key, v in fld.items():
            diff_s = f"{v['n_different']} / {v['n_compared']}" if v["n_different"] else "0 / all"
            print(f"    {v['desc']:<40}: diff cycles={diff_s}")

    # ── ASI ────────────────────────────────────────────────────────────────
    print(f"\n[Metric 3: ALU Sensitivity Index (ASI)]")
    print(f"  Pearson ρ(accum_reg_post, ALU_signal) — using A5_LONG for maximum accum variation")
    for x_field in ["accum_reg_post", "accum_reg_pre"]:
        asi = compute_asi(rows, x_field=x_field)
        print(f"\n  Using {x_field}:")
        for yf, rho in asi.items():
            sig = "SIGNIFICANT" if not math.isnan(rho) and abs(rho) > 0.05 else \
                  ("UNDEFINED" if math.isnan(rho) else "NON-SIGNIFICANT")
            rho_s = f"{rho:+.6f}" if not math.isnan(rho) else "NaN (zero variance)"
            print(f"    ρ(accum, {yf:<12}) = {rho_s}  → {sig}")

    # ── Time-lag coupling ─────────────────────────────────────────────────
    print(f"\n[Metric 4: Time-Lag Coupling — ρ(accum_reg(t), computed(t+lag))]")
    lag_results = time_lag_coupling(rows)
    for lag, rho in lag_results.items():
        bar = "#" * int(abs(rho) * 40) if not math.isnan(rho) else ""
        rho_s = f"{rho:+.6f}" if not math.isnan(rho) else "NaN"
        print(f"  lag={lag:>2}: ρ={rho_s}  [{bar}]")

    # ── Reset entropy recovery ─────────────────────────────────────────────
    print(f"\n[Metric 5: Reset Entropy Recovery (A2_CLR sub-test)]")
    rer = reset_entropy_recovery(by_sub, sub_id=2)
    print(f"  H(computed) before accum_clr : {rer.get('H_pre_clr', 0):.4f} bits")
    print(f"  H(computed) after  accum_clr : {rer.get('H_post_clr', 0):.4f} bits")
    print(f"  Number of clear transitions  : {rer.get('n_transitions', 0)}")
    print(f"  {'→ No entropy change' if rer.get('H_pre_clr',0)==rer.get('H_post_clr',0) else '→ Entropy changed — investigate'}")

    # ── A5 long horizon profile ───────────────────────────────────────────
    print(f"\n[A5 Long Horizon Profile — accum range vs computed range over 5,000 cycles]")
    lhp = long_horizon_profile(rows)
    print(f"  accum_reg range : {lhp['accum_min']:>12,} → {lhp['accum_max']:>12,}  (span={lhp['accum_range']:,})")
    print(f"  computed range  : {lhp['computed_min']:>12,} → {lhp['computed_max']:>12,}  (span={lhp['computed_range']})")
    print(f"  Ratio: accum spans {lhp['accum_range']:,} while computed spans {lhp['computed_range']}")
    if lhp['computed_range'] == 0:
        print(f"  → computed is PERFECTLY CONSTANT despite accum varying by {lhp['accum_range']:,}")

    # ── A3 extremes: side-by-side comparison ─────────────────────────────
    print(f"\n[A3 Extreme Accum Comparison — first 5 cycles per sub-test]")
    print(f"  {'Cycle':>5}  {'accum(A3_HIGH)':>16}  {'computed(A3_HIGH)':>18}  "
          f"{'accum(A3_LOW)':>14}  {'computed(A3_LOW)':>17}")
    for lc in range(5):
        if lc < len(by_sub[4]) and lc < len(by_sub[5]):
            rh = by_sub[4][lc]; rl = by_sub[5][lc]
            print(f"  {lc:>5}  {rh['accum_reg_post']:>16,}  0x{rh['computed']:>08x}       "
                  f"  {rl['accum_reg_post']:>14,}  0x{rl['computed']:>08x}")

    # ── Classification ────────────────────────────────────────────────────
    cis_val, _ = compute_cis(by_sub, "computed")
    fld_results = compute_fld(by_sub, "computed")
    asi_results = compute_asi(rows, "accum_reg_post")
    verdict, label, reason = classify(cis_val, fld_results, asi_results, lag_results)

    print(f"\n{'='*64}")
    print(f"  CLASSIFICATION: ({verdict}) {label}")
    print(f"{'='*64}")
    print(f"  Reason: {reason}")
    print(f"\n  Evidence summary:")
    print(f"    CIS(computed)  = {cis_val:.4e}  {'← INVARIANT' if cis_val==0 else '← NON-ZERO'}")
    total_fld = sum(v['n_different'] for v in fld_results.values())
    print(f"    FLD(computed)  = {total_fld} leakage cycles  {'← NO LEAKAGE' if total_fld==0 else '← LEAKAGE DETECTED'}")
    valid_asi = {k:v for k,v in asi_results.items() if not math.isnan(v)}
    max_asi = max(abs(v) for v in valid_asi.values()) if valid_asi else 0.0
    print(f"    ASI max|ρ|    = {max_asi:.6f}  {'← NON-SIGNIFICANT' if max_asi <= 0.05 else '← SIGNIFICANT'}")
    valid_lags = {k:v for k,v in lag_results.items() if not math.isnan(v)}
    max_lag    = max(abs(v) for v in valid_lags.values()) if valid_lags else 0.0
    print(f"    Max lag ρ      = {max_lag:.6f}  {'← NO LAG COUPLING' if max_lag <= 0.10 else '← LAG COUPLING'}")

    if verdict == "A":
        print(f"\n  MATHEMATICAL PROOF: The HORUS v3 ALU is strictly feedforward.")
        print(f"  accum_reg is causally isolated from {{mant_sum, scale_reg, computed, result}}.")

    # Write log
    with open(LOG_PATH, "w") as f:
        f.write(f"HBS_C17_VERDICT={verdict}\n")
        f.write(f"HBS_C17_LABEL={label}\n")
        f.write(f"CIS_COMPUTED={cis_val:.6e}\n")
        f.write(f"FLD_TOTAL_LEAKAGE={total_fld}\n")
        f.write(f"ASI_MAX={max_asi:.6f}\n")
        f.write(f"LAG_MAX_RHO={max_lag:.6f}\n")
        f.write(f"FEEDFORWARD_PROVEN={'YES' if verdict=='A' else 'NO'}\n")
        f.write(f"\nA5_LONG_HORIZON\n")
        f.write(f"  accum_range={lhp['accum_range']}\n")
        f.write(f"  computed_range={lhp['computed_range']}\n")
        f.write("\nFLD_DETAIL\n")
        for key, v in fld_results.items():
            f.write(f"  {v['desc']}: {v['n_different']} leakage cycles / {v['n_compared']} total\n")

    print(f"\n  Log written to {LOG_PATH}")
    return verdict


if __name__ == "__main__":
    main()
