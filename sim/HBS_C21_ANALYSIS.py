#!/usr/bin/env python3
"""
HBS-C21: Controlled Feedback Coupling Experiment
  Option A — Accumulator Right-Shift Injection
  computed_mod = computed + (accum_reg >> k)
=================================================
This analysis measures EMERGENCE, not closure.

We are asking:
  "When state is allowed to modulate the arithmetic observation,
   what structure appears in the output?"

Expected regime classification:
  Regime 1 — No penetration   : AII ≈ 0, CPR < 0.01
  Regime 2 — Linear bleed     : small measurable coupling, attractor bias shifts
  Regime 3 — Phase takeover   : output clusters into A1-A4 structure

Metrics
-------
AII  Attractor Imprint Index
     How much of computed_mod variance is explained by the BASE attractor state.
     = eta² (ANOVA effect size):
         AII = SS_between / SS_total
         where groups are the A1-A4 classifications of 'computed'.
     Range 0–1.  0 = no imprint.  1 = perfect imprint.

CPR  Causal Penetration Ratio
     Fraction of computed_mod variance attributable to the coupling term.
     = Var(coupling_term) / Var(computed_mod)
     Equivalent to R² of regression: computed_mod ~ a*coupling + computed_base

PIG  Phase Injection Gain
     At attractor TRANSITION cycles (when computed changes attractor class),
     does computed_mod show amplified jumps?
     PIG = mean(delta_mod_at_transition) / mean(delta_computed_at_transition)
     PIG > 1  → transitions are amplified by the coupling

SLF  Stability Loss Function
     Mean squared deviation of computed_mod from computed, normalized.
     = E[(computed_mod - computed)²] / Var(computed)
     = Var(coupling_term) / Var(computed)    (since coupling_term = computed_mod - computed)
     In dB: SLF_dB = 10*log10(SLF)

Additionally report:
  - Attractor distribution shift (computed vs computed_mod)
  - E-field correlation: how much does coupling_term correlate with e_field_base?
  - Multi-cycle leakage: does coupling_term show lag-correlation with computed?
"""

import sys
import csv
import math
import os
import statistics

TRACE_CSV = "HBS_C21_FEEDBACK_TRACE.csv"
LOG_FILE  = "HBS_C21_SUMMARY.log"
RESULT_CSV = "HBS_C21_REGIME_RESULTS.csv"

ATTRACTOR_NAMES = {1: "A1(cancel)", 2: "A2(explode)", 3: "A3(rollover)", 4: "A4(entropic)"}

# ── Utilities ─────────────────────────────────────────────────────────────────

def pearson(x, y):
    n = len(x)
    if n < 2: return float('nan')
    mx, my = sum(x)/n, sum(y)/n
    num = sum((xi-mx)*(yi-my) for xi,yi in zip(x,y))
    sx  = math.sqrt(sum((xi-mx)**2 for xi in x))
    sy  = math.sqrt(sum((yi-my)**2 for yi in y))
    if sx < 1e-9 or sy < 1e-9: return float('nan')
    return num / (sx*sy)

def variance(vals):
    if len(vals) < 2: return 0.0
    m = sum(vals)/len(vals)
    return sum((v-m)**2 for v in vals) / len(vals)

def mean(vals):
    if not vals: return float('nan')
    return sum(vals) / len(vals)

def eta_squared(vals, groups):
    """ANOVA eta² effect size: SS_between / SS_total."""
    n = len(vals)
    if n < 2: return float('nan')
    grand_mean = mean(vals)
    ss_total = sum((v - grand_mean)**2 for v in vals)
    if ss_total < 1e-9: return float('nan')
    group_vals = {}
    for v, g in zip(vals, groups):
        group_vals.setdefault(g, []).append(v)
    ss_between = sum(
        len(gv) * (mean(gv) - grand_mean)**2
        for gv in group_vals.values()
    )
    return ss_between / ss_total

