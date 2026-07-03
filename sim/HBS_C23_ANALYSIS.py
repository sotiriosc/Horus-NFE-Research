#!/usr/bin/env python3
"""
HBS-C23: Observer-Decoupling Falsification Suite
=================================================
Tests whether HORUS v3 attractors (A1–A4) are INTRINSIC dynamical properties
or COORDINATE ARTIFACTS of the specific E-field extraction result[11:6].

All four observer transforms are applied to the same DUT output simultaneously.
Results are compared cycle-by-cycle against the ground truth (E_obs standard).

Transforms tested:
  STD   Ground truth   E_obs = result[11:6]                    (standard)
  R1    Desync         E_alt = result[9:4] XOR result[12:7]   (bit-scramble)
  R2    Nonlinear      pop_r2= popcount(result XOR accum_reg)  (Hamming domain)
  R3    Lagged         E_lag = result(t-1)[11:6]              (1-cycle delay)
  R4    Rotation       x'=rotl(result,k) XOR epoch_mask       (epoch-varying)

Metrics computed for each transform:
  1.  Attractor distribution  P(A1), P(A2), P(A3), P(A4)
  2.  Cross-regime disagreement rate  P(attr_T ≠ attr_STD)
  3.  Mutual information  MI(attr_STD ; attr_T)  [bits]
  4.  Transition entropy  H(attr(t)→attr(t+1))  [bits per transition]
  5.  Per-attractor conditional survival  P(attr_T = x | attr_STD = x)
  6.  A3 invariance check  P(attr_T = A3 | attr_STD = A3)  (fail if < 0.5)
  7.  A1↔A2 swap rate  P(attr_T = A2 | attr_STD = A1)  (fail if > 0.1)
  8.  R4 per-epoch disagreement (to see which rotations break most)

Pass/Fail conditions (from spec):
  PASS:  All transforms show < 5% cross-regime disagreement
  FAIL — MODEL BREAKS if any of:
    • Attractor identity changes under R2 or R4  (distribution shift > 10 pp in any bin)
    • MI drops to ~0 under any nonlinear embedding  (MI < 0.05 bits)
    • A3 ceases to be invariant under R3 lag  (P(A3|A3) < 0.5)
    • A1/A2 swap under R4 rotation  (P(A2|A1) > 0.10)

Scientific framing:
  If the model HOLDS: attractors are coordinate-invariant dynamical properties.
  If the model BREAKS: attractors are observer-frame artifacts defined by the
    E-field extraction convention, not intrinsic to the computation.
"""

import sys
import csv
import math
import os
from collections import Counter, defaultdict

TRACE_CSV  = "HBS_C23_OBSERVER_TRACE.csv"
LOG_FILE   = "HBS_C23_SUMMARY.log"
RESULT_CSV = "HBS_C23_REGIME_RESULTS.csv"

ATTR_NAMES  = {1: "A1", 2: "A2", 3: "A3", 4: "A4"}
FAIL_THRESHOLD_DISAGREE   = 0.05   # > 5% disagree → model holds criterion violated
FAIL_THRESHOLD_DIST_SHIFT = 0.10   # > 10 pp distribution shift → identity change
FAIL_THRESHOLD_MI_LOW     = 0.05   # MI < 0.05 bits → nearly uncorrelated
FAIL_A3_INVARIANCE        = 0.50   # P(A3|A3) < 0.5 → A3 fails invariance
FAIL_A1_SWAP              = 0.10   # P(A2|A1) > 0.10 → A1/A2 swap

# ── Utilities ─────────────────────────────────────────────────────────────────

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

def mutual_information_bits(x_vals, y_vals):
    n = len(x_vals)
    if n == 0: return float('nan')
    joint = Counter(zip(x_vals, y_vals))
    cx, cy = Counter(x_vals), Counter(y_vals)
    mi = 0.0
    for (x, y), cnt in joint.items():
        p_xy = cnt/n; p_x = cx[x]/n; p_y = cy[y]/n
        if p_xy > 0 and p_x > 0 and p_y > 0:
            mi += p_xy * math.log2(p_xy / (p_x * p_y))
    return max(mi, 0.0)

