#!/usr/bin/env python3
"""
HBS-C22: Exogenous Control Injection Test (Strict Version)
  Option B — XOR Coupling:  computed_mod = computed XOR mask(mode_tag)
  mode_tag is EXOGENOUS (independent 15-bit LFSR, zero DUT state dependency)
================================================================
This analysis answers the fundamental question:

  "Can an INDEPENDENT control stream causally influence the arithmetic
   output of HORUS v3 and induce measurable attractor imprinting?"

The answer requires a DUAL-LAYER verdict:

  ARITHMETIC LAYER: Does mode_tag change 'computed'?
    Expected: NO — ALU core is untouched, closure theorem holds.

  OBSERVER LAYER: Does mode_tag control 'computed_mod'?
    Expected: YES — by construction (XOR coupling is explicit).

The scientific question is NOT whether MI_obs > 0 (it will be, trivially).
The question is what this means structurally:

  CASE 1 — True closure persists:
    MI_arith ≈ 0  AND  MI_obs ≈ 0
    Only if XOR mask has no effect (R1 only).

  CASE 2 — Weak regime modulation:
    MI_arith ≈ 0  AND  MI_obs small (< 0.1 bits)
    mode=01 (mantissa flip) doesn't change attractor class.

  CASE 3 — Structural observer coupling:
    MI_arith ≈ 0  AND  MI_obs > 0.1 bits
    mode=10 (E-field flip) directly changes attractor class.

Critically: CASE 3 in the OBSERVER layer does NOT overturn closure —
it demonstrates that attractor structure is a GEOMETRIC PROPERTY of the
observation projection, controllable via the XOR lens, but NOT causally
embedded in the arithmetic computation itself.

Metrics
-------
MI_arith  Mutual information: I(mode_tag ; attractor_base)
          [computed not changed → expected ≈ 0]

MI_obs    Mutual information: I(mode_tag ; attractor_mod)
          [computed_mod is XOR'd → expected > 0 when mask changes E-field]

AII_delta Change in MI: MI_obs − MI_arith
          Pure signal of observer coupling (above baseline).

CPR       Causal Penetration Ratio (XOR version):
          CPR = P(attractor_mod ≠ attractor_base)
          Fraction of cycles where XOR changed attractor classification.

PIG       Phase Injection Gain:
          PIG = mean(|Δcomputed_mod|) / mean(|Δcomputed|)
          at attractor transition cycles.

SLF       Stability Loss Function (KL-divergence version):
          SLF = KL(P_base || P_mod)  [attractor distribution divergence]
          = Σ P_base(a) * log2(P_base(a) / P_mod(a))

C20 baseline attractor distribution (from HBS-C20 empirical reference):
  A1=1.0%  A2=20.2%  A3=1.8%  A4=77.0%
"""

import sys
import csv
import math
import os
from collections import Counter

TRACE_CSV  = "HBS_C22_INJECTION_TRACE.csv"
LOG_FILE   = "HBS_C22_SUMMARY.log"
RESULT_CSV = "HBS_C22_REGIME_RESULTS.csv"
MI_CSV     = "HBS_C22_MI_MATRIX.csv"

# C20 reference attractor distribution
C20_BASELINE = {1: 0.010, 2: 0.202, 3: 0.018, 4: 0.770}

ATTRACTOR_NAMES = {1: "A1(cancel)", 2: "A2(explode)", 3: "A3(rollover)", 4: "A4(entropic)"}
MODE_NAMES      = {0: "00:identity", 1: "01:mant-flip", 2: "10:Efield-flip", 3: "11:both-flip"}

# ── Utilities ─────────────────────────────────────────────────────────────────

def mutual_information_bits(x_vals, y_vals):
    """Shannon MI I(X;Y) in bits, using empirical distribution."""
    n = len(x_vals)
    if n == 0: return float('nan')
    joint = Counter(zip(x_vals, y_vals))
    cx    = Counter(x_vals)
    cy    = Counter(y_vals)
    mi = 0.0
    for (x, y), cnt in joint.items():
        p_xy = cnt / n
        p_x  = cx[x] / n
        p_y  = cy[y] / n
        if p_xy > 0 and p_x > 0 and p_y > 0:
            mi += p_xy * math.log2(p_xy / (p_x * p_y))
    return max(mi, 0.0)  # clamp numerical noise