def fmt(v, decimals=6):
    if math.isnan(v): return "NaN"
    return f"{v:.{decimals}f}"

def attractor_dist(attr_list):
    dist = {1:0, 2:0, 3:0, 4:0}
    for a in attr_list: dist[a] = dist.get(a, 0) + 1
    return dist

# ── Load ──────────────────────────────────────────────────────────────────────

def load_csv(fname):
    rows = []
    with open(fname, newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            parsed = {}
            for k, v in row.items():
                v = v.strip()
                parsed[k] = int(v) if v not in ('', 'x') else 0
            rows.append(parsed)
    return rows

# ── Main ──────────────────────────────────────────────────────────────────────

def analyze_regime(rrows, regime_id, shift_k):
    result = {}

    computed_vals  = [r['computed']      for r in rrows]
    mod_vals       = [r['computed_mod']  for r in rrows]
    coupling_vals  = [r['coupling_term'] for r in rrows]
    attr_base      = [r['attractor_base'] for r in rrows]
    attr_mod       = [r['attractor_mod']  for r in rrows]
    delta_comp     = [r['delta_computed'] for r in rrows]
    delta_mod      = [r['delta_mod']      for r in rrows]
    transitions    = [r['transition_base'] for r in rrows]
    e_base         = [r['e_field_base']   for r in rrows]
    e_mod          = [r['e_field_mod']    for r in rrows]

    n = len(rrows)

    # ── AII: Attractor Imprint Index ─────────────────────────────────────
    # AII_base: intrinsic correlation of 'computed' with its OWN attractor class.
    #   High by construction — E-field classification IS derived from computed.
    # AII_mod: same classification applied to computed_mod.
    # AII_delta: CHANGE induced by coupling.  This is the meaningful metric.
    aii_base  = eta_squared(computed_vals, attr_base)
    aii       = eta_squared(mod_vals, attr_base)
    aii_delta = aii - aii_base   # positive = coupling amplifies structure

    # ── CPR: Causal Penetration Ratio ─────────────────────────────────────
    var_coupling = variance(coupling_vals)
    var_mod      = variance(mod_vals)
    cpr = var_coupling / var_mod if var_mod > 1e-9 else float('nan')

    # ── SLF: Stability Loss Function ──────────────────────────────────────
    # = E[(computed_mod - computed)²] / Var(computed)
    sq_dev   = [(m - c)**2 for m, c in zip(mod_vals, computed_vals)]
    slf      = mean(sq_dev) / variance(computed_vals) if variance(computed_vals) > 1e-9 else float('nan')
    slf_db   = 10*math.log10(slf) if not math.isnan(slf) and slf > 1e-30 else float('-inf')

    # ── PIG: Phase Injection Gain ─────────────────────────────────────────
    trans_idx  = [i for i, t in enumerate(transitions) if t > 0 and i > 0]
    if trans_idx:
        dc_trans = [delta_comp[i] for i in trans_idx]
        dm_trans = [delta_mod[i]  for i in trans_idx]
        mean_dc  = mean(dc_trans)
        mean_dm  = mean(dm_trans)
        pig = mean_dm / mean_dc if mean_dc > 1e-6 else float('nan')
    else:
        pig = float('nan')
        mean_dc = mean_dm = 0.0

    # ── Attractor distribution shift ─────────────────────────────────────
    dist_base = attractor_dist(attr_base)
    dist_mod  = attractor_dist(attr_mod)

    # Fraction of cycles where attractor classification CHANGED
    n_changed = sum(r['attractor_changed'] for r in rrows)
    frac_changed = n_changed / n

    # ── E-field statistics ────────────────────────────────────────────────
    e_field_shift = mean(e_mod) - mean(e_base)  # mean E-field bias

    # ── Coupling term statistics ──────────────────────────────────────────
    coupling_mean   = mean(coupling_vals)
    coupling_max    = max(coupling_vals)
    coupling_nonzero = sum(1 for v in coupling_vals if v > 0)

    # ── Pearson r: coupling_term vs computed ──────────────────────────────
    r_coupling_computed = pearson(coupling_vals, computed_vals)

    # ── Regime classification ─────────────────────────────────────────────
    # Use AII_delta (not raw AII) to avoid the intrinsic self-correlation
    # of 'computed' with its own classification.  CPR threshold also tightened.
    aii_d = aii_delta if not math.isnan(aii_delta) else 0.0
    cpr_v = cpr       if not math.isnan(cpr)       else 0.0
    if cpr_v >= 0.10 or aii_d >= 0.05:
        regime_class = "REGIME_3_PHASE_TAKEOVER"
    elif cpr_v >= 0.01 or aii_d >= 0.01:
        regime_class = "REGIME_2_LINEAR_BLEED"
    else:
        regime_class = "REGIME_1_NO_PENETRATION"

    result.update({
        'regime_id': regime_id, 'shift_k': shift_k, 'n_cycles': n,
        'aii_base': aii_base, 'aii': aii, 'aii_delta': aii_delta,
        'cpr': cpr, 'pig': pig, 'slf': slf, 'slf_db': slf_db,
        'frac_attractor_changed': frac_changed,
        'e_field_shift': e_field_shift,
        'coupling_mean': coupling_mean, 'coupling_max': coupling_max,
        'coupling_nonzero': coupling_nonzero,
        'r_coupling_computed': r_coupling_computed,
        'n_transitions': len(trans_idx),
        'mean_delta_comp_at_trans': mean_dc,
        'mean_delta_mod_at_trans': mean_dm,
        'dist_base': dist_base, 'dist_mod': dist_mod,
        'regime_class': regime_class,
    })
    return result

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
    log("HBS-C21: Controlled Feedback Coupling Experiment")
    log("  Option A: computed_mod = computed + (accum_reg >> k)")
    log("=" * 72)
    log(f"Total cycles: {len(rows)}")
    log("")

    regime_data = {1: [], 2: [], 3: []}
    for r in rows:
        regime_data[r['regime']].append(r)

    regime_shifts = {1: 12, 2: 10, 3: 8}
    results = []

    # ──────────────────────────────────────────────────────────────────────────
    for rid in [1, 2, 3]:
        rrows = regime_data[rid]
        sk    = regime_shifts[rid]

        log(f"{'─'*72}")
        log(f"REGIME {rid}: shift_k={sk}  "
            f"({'weak — mantissa only' if sk==12 else 'medium — low E-field' if sk==10 else 'strong — full E-field'})"
            f"  ({len(rrows)} cycles)")
        log(f"{'─'*72}")

        res = analyze_regime(rrows, rid, sk)
        results.append(res)

        log(f"  Coupling term:  mean={res['coupling_mean']:.2f}  "
            f"max={res['coupling_max']}  "
            f"non-zero={res['coupling_nonzero']}/{res['n_cycles']}")
        log(f"  r(coupling,computed) = {fmt(res['r_coupling_computed'])}")
        log("")

        log(f"  METRICS:")
        log(f"    AII_base (computed self-correlation) = {fmt(res['aii_base'])} ← intrinsic (E-field → class)")
        log(f"    AII_mod  (computed_mod correlation)  = {fmt(res['aii'])} ")
        log(f"    AII_delta (coupling-induced imprint)  = {fmt(res['aii_delta'])} "
            f"{'← IMPRINT' if not math.isnan(res['aii_delta']) and res['aii_delta']>=0.01 else '← no imprint'}")
        log(f"    CPR  (Causal Penetration Ratio)   = {fmt(res['cpr'])} "
            f"({'= {:.3%} of variance'.format(res['cpr']) if not math.isnan(res['cpr']) else 'NaN'})")
        log(f"    SLF  (Stability Loss Function)    = {fmt(res['slf'])}  "
            f"({fmt(res['slf_db'], 2)} dB)")
        log(f"    PIG  (Phase Injection Gain)       = {fmt(res['pig'])} "
            f"({'× amplification at transitions' if not math.isnan(res['pig']) else 'NaN (no transitions)'})")
        log("")

        log(f"  Attractor distribution (base computed vs computed_mod):")
        for a in [1, 2, 3, 4]:
            nb  = res['dist_base'].get(a, 0)
            nm  = res['dist_mod'].get(a, 0)
            pct_b = 100*nb/res['n_cycles']
            pct_m = 100*nm/res['n_cycles']
            arrow = " ← shifted" if abs(nb-nm) > 5 else ""
            log(f"    {ATTRACTOR_NAMES[a]:16s}  base={nb:5d} ({pct_b:5.1f}%)  "
                f"mod={nm:5d} ({pct_m:5.1f}%){arrow}")
        log(f"  Attractor class changed: {res['n_cycles']*res['frac_attractor_changed']:.0f}"
            f" / {res['n_cycles']} cycles ({100*res['frac_attractor_changed']:.2f}%)")
        log(f"  E-field mean shift: {res['e_field_shift']:+.4f} units")
        log("")
        log(f"  Transition analysis ({res['n_transitions']} attractor transitions):")
        log(f"    mean |Δcomputed|   at transitions = {res['mean_delta_comp_at_trans']:.4f}")
        log(f"    mean |Δcomputed_mod| at transitions = {res['mean_delta_mod_at_trans']:.4f}")
        if not math.isnan(res['pig']):
            log(f"    PIG = {res['pig']:.4f}  "
                f"({'amplified' if res['pig'] > 1.0 else 'attenuated' if res['pig'] < 1.0 else 'neutral'})")
        log("")

        log(f"  ╔═══════════════════════════════════════════╗")
        log(f"  ║  REGIME {rid} CLASSIFICATION: {res['regime_class']:<21}║")
        log(f"  ╚═══════════════════════════════════════════╝")
        log("")

    # ──────────────────────────────────────────────────────────────────────────
    log("=" * 72)
    log("SUMMARY ACROSS ALL REGIMES")
    log("=" * 72)
    log("")
    log(f"{'Regime':<10}{'k':<6}{'AII_base':>12}{'AII_Δ':>10}{'CPR':>10}{'SLF_dB':>10}{'PIG':>9}  Classification")
    log("─" * 80)
    for res in results:
        log(f"  R{res['regime_id']} k={res['shift_k']:<4}"
            f"  {fmt(res['aii_base']):>12}"
            f"  {fmt(res['aii_delta']):>10}"
            f"  {fmt(res['cpr']):>10}"
            f"  {fmt(res['slf_db'],2):>8} dB"
            f"  {fmt(res['pig']):>9}"
            f"  {res['regime_class']}")
    log("")

    # ── Cross-regime CPR scaling check ────────────────────────────────────
    log("CPR scaling with k:")
    for res in results:
        bar_len = int(res['cpr'] * 100) if not math.isnan(res['cpr']) else 0
        log(f"  k={res['shift_k']:2d}: CPR={fmt(res['cpr'])}  {'█'*min(bar_len,60)}")
    log("")

    # ── Phase takeover detection ──────────────────────────────────────────
    any_takeover = any(r['regime_class'] == 'REGIME_3_PHASE_TAKEOVER' for r in results)
    any_bleed    = any(r['regime_class'] == 'REGIME_2_LINEAR_BLEED'   for r in results)

    log("=" * 72)
    log("SCIENTIFIC INTERPRETATION")
    log("=" * 72)
    log("")
    if any_takeover:
        log("  ► PHASE TAKEOVER detected in at least one regime.")
        log("    The feedback coupling is strong enough that computed_mod begins")
        log("    clustering into A1-A4 structure independent of the input.")
        log("    This converts HORUS from a pure arithmetic system to a")
        log("    state-modulated dynamical system (hybrid regime).")
    elif any_bleed:
        log("  ► LINEAR BLEED detected. No phase takeover.")
        log("    The feedback coupling introduces measurable but bounded deviation.")
        log("    computed_mod ≠ computed, but the deviation is proportional to")
        log("    the coupling term — no nonlinear amplification observed.")
        log("    System remains classifiable as 'closed with external bias envelope'.")
    else:
        log("  ► NO PENETRATION in all tested regimes.")
        log("    Even with explicit feedback coupling, computed_mod shows no")
        log("    attractor imprinting from state.  The arithmetic subspace is so")
        log("    structurally dominant that weak state injection is lost in signal.")
        log("    Confirms: causal isolation is not just a property of the boundary —")
        log("    it is a property of the arithmetic signal MAGNITUDE.")

    log("")
    log("")
    # Key insight: r(coupling, computed) reveals whether the coupling carries
    # genuinely NEW state information or just the arithmetic's own echo.
    r_vals = [r['r_coupling_computed'] for r in results if not math.isnan(r['r_coupling_computed'])]
    if r_vals:
        r_mean = sum(r_vals) / len(r_vals)
        log(f"  KEY FINDING: r(coupling_term, computed) = {r_mean:.4f}")
        if r_mean > 0.9:
            log("  The coupling term is nearly identical to a scaled version of 'computed'.")
            log("  accum_reg = ∫ computed dt (time-integral over accumulation epochs).")
            log("  Feeding it back adds an ECHO of the arithmetic history — not new state info.")
            log("  This is a SELF-REINFORCING feedback, not a cross-domain coupling.")
        elif r_mean > 0.5:
            log("  The coupling term partially tracks 'computed' (moderate correlation).")
        else:
            log("  The coupling term is largely decorrelated from 'computed' — genuine cross-domain.")
    log("")
    log("  Closure status: Arithmetic core (computed) remains UNMODIFIED.")
    log("  The coupling is a side-channel term, not a feedback loop.")
    log("  computed_mod is an OBSERVER LAYER quantity, not an architectural one.")
    log("")

    # ── Boundary between closed and open systems ──────────────────────────
    log("=" * 72)
    log("BOUNDARY BETWEEN DIGITAL ARITHMETIC AND COMPUTATIONAL DYNAMICS")
    log("=" * 72)
    log("")
    log("  Digital arithmetic (closed):  dynamics → accumulation only")
    log("  Computational dynamics (open): dynamics → modulate the function")
    log("")
    cprs = [r['cpr'] for r in results if not math.isnan(r['cpr'])]
    if cprs:
        cpr_max = max(cprs)
        log(f"  Maximum CPR observed:  {cpr_max:.6f}")
        if cpr_max < 0.01:
            log("  → System is firmly in the digital arithmetic regime.")
            log("    CPR < 1%: state cannot penetrate the arithmetic domain.")
        elif cpr_max < 0.10:
            log("  → System is at the boundary (hybrid zone).")
            log("    CPR 1-10%: state creates a detectable arithmetic bias envelope.")
        else:
            log("  → System has crossed into computational dynamics.")
            log("    CPR > 10%: state drives more than 10% of arithmetic variance.")
    log("")

    # ── Write outputs ─────────────────────────────────────────────────────
    with open(LOG_FILE, 'w') as f:
        f.write('\n'.join(log_lines) + '\n')

    fields = ['regime_id','shift_k','n_cycles','aii_base','aii','aii_delta','cpr','pig','slf','slf_db',
              'frac_attractor_changed','e_field_shift',
              'coupling_mean','coupling_max','coupling_nonzero',
              'r_coupling_computed','n_transitions',
              'mean_delta_comp_at_trans','mean_delta_mod_at_trans',
              'regime_class']
    with open(RESULT_CSV, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(results)

    print(f"\nLogs: {LOG_FILE}  Results: {RESULT_CSV}")
    classes = [r['regime_class'] for r in results]
    for i, c in enumerate(classes, 1):
        print(f"  Regime {i} (k={regime_shifts[i]}): {c}")
    return classes

if __name__ == '__main__':
    main()