def transition_entropy(attr_seq):
    """Entropy of empirical 1-step Markov transition distribution H(A(t+1)|A(t))."""
    trans = defaultdict(Counter)
    for t in range(len(attr_seq)-1):
        trans[attr_seq[t]][attr_seq[t+1]] += 1
    h = 0.0
    p_state = Counter(attr_seq[:-1])
    n_total = len(attr_seq) - 1
    for s, next_cnts in trans.items():
        p_s = p_state[s] / n_total
        total_from_s = sum(next_cnts.values())
        for ns, cnt in next_cnts.items():
            p_ns_given_s = cnt / total_from_s
            if p_ns_given_s > 0:
                h -= p_s * p_ns_given_s * math.log2(p_ns_given_s)
    return h

def attractor_dist(attr_list):
    n = len(attr_list)
    c = Counter(attr_list)
    return {k: c.get(k, 0)/n for k in [1, 2, 3, 4]}

def conditional_survival(attr_std, attr_transform, target):
    """P(attr_T = target | attr_STD = target)"""
    idx = [i for i, a in enumerate(attr_std) if a == target]
    if not idx: return float('nan')
    match = sum(1 for i in idx if attr_transform[i] == target)
    return match / len(idx)

def conditional_map(attr_std, attr_transform, src, dst):
    """P(attr_T = dst | attr_STD = src)"""
    idx = [i for i, a in enumerate(attr_std) if a == src]
    if not idx: return float('nan')
    match = sum(1 for i in idx if attr_transform[i] == dst)
    return match / len(idx)

def fmt(v, d=4):
    if math.isnan(v) or math.isinf(v): return f"{v}"
    return f"{v:.{d}f}"

def dist_max_shift(p_ref, p_alt):
    """Max absolute distribution shift across all bins."""
    return max(abs(p_alt.get(a, 0) - p_ref.get(a, 0)) for a in [1, 2, 3, 4])

# ── Per-transform analysis ────────────────────────────────────────────────────

def analyze_transform(rows, std_col, trans_col, disagree_col, label, trans_type='e'):
    """
    Compute all metrics for one observer transform.
    trans_type: 'e' = standard E-field classifier, 'pop' = popcount
    """
    n = len(rows)
    attr_std  = [r['attr_std']    for r in rows]
    attr_t    = [r[trans_col]     for r in rows]
    disagree  = [r[disagree_col]  for r in rows]

    dist_std  = attractor_dist(attr_std)
    dist_t    = attractor_dist(attr_t)

    mi        = mutual_information_bits(attr_std, attr_t)
    disagree_rate = sum(disagree) / n
    max_shift = dist_max_shift(dist_std, dist_t)

    h_std = transition_entropy(attr_std)
    h_t   = transition_entropy(attr_t)

    # Per-attractor conditional survival
    surv = {a: conditional_survival(attr_std, attr_t, a) for a in [1, 2, 3, 4]}

    # A1/A2 swap
    a1_to_a2 = conditional_map(attr_std, attr_t, 1, 2)
    a2_to_a1 = conditional_map(attr_std, attr_t, 2, 1)

    # A3 invariance
    a3_survival = surv.get(3, float('nan'))

    return {
        'label': label,
        'n': n,
        'dist_std': dist_std,
        'dist_t': dist_t,
        'mi': mi,
        'disagree_rate': disagree_rate,
        'max_shift': max_shift,
        'h_std': h_std,
        'h_t': h_t,
        'surv': surv,
        'a1_to_a2': a1_to_a2,
        'a2_to_a1': a2_to_a1,
        'a3_survival': a3_survival,
    }

def analyze_r4_per_epoch(rows):
    """Disagree rate per rotation amount in R4."""
    epoch_stats = defaultdict(lambda: {'n': 0, 'disagree': 0})
    for r in rows:
        k = r['rot_k']
        epoch_stats[k]['n'] += 1
        epoch_stats[k]['disagree'] += r['r4_disagree']
    result = {}
    for k in sorted(epoch_stats.keys()):
        s = epoch_stats[k]
        result[k] = s['disagree'] / s['n'] if s['n'] > 0 else float('nan')
    return result

# ── Pass/Fail engine ──────────────────────────────────────────────────────────