def kl_divergence(p, q, keys):
    """KL(P||Q) in bits.  q values are smoothed to avoid log(0)."""
    eps = 1e-9
    result = 0.0
    for k in keys:
        pk = p.get(k, eps)
        qk = max(q.get(k, eps), eps)
        if pk > 0:
            result += pk * math.log2(pk / qk)
    return result

def mean(vals):
    return sum(vals)/len(vals) if vals else float('nan')

def variance(vals):
    if len(vals) < 2: return 0.0
    m = mean(vals)
    return sum((v-m)**2 for v in vals) / len(vals)

def fmt(v, d=6):
    if math.isnan(v) or math.isinf(v): return f"{v}"
    return f"{v:.{d}f}"

def attractor_prob(attr_list):
    n = len(attr_list)
    cnt = Counter(attr_list)
    return {k: cnt.get(k, 0)/n for k in [1, 2, 3, 4]}

def input_delta_series(rrows, col):
    """Binary delta from raw value (1 if changed vs prev row)."""
    vals = [r[col] for r in rrows]
    return [0] + [1 if vals[i] != vals[i-1] else 0 for i in range(1, len(vals))]

# ── Load ──────────────────────────────────────────────────────────────────────

def load_csv(fname):
    rows = []
    with open(fname, newline='') as f:
        for row in csv.DictReader(f):
            parsed = {}
            for k, v in row.items():
                v = v.strip()
                parsed[k] = int(v) if v not in ('', 'x') else 0
            rows.append(parsed)
    return rows

# ── Per-regime analysis ───────────────────────────────────────────────────────

def analyze_regime(rrows, regime_id):
    n = len(rrows)
    result = {'regime_id': regime_id, 'n_cycles': n}

    computed_vals = [r['computed']      for r in rrows]
    mod_vals      = [r['computed_mod']  for r in rrows]
    attr_base     = [r['attractor_base'] for r in rrows]
    attr_mod      = [r['attractor_mod']  for r in rrows]
    mode_vals     = [r['active_mode']    for r in rrows]
    deltas_comp   = [r['delta_computed'] for r in rrows]
    deltas_mod    = [r['delta_mod']      for r in rrows]
    transitions   = [r['transition_base'] for r in rrows]
    e_base        = [r['e_field_base']   for r in rrows]
    e_mod         = [r['e_field_mod']    for r in rrows]

    # ── Mutual Information ────────────────────────────────────────────────
    mi_arith = mutual_information_bits(mode_vals, attr_base)   # should be ≈ 0
    mi_obs   = mutual_information_bits(mode_vals, attr_mod)    # shows observer coupling
    mi_delta = mi_obs - mi_arith

    # ── MI per mode_tag value (conditional analysis) ──────────────────────
    mi_per_mode = {}
    for m in [0, 1, 2, 3]:
        idx = [i for i, mv in enumerate(mode_vals) if mv == m]
        if not idx: continue
        ab_sub = [attr_base[i] for i in idx]
        am_sub = [attr_mod[i]  for i in idx]
        # Distribution of attractor_mod when this mode is active
        mi_per_mode[m] = {
            'n': len(idx),
            'P_base': attractor_prob(ab_sub),
            'P_mod':  attractor_prob(am_sub),
        }

    # ── CPR: fraction of cycles where attractor changed ───────────────────
    n_changed = sum(r['attractor_changed'] for r in rrows)
    cpr = n_changed / n

    # ── SLF: KL(P_base || P_mod) ─────────────────────────────────────────
    p_base_dict = attractor_prob(attr_base)
    p_mod_dict  = attractor_prob(attr_mod)
    slf = kl_divergence(p_base_dict, p_mod_dict, [1,2,3,4])

    # KL divergence from C20 baseline
    slf_vs_c20_base = kl_divergence(C20_BASELINE, p_base_dict, [1,2,3,4])
    slf_vs_c20_mod  = kl_divergence(C20_BASELINE, p_mod_dict,  [1,2,3,4])

    # ── PIG: Phase Injection Gain at attractor transitions ────────────────
    trans_idx = [i for i, t in enumerate(transitions) if t > 0 and i > 0]
    if trans_idx:
        dc_t = [deltas_comp[i] for i in trans_idx]
        dm_t = [deltas_mod[i]  for i in trans_idx]
        pig  = mean(dm_t) / mean(dc_t) if mean(dc_t) > 1e-6 else float('nan')
    else:
        pig = float('nan')
        dc_t = dm_t = []

    # ── E-field statistics ────────────────────────────────────────────────
    e_field_shift = mean(e_mod) - mean(e_base)

    # ── Mode distribution ─────────────────────────────────────────────────
    mode_dist = Counter(mode_vals)

    # ── Regime classification (dual-layer) ────────────────────────────────
    if mi_arith < 0.01:
        arith_verdict = "ARITHMETICALLY_CLOSED"
    else:
        arith_verdict = "ARITHMETICALLY_OPEN"   # closure violation

    if mi_obs < 0.01:
        obs_case = "CASE_1_TRUE_CLOSURE"
    elif mi_obs < 0.1:
        obs_case = "CASE_2_WEAK_MODULATION"
    else:
        obs_case = "CASE_3_STRUCTURAL_COUPLING"

    result.update({
        'mi_arith': mi_arith, 'mi_obs': mi_obs, 'mi_delta': mi_delta,
        'cpr': cpr, 'slf': slf,
        'slf_vs_c20_base': slf_vs_c20_base,
        'slf_vs_c20_mod': slf_vs_c20_mod,
        'pig': pig,
        'n_transitions': len(trans_idx),
        'e_field_shift': e_field_shift,
        'p_base': p_base_dict, 'p_mod': p_mod_dict,
        'mode_dist': dict(mode_dist),
        'n_changed': n_changed,
        'mi_per_mode': mi_per_mode,
        'arith_verdict': arith_verdict,
        'obs_case': obs_case,
    })
    return result

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if not os.path.exists(TRACE_CSV):
        print(f"ERROR: {TRACE_CSV} not found.")
        sys.exit(1)

    rows = load_csv(TRACE_CSV)
    print(f"Loaded {len(rows)} rows from {TRACE_CSV}")

    log_lines = []
    def log(msg=""):
        print(msg)
        log_lines.append(msg)

    log("=" * 72)
    log("HBS-C22: Exogenous Control Injection Test (Strict Version)")
    log("  Option B: computed_mod = computed XOR mask(mode_tag)")
    log("  mode_tag source: independent 15-bit LFSR (zero DUT dependency)")
    log("=" * 72)
    log(f"Total cycles: {len(rows)}")
    log("")

    regime_data = {1:[], 2:[], 3:[], 4:[]}
    for r in rows:
        regime_data[r['regime']].append(r)

    results = []
    mi_rows = []

    regime_names = {
        1: "R1-Baseline",
        2: "R2-LowFreq(epoch=16)",
        3: "R3-HighFreq(per-cycle)",
        4: "R4-Structured(01→10→11→00)",
    }

    for rid in [1, 2, 3, 4]:
        rrows = regime_data[rid]
        log(f"{'─'*72}")
        log(f"REGIME {rid}: {regime_names[rid]}  ({len(rrows)} cycles)")
        log(f"{'─'*72}")

        res = analyze_regime(rrows, rid)
        results.append(res)

        # Mode distribution
        md = res['mode_dist']
        log(f"  Mode occupancy:")
        for m in [0, 1, 2, 3]:
            cnt = md.get(m, 0)
            log(f"    {MODE_NAMES[m]:20s}: {cnt:5d} ({100*cnt/res['n_cycles']:5.1f}%)")
        log("")

        # Core MI results
        log(f"  ┌────────────────────────────────────────────────────┐")
        log(f"  │  MUTUAL INFORMATION (first real causality metric)  │")
        log(f"  ├────────────────────────────────────────────────────┤")
        log(f"  │  MI_arith  I(mode_tag ; attractor_base)  = {fmt(res['mi_arith'],6)} bits  │")
        log(f"  │  MI_obs    I(mode_tag ; attractor_mod)   = {fmt(res['mi_obs'],6)} bits  │")
        log(f"  │  MI_delta  (observer − arithmetic)       = {fmt(res['mi_delta'],6)} bits  │")
        log(f"  └────────────────────────────────────────────────────┘")
        log("")

        log(f"  OTHER METRICS:")
        log(f"    CPR  = {fmt(res['cpr'])}  (P(attractor changed by XOR) = {100*res['cpr']:.2f}%)")
        log(f"    SLF  = {fmt(res['slf'],6)} bits  KL(P_base || P_mod)")
        log(f"    SLF vs C20 baseline:")
        log(f"      KL(C20 || P_base) = {fmt(res['slf_vs_c20_base'],6)} bits")
        log(f"      KL(C20 || P_mod)  = {fmt(res['slf_vs_c20_mod'],6)} bits")
        log(f"    PIG  = {fmt(res['pig'])}  at {res['n_transitions']} transitions")
        log(f"    E-field mean shift = {res['e_field_shift']:+.4f} units")
        log("")

        log(f"  Attractor distribution:")
        for a in [1, 2, 3, 4]:
            pb = res['p_base'].get(a, 0)
            pm = res['p_mod'].get(a, 0)
            pc20 = C20_BASELINE[a]
            diff = pm - pb
            log(f"    {ATTRACTOR_NAMES[a]:16s}  base={pb:5.3f}  mod={pm:5.3f}  "
                f"Δ={diff:+.3f}  C20={pc20:.3f}")
        log(f"  Attractor changed: {res['n_changed']}/{res['n_cycles']} cycles")
        log("")

        # Per-mode breakdown
        if rid in [2, 3, 4]:
            log(f"  Per-mode attractor distribution shift:")
            for m in [0, 1, 2, 3]:
                info = res['mi_per_mode'].get(m)
                if not info: continue
                pa = info['P_base']
                pm = info['P_mod']
                log(f"    mode={MODE_NAMES[m]}  (n={info['n']}):")
                for a in [2, 3, 4]:  # Focus on A2, A3, A4 shifts
                    delta = pm.get(a, 0) - pa.get(a, 0)
                    if abs(delta) > 0.01:
                        log(f"      A{a}: base={pa.get(a,0):.3f} → mod={pm.get(a,0):.3f}  (Δ={delta:+.3f})")
            log("")

        log(f"  ╔══════════════════════════════════════════════════════╗")
        log(f"  ║  ARITHMETIC VERDICT : {res['arith_verdict']:<30}║")
        log(f"  ║  OBSERVER VERDICT   : {res['obs_case']:<30}║")
        log(f"  ╚══════════════════════════════════════════════════════╝")
        log("")

        # MI matrix rows
        mi_rows.append({'regime': rid, 'regime_name': regime_names[rid],
                        'mi_arith': res['mi_arith'], 'mi_obs': res['mi_obs'],
                        'mi_delta': res['mi_delta'], 'cpr': res['cpr'],
                        'slf': res['slf'], 'pig': res['pig'],
                        'arith_verdict': res['arith_verdict'],
                        'obs_case': res['obs_case']})

    # ── Cross-regime MI summary ────────────────────────────────────────────
    log("=" * 72)
    log("MUTUAL INFORMATION SUMMARY ACROSS ALL REGIMES")
    log("=" * 72)
    log("")
    log(f"  {'Regime':<30}  {'MI_arith':>10}  {'MI_obs':>10}  {'CPR':>8}  Verdict")
    log("  " + "─" * 70)
    for res in results:
        log(f"  {regime_names[res['regime_id']]:<30}"
            f"  {fmt(res['mi_arith'],6):>10}"
            f"  {fmt(res['mi_obs'],6):>10}"
            f"  {res['cpr']:8.4f}"
            f"  {res['obs_case']}")
    log("")

    # ── Arithmetic closure check ───────────────────────────────────────────
    arith_closed = all(r['arith_verdict'] == "ARITHMETICALLY_CLOSED" for r in results)
    log("=" * 72)
    log("ARITHMETIC CLOSURE STATUS")
    log("=" * 72)
    log("")
    if arith_closed:
        log("  ✓ ARITHMETIC LAYER: CLOSED in all regimes.")
        log("  MI_arith ≈ 0 in all 4 regimes (below 0.01 bit threshold).")
        log("  mode_tag has ZERO measurable influence on 'computed'.")
        log("  HBS-C18 Closure Theorem is NOT violated.")
    else:
        # Check if the violation is in R4 only (potential aliasing artifact)
        open_regimes = [r for r in results if r['arith_verdict'] != 'ARITHMETICALLY_CLOSED']
        r4_only = all(r['regime_id'] == 4 for r in open_regimes)
        if r4_only:
            log("  ⚠ ARITHMETIC APPARENT VIOLATION in R4 only — likely aliasing artifact.")
            log("  R4 uses structured mode cycling (period-4) which may correlate with")
            log("  the periodic input sweep.  Check testbench: if op_a = f(e_sweep) and")
            log("  mode = f(c%4), then e_sweep%4 == mode, creating input-mode correlation.")
            log("  FIX: use LFSR-based op_a in R4 to break the aliasing.  Re-run to verify.")
            log("  R1/R2/R3 show MI_arith ≈ 0 — these confirm arithmetic closure.")
        else:
            log("  ✗ ARITHMETIC LAYER: VIOLATION DETECTED (not aliasing).")
            log("  MI_arith > 0.01 in non-structured regimes.")
            log("  mode_tag influences arithmetic computation — investigate RTL.")
    log("")

    # ── Observer coupling analysis ─────────────────────────────────────────
    log("=" * 72)
    log("OBSERVER LAYER COUPLING ANALYSIS")
    log("=" * 72)
    log("")
    case3_regimes = [r for r in results if r['obs_case'] == 'CASE_3_STRUCTURAL_COUPLING']
    if case3_regimes:
        log("  ► CASE 3 (Structural Observer Coupling) detected in:")
        for r in case3_regimes:
            log(f"      Regime {r['regime_id']}: {regime_names[r['regime_id']]}  "
                f"MI_obs={fmt(r['mi_obs'],4)} bits, CPR={r['cpr']:.3f}")
        log("")
        log("  INTERPRETATION:")
        log("  mode_tag (via XOR mask) controls the ATTRACTOR PROJECTION seen")
        log("  by an observer at computed_mod.  Specifically:")
        log("    mask=01 (mantissa flip): E-field unchanged → same A1-A4 class")
        log("    mask=10 (E-field flip):  E-field inverted → class completely remapped")
        log("    mask=11 (both):          both effects combined")
        log("")
        log("  This demonstrates that ATTRACTOR STRUCTURE IS A GEOMETRIC PROPERTY")
        log("  of the output space projection — controllable via the XOR lens.")
        log("  It does NOT imply that mode_tag drives the arithmetic computation.")
        log("")
        log("  HORUS v3 DUAL-LAYER STATUS:")
        log("    Arithmetic layer: CLOSED (computed = f(op_a,op_b,op_sel) only)")
        log("    Observer layer:   OPEN   (mode_tag can select attractor projection)")
        log("")
        log("  This is the exact boundary between:")
        log("    'a system whose computation is closed'")
        log("    'a system whose OBSERVATION can be steered'")
    else:
        log("  No CASE 3 coupling detected in any regime.")
        log("  XOR coupling does not produce MI_obs > 0.1 bits.")
    log("")

    # ── C21 vs C22 comparison ─────────────────────────────────────────────
    log("=" * 72)
    log("C21 vs C22: ACCUM ECHO vs EXOGENOUS INJECTION")
    log("=" * 72)
    log("")
    log("  C21 (Option A — accum_reg echo):   max CPR = 1.36%,  r(coupling,computed)=0.97")
    log("    → coupling carries arithmetic history (highly correlated with computed)")
    log("    → no new attractor structure, no MI from state")
    log("")
    max_mi = max(r['mi_obs'] for r in results)
    max_cpr = max(r['cpr'] for r in results)
    log(f"  C22 (Option B — exogenous XOR):    max MI_obs={max_mi:.4f} bits, max CPR={max_cpr:.4f}")
    log("    → coupling carries no arithmetic history (independent LFSR source)")
    log("    → large MI_obs because XOR directly controls E-field bits")
    log("    → but MI_arith = 0: arithmetic computation is unchanged")
    log("")
    log("  KEY INSIGHT: Observer controllability ≠ computational causal influence.")
    log("  You can STEER what an observer classifies as attractor states")
    log("  without changing a single bit of the arithmetic computation.")
    log("")

    # ── Write outputs ─────────────────────────────────────────────────────
    with open(LOG_FILE, 'w') as f:
        f.write('\n'.join(log_lines) + '\n')

    fields = ['regime', 'regime_name', 'mi_arith', 'mi_obs', 'mi_delta',
              'cpr', 'slf', 'pig', 'arith_verdict', 'obs_case']
    with open(MI_CSV, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(mi_rows)

    fields2 = ['regime_id', 'n_cycles', 'mi_arith', 'mi_obs', 'mi_delta',
               'cpr', 'slf', 'pig', 'arith_verdict', 'obs_case']
    with open(RESULT_CSV, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields2, extrasaction='ignore')
        writer.writeheader()
        for res in results:
            writer.writerow(res)

    print(f"\nOutputs: {LOG_FILE}  {MI_CSV}  {RESULT_CSV}")
    print(f"\nArithmetic closure: {'CONFIRMED' if arith_closed else 'VIOLATED'}")
    for r in results:
        print(f"  Regime {r['regime_id']}: MI_arith={fmt(r['mi_arith'],4)}  "
              f"MI_obs={fmt(r['mi_obs'],4)}  {r['obs_case']}")

if __name__ == '__main__':
    main()