def check_pass_fail(res_r1, res_r2, res_r3, res_r4):
    fails = []
    passes = []

    # Cross-regime disagreement (<5% = PASS)
    for res in [res_r1, res_r2, res_r3, res_r4]:
        if res['disagree_rate'] > FAIL_THRESHOLD_DISAGREE:
            fails.append(f"{res['label']}: disagree_rate={res['disagree_rate']:.3f} > 5%")
        else:
            passes.append(f"{res['label']}: disagree_rate={res['disagree_rate']:.3f} ≤ 5% ✓")

    # Attractor identity change under R2 or R4 (>10 pp dist shift)
    for res in [res_r2, res_r4]:
        if res['max_shift'] > FAIL_THRESHOLD_DIST_SHIFT:
            fails.append(f"{res['label']}: max_dist_shift={res['max_shift']:.3f} > 10 pp → identity changed")

    # MI drop to ~0 under nonlinear (R2)
    if res_r2['mi'] < FAIL_THRESHOLD_MI_LOW:
        fails.append(f"R2: MI={res_r2['mi']:.4f} < 0.05 bits → near-zero observer coupling")

    # A3 invariance under lag (R3)
    a3_surv = res_r3['a3_survival']
    if not math.isnan(a3_surv) and a3_surv < FAIL_A3_INVARIANCE:
        fails.append(f"R3: P(A3|A3)={a3_surv:.3f} < 0.5 → A3 not invariant under lag")
    else:
        passes.append(f"R3: P(A3|A3)={fmt(a3_surv)} ≥ 0.5 ✓")

    # A1/A2 swap under R4
    a1_swap = res_r4['a1_to_a2']
    if not math.isnan(a1_swap) and a1_swap > FAIL_A1_SWAP:
        fails.append(f"R4: P(A2|A1)={a1_swap:.3f} > 0.10 → A1/A2 swap under rotation")
    else:
        passes.append(f"R4: P(A2|A1)={fmt(a1_swap)} ≤ 0.10 ✓")

    if fails:
        verdict = "MODEL BREAKS"
    else:
        verdict = "MODEL HOLDS"

    return verdict, fails, passes

# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    if not os.path.exists(TRACE_CSV):
        print(f"ERROR: {TRACE_CSV} not found."); sys.exit(1)

    rows = load_csv(TRACE_CSV)
    print(f"Loaded {len(rows)} rows from {TRACE_CSV}")

    log_lines = []
    def log(msg=""):
        print(msg); log_lines.append(msg)

    log("=" * 72)
    log("HBS-C23: Observer-Decoupling Falsification Suite")
    log("  One-line question: 'Does the attractor system survive when the")
    log("  coordinate system itself is destroyed?'")
    log("=" * 72)
    log(f"Total cycles: {len(rows)}")
    log("")

    # Analyze all four transforms
    res_std = analyze_transform(rows, 'attr_std', 'attr_std', 'r1_disagree',  # dummy
                                'STD (ground truth)')
    res_r1  = analyze_transform(rows, 'attr_std', 'attr_r1',  'r1_disagree',  'R1-Desync')
    res_r2  = analyze_transform(rows, 'attr_std', 'attr_r2',  'r2_disagree',  'R2-PopCount')
    res_r3  = analyze_transform(rows, 'attr_std', 'attr_r3',  'r3_disagree',  'R3-Lag1')
    res_r4  = analyze_transform(rows, 'attr_std', 'attr_r4',  'r4_disagree',  'R4-Rotation')

    r4_epoch_stats = analyze_r4_per_epoch(rows)

    transforms = [
        ('STD', res_std, 'E_obs = result[11:6]            (ground truth)'),
        ('R1',  res_r1,  'E_alt = result[9:4]^result[12:7] (desync)'),
        ('R2',  res_r2,  'E_r2  = popcount(result^accum)   (Hamming domain)'),
        ('R3',  res_r3,  'E_r3  = result(t-1)[11:6]        (1-cycle lag)'),
        ('R4',  res_r4,  'E_r4  = x\'[11:6], x\'=rotl+XOR   (rotation)'),
    ]

    for tag, res, desc in transforms:
        log(f"{'─'*72}")
        log(f"OBSERVER: {tag}  —  {desc}")
        log(f"{'─'*72}")

        d_std = res['dist_std']
        d_t   = res['dist_t']
        log(f"  Attractor distribution (std | this transform):")
        for a in [1, 2, 3, 4]:
            shift = d_t.get(a,0) - d_std.get(a,0)
            log(f"    A{a}: std={d_std.get(a,0):.4f}  T={d_t.get(a,0):.4f}  Δ={shift:+.4f}")
        log("")

        if tag != 'STD':
            log(f"  Disagreement rate:  {res['disagree_rate']*100:.2f}%")
            log(f"  Max dist. shift:    {res['max_shift']:.4f}  (>{FAIL_THRESHOLD_DIST_SHIFT:.2f} = identity changed)")
            log(f"  MI(std;transform):  {fmt(res['mi'],4)} bits  (<{FAIL_THRESHOLD_MI_LOW} = near-zero)")
            log(f"  Transition entropy: std={res['h_std']:.4f} bits  T={res['h_t']:.4f} bits")
            log("")
            log(f"  Conditional survival P(attr_T = x | attr_STD = x):")
            for a in [1, 2, 3, 4]:
                sv = res['surv'].get(a, float('nan'))
                flag = " ← IDENTITY LOST" if not math.isnan(sv) and sv < 0.5 else ""
                log(f"    A{a}: {fmt(sv)}{flag}")
            log(f"  A1→A2 swap rate: P(T=A2|S=A1) = {fmt(res['a1_to_a2'])}"
                f"  (>{FAIL_A1_SWAP} = swap)")
            log(f"  A2→A1 swap rate: P(T=A1|S=A2) = {fmt(res['a2_to_a1'])}")
            log(f"  A3 survival:     P(T=A3|S=A3) = {fmt(res['a3_survival'])}"
                f"  (<{FAIL_A3_INVARIANCE} = A3 invariance broken)")
        log("")

    # R4 per-rotation breakdown
    log("=" * 72)
    log("R4: PER-ROTATION-AMOUNT DISAGREEMENT RATE")
    log("=" * 72)
    log("")
    log(f"  {'rot_k':>6}  {'disagree%':>10}  assessment")
    log("  " + "─" * 30)
    for k in sorted(r4_epoch_stats.keys()):
        rate = r4_epoch_stats[k]
        flag = " ← LARGE" if rate > 0.30 else ""
        log(f"  {k:>6}  {rate*100:>10.2f}%{flag}")
    log("")

    # A3 deep analysis for R3
    log("=" * 72)
    log("A3 INVARIANCE UNDER LAGGED OBSERVATION (R3 DEEP ANALYSIS)")
    log("=" * 72)
    log("")
    attr_std_list = [r['attr_std'] for r in rows]
    attr_r3_list  = [r['attr_r3']  for r in rows]

    n_a3_std  = sum(1 for a in attr_std_list if a == 3)
    n_a3_r3   = sum(1 for a in attr_r3_list  if a == 3)

    log(f"  A3 cycles (standard observer): {n_a3_std} ({100*n_a3_std/len(rows):.2f}%)")
    log(f"  A3 cycles (lagged observer):   {n_a3_r3} ({100*n_a3_r3/len(rows):.2f}%)")
    log("")

    # What does the lagged observer see when standard = A3?
    a3_cycles_std = [(i, rows[i]) for i, r in enumerate(rows) if r['attr_std'] == 3]
    if a3_cycles_std:
        lag_view = Counter(r['attr_r3'] for _, r in a3_cycles_std)
        total = sum(lag_view.values())
        log(f"  When attr_STD=A3 (n={total}), lagged observer sees:")
        for a in [1, 2, 3, 4]:
            cnt = lag_view.get(a, 0)
            log(f"    A{a}: {cnt} ({100*cnt/total:.1f}%)")
    log("")

    # What does standard see when standard(t-1) → standard(t) crosses A3?
    log("  A3 boundary analysis:")
    log(f"    At E=63 (A3): E(t-1) is likely E=62 → A2")
    log(f"    At E=0  (A1): E(t-1) is likely E=63 → A3")
    log(f"    → Lagged A3 appears as A2, lagged A1 appears as A3 (E-field sweep)")
    log("")

    # Overall Summary Table
    log("=" * 72)
    log("SUMMARY TABLE: All 4 observer transforms vs ground truth")
    log("=" * 72)
    log("")
    log(f"  {'Transform':<14}  {'Disagree%':>9}  {'MaxShift':>9}  {'MI(bits)':>9}  "
        f"{'P(A3|A3)':>9}  {'P(A2|A1)':>9}")
    log("  " + "─" * 70)
    for _, res, _ in transforms[1:]:
        log(f"  {res['label']:<14}"
            f"  {res['disagree_rate']*100:>9.2f}"
            f"  {res['max_shift']:>9.4f}"
            f"  {fmt(res['mi'],4):>9}"
            f"  {fmt(res['a3_survival'],4):>9}"
            f"  {fmt(res['a1_to_a2'],4):>9}")
    log("")

    # Pass/Fail
    verdict, fails, passes = check_pass_fail(res_r1, res_r2, res_r3, res_r4)

    log("=" * 72)
    log("PASS / FAIL VERDICT")
    log("=" * 72)
    log("")
    if fails:
        log(f"  ╔══════════════════════════════════════════════════════╗")
        log(f"  ║  MODEL BREAKS — Attractor system is coordinate-     ║")
        log(f"  ║  DEPENDENT (observer artifacts, not invariants)     ║")
        log(f"  ╚══════════════════════════════════════════════════════╝")
        log("")
        log("  FAIL conditions triggered:")
        for f in fails:
            log(f"    ✗ {f}")
    else:
        log(f"  ╔══════════════════════════════════════════════════════╗")
        log(f"  ║  MODEL HOLDS — Attractors are coordinate-invariant  ║")
        log(f"  ╚══════════════════════════════════════════════════════╝")
    log("")
    if passes:
        log("  PASS conditions satisfied:")
        for p in passes:
            log(f"    ✓ {p}")
    log("")

    # Interpretation
    log("=" * 72)
    log("SCIENTIFIC INTERPRETATION")
    log("=" * 72)
    log("")
    if verdict == "MODEL BREAKS":
        log("  HORUS v3 attractors (A1–A4) are OBSERVER-FRAME ARTIFACTS.")
        log("")
        log("  They are stable ONLY in the specific coordinate system defined")
        log("  by the standard E-field extraction: result[11:6].")
        log("")
        log("  Destroy that coordinate system (via desync, popcount, lag, or")
        log("  rotation) and the attractor labels change — sometimes dramatically.")
        log("")
        log("  This does NOT invalidate the COMPUTATION — `computed` is still")
        log("  fully deterministic and produces consistent arithmetic results.")
        log("  What is invalidated is the CLAIM that A1–A4 are intrinsic")
        log("  dynamical invariants independent of observation frame.")
        log("")
        log("  The correct characterization of HORUS v3 after C23:")
        log("    • Arithmetic: invariant, frame-independent (proved C18–C22)")
        log("    • Attractors: observer-defined, frame-dependent (proved C23)")
        log("    • Causal closure: holds for arithmetic (proved C18–C22)")
        log("    • Attractor labels: NOT causally invariant under coord change")
    else:
        log("  HORUS v3 attractors exhibit coordinate invariance.")
        log("  A1–A4 structure survives all four observer transforms.")
        log("  The attractor system is a genuine dynamical property.")
    log("")

    # Write outputs
    with open(LOG_FILE, 'w') as f:
        f.write('\n'.join(log_lines) + '\n')

    csv_rows = []
    for _, res, _ in transforms[1:]:
        csv_rows.append({
            'transform': res['label'],
            'disagree_rate': res['disagree_rate'],
            'max_shift': res['max_shift'],
            'mi': res['mi'],
            'h_std': res['h_std'],
            'h_t': res['h_t'],
            'a3_survival': res['a3_survival'],
            'a1_to_a2': res['a1_to_a2'],
            'a2_to_a1': res['a2_to_a1'],
            'verdict': verdict,
        })

    fields = ['transform','disagree_rate','max_shift','mi','h_std','h_t',
              'a3_survival','a1_to_a2','a2_to_a1','verdict']
    with open(RESULT_CSV, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(csv_rows)

    print(f"\nOutputs: {LOG_FILE}  {RESULT_CSV}")
    print(f"\nVERDICT: {verdict}")
    for res in [res_r1, res_r2, res_r3, res_r4]:
        print(f"  {res['label']:14}: disagree={res['disagree_rate']*100:.2f}%  "
              f"MI={fmt(res['mi'],4)} bits  A3_surv={fmt(res['a3_survival'],4)}")

if __name__ == '__main__':
    main()
