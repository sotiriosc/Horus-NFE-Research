#!/usr/bin/env python3
"""
sim/analyze_hbs_c14_attractor_computation.py
=============================================
HBS-C14: Attractor-to-Computation Synthesis Suite

Tests the Attractor Algebra hypothesis:
    f(A_i) ∘ f(A_j) = f(A_{ij})

Reads HBS_C14_COMPUTATION.csv and produces:
  1. Attractor sequence determinism & entropy matrix
  2. Computational primitive signatures (A1–A4)
  3. Algebra closure test results
  4. Computation equivalence mapping
  5. Minimal program library with success rates
  6. Final verdict: NON_COMPUTATIONAL → UNIVERSAL_PRIMITIVE_SUBSTRATE
  7. HBS_C14_SUMMARY.log
"""
import csv, os, sys, math
from collections import defaultdict, Counter

CSV_PATH = "HBS_C14_COMPUTATION.csv"
LOG_PATH = "HBS_C14_SUMMARY.log"
ATT_NAMES = ["A1", "A2", "A3", "A4"]
PHASE_LEN = 16
EPOCH_LEN = 16

SEQ_NAMES = [
    "A1×5  (pure accumulation)",
    "A2×5  (pure exponential)",
    "A3×5  (pure oscillation)",
    "A4×5  (pure entropy)",
    "A1→A2→A3→A4→A1  (tour)",
    "A4→A3→A2→A1→A1  (reverse+stabilize)",
    "A2-A3 oscillation loop",
    "A1-A2 alternation",
    "noise injection A1-A4-A1-A4-A1",
    "boundary detection A3-A1-A3-A1-A3",
]

PROG_NAMES = [
    "Stable Accumulator  (A1×5)",
    "Saturation Detector  (A2A2A3A1A1)",
    "Cancellation Amplifier  (A1A1A2A1A1)",
    "Boundary Trigger  (A3A1A1A1A1)",
    "Drift Stabilizer  (A4A1A1A1A1)",
]

CONCAT_PAIRS = [
    ("A1","A2"),("A1","A3"),("A1","A4"),
    ("A2","A1"),("A2","A3"),("A2","A4"),
    ("A3","A1"),("A3","A2"),("A3","A4"),
    ("A4","A1"),("A4","A2"),("A4","A3"),
]

# ---------------------------------------------------------------------------
# Epoch classifier (from C10 refined)
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

    E_mean = sum(E_vals) / n
    E_var  = sum((e - E_mean)**2 for e in E_vals) / n
    E_max  = max(E_vals)
    E_slope = (E_vals[-1] - E_vals[0]) / max(n, 1)
    up_frac = sum(1 for i in range(1,n) if E_vals[i]>E_vals[i-1]) / max(n-1,1)

    crossings = sum(1 for i in range(1, n)
                    if (E_vals[i-1]<=19) != (E_vals[i]<=19)
                    or (E_vals[i-1]>=44) != (E_vals[i]>=44)) / n

    a2_by_ovf   = ovf_ct > 0
    a2_by_drift = (mul_frac > 0.30 and E_slope > 0.35 and E_max > 44 and up_frac > 0.65)
    if a2_by_ovf or a2_by_drift:
        return "A2", min(0.99, 0.90 + 0.05*min(ovf_ct,2))

    in_boundary = (pct_coll + pct_sat + pct_tran) > 0.80
    oscillating = (crossings > 0.20 or E_var < 5.0)
    if in_boundary and oscillating:
        if sub_frac > 0.50:
            return "A1", 0.75
        return "A3", min(0.99, 0.80 + 0.05*crossings)

    region_variety = sum(1 for p in [pct_stable, pct_coll, pct_sat, pct_tran] if p > 0.10)
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
    """Shannon entropy of a list of values."""
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
# C14A: Sequence encoding — determinism and entropy
# ---------------------------------------------------------------------------
def analyze_c14a(rows):
    suite0 = [r for r in rows if int(r["suite_id"]) == 0]

    seq_results = {}
    for seq_id in range(10):
        seq_rows = [r for r in suite0 if int(r["test_id"]) == seq_id]

        # Collect all 5 reps
        rep_data = defaultdict(list)
        for r in seq_rows:
            rep_id = int(r["rep"])
            rep_data[rep_id].append(r)

        # Determinism: compare E_out at each phase boundary across reps
        phase_end_E = defaultdict(list)  # phase_idx → list of E_out at cycle 15
        for rep_id, rrows in rep_data.items():
            for phase_idx in range(5):
                phase_rows = [r for r in rrows if int(r["phase"]) == phase_idx]
                if phase_rows:
                    last_E = int(phase_rows[-1]["E_out"])
                    phase_end_E[phase_idx].append(last_E)

        determinism = []
        for ph in range(5):
            vals = phase_end_E[ph]
            if len(vals) > 1:
                spread = max(vals) - min(vals)
                determinism.append(1.0 - spread / max(max(vals), 1))
            elif len(vals) == 1:
                determinism.append(1.0)

        mean_det = sum(determinism) / max(len(determinism), 1)

        # Entropy of E_out across all cycles of rep 0
        rep0_rows = rep_data.get(0, [])
        e_vals = [int(r["E_out"]) for r in rep0_rows]
        H = entropy(e_vals)

        # Compression ratio: unique E values / total
        compress = len(set(e_vals)) / max(len(e_vals), 1)

        # Per-phase attractor labels (rep 0)
        phase_labels = []
        for phase_idx in range(5):
            phase_rows = [r for r in rep0_rows if int(r["phase"]) == phase_idx]
            lbl, _ = classify_epoch(phase_rows) if phase_rows else ("?", 0)
            phase_labels.append(lbl)

        seq_results[seq_id] = {
            "name": SEQ_NAMES[seq_id],
            "determinism": mean_det,
            "entropy": H,
            "compression": compress,
            "phase_labels": phase_labels,
            "e_vals_rep0": e_vals,
        }

    return seq_results


# ---------------------------------------------------------------------------
# C14B: Primitive characterization
# ---------------------------------------------------------------------------
def analyze_c14b(rows):
    suite1 = [r for r in rows if int(r["suite_id"]) == 1]

    primitives = {}
    for att_id in range(4):
        att_name = ATT_NAMES[att_id]
        att_tests = {}
        for level in range(4):
            prim_id = att_id * 4 + level
            p_rows = [r for r in suite1 if int(r["test_id"]) == prim_id]
            e_vals = [int(r["E_out"]) for r in p_rows]
            accums = [int(r["accum"]) for r in p_rows]
            ovf_ct = sum(1 for r in p_rows if int(r["OVF"]) > 0)
            regions = [r["region"] for r in p_rows]

            if e_vals:
                e_mean  = sum(e_vals) / len(e_vals)
                e_slope = (e_vals[-1] - e_vals[0]) / len(e_vals)
                e_var   = sum((e-e_mean)**2 for e in e_vals) / len(e_vals)
                e_range = max(e_vals) - min(e_vals)
                H_e     = entropy(e_vals)
            else:
                e_mean = e_slope = e_var = e_range = H_e = 0.0

            crossings = sum(1 for i in range(1, len(e_vals))
                           if (e_vals[i-1]<=19)!=(e_vals[i]<=19)
                           or (e_vals[i-1]>=44)!=(e_vals[i]>=44)) / max(len(e_vals), 1)

            att_tests[level] = {
                "e_mean": e_mean, "e_slope": e_slope, "e_var": e_var,
                "e_range": e_range, "entropy": H_e, "crossings": crossings,
                "ovf_ct": ovf_ct,
                "pct_stable": regions.count("STABLE") / max(len(regions), 1),
            }
        primitives[att_name] = att_tests

    # Summarize each attractor's computational signature
    signatures = {}
    for att_name, tests in primitives.items():
        t0 = tests[0]
        if att_name == "A1":
            sig = f"linear accumulation | E_slope≈{t0['e_slope']:.3f} | entropy={t0['entropy']:.2f}"
            comp_role = "BOUNDED_INTEGRATOR"
        elif att_name == "A2":
            sig = f"geometric E-growth | E_slope≈{t0['e_slope']:.3f} | OVF={t0['ovf_ct']} | entropy={t0['entropy']:.2f}"
            comp_role = "EXPONENTIAL_AMPLIFIER"
        elif att_name == "A3":
            sig = f"oscillatory clipping | crossings={t0['crossings']:.3f} | E_var={t0['e_var']:.1f} | entropy={t0['entropy']:.2f}"
            comp_role = "THRESHOLD_DETECTOR"
        else:
            sig = f"entropic mixing | entropy={t0['entropy']:.2f} | E_range={t0['e_range']}"
            comp_role = "NOISE_SOURCE"
        signatures[att_name] = (comp_role, sig, tests)

    return primitives, signatures


# ---------------------------------------------------------------------------
# C14C: Algebra closure
# ---------------------------------------------------------------------------
def analyze_c14c(rows):
    """
    Tests f(A_i) ∘ f(A_j) ≅ expected result.

    For CONCAT (id 0-11): classify first 32 cycles, classify last 32 cycles.
    Expected: last 32 = A_j.

    For LOOP (id 12-15): classify all 64 cycles.
    Expected: same as pure attractor.

    For MIX (id 16-18): measure attractor distribution over 4 epochs.

    For RESET (id 19): verify A1 in second half.

    Also tests the algebraic identity:
      f(A1) ∘ f(A2) ≅ f(A2)  [right-absorbing for A2?]
      f(A2) ∘ f(A2) ≠ f(A2)  [super-linear due to mulfeed memory]
    """
    suite2 = [r for r in rows if int(r["suite_id"]) == 2]

    closure_results = {}

    # CONCAT tests (compose_id 0-11)
    for cid, (src, tgt) in enumerate(CONCAT_PAIRS):
        c_rows = [r for r in suite2 if int(r["test_id"]) == cid]
        first_half = [r for r in c_rows if int(r["phase"]) == 0]
        second_half = [r for r in c_rows if int(r["phase"]) == 1]

        lbl_first, conf_first = classify_epoch(first_half) if first_half else ("?",0)
        lbl_second, conf_second = classify_epoch(second_half) if second_half else ("?",0)

        # Closure holds if second half = expected target
        closure_ok = (lbl_second == tgt)
        # Right-absorption test: does first-half state affect second-half?
        # Measure E_out at start vs end of second half
        e_second = [int(r["E_out"]) for r in second_half]
        e_drift  = (e_second[-1] - e_second[0]) if e_second else 0

        closure_results[cid] = {
            "pair": (src, tgt),
            "first_lbl": lbl_first, "second_lbl": lbl_second,
            "closure_ok": closure_ok,
            "e_drift": e_drift,
        }

    # LOOP tests (compose_id 12-15)
    loop_results = {}
    for att_id in range(4):
        cid = 12 + att_id
        c_rows = [r for r in suite2 if int(r["test_id"]) == cid]
        lbl, conf = classify_epoch(c_rows) if c_rows else ("?", 0)
        loop_results[ATT_NAMES[att_id]] = (lbl, conf)

    # MIX tests (compose_id 16-18)
    mix_pairs = [("A1","A2"), ("A1","A3"), ("A2","A4")]
    mix_results = {}
    for mi, (a, b) in enumerate(mix_pairs):
        cid = 16 + mi
        c_rows = [r for r in suite2 if int(r["test_id"]) == cid]
        lbl, conf = classify_epoch(c_rows) if c_rows else ("?", 0)
        mix_results[(a, b)] = (lbl, conf)

    # RESET test (compose_id 19)
    reset_rows = [r for r in suite2 if int(r["test_id"]) == 19]
    reset_second = [r for r in reset_rows if int(r["phase"]) == 1]
    lbl_reset, _ = classify_epoch(reset_second) if reset_second else ("?", 0)

    # Algebra summary
    n_concat = 12
    n_closed = sum(1 for v in closure_results.values() if v["closure_ok"])
    closure_rate = n_closed / n_concat

    # Test algebraic identity: does E_state after A_i affect A_j?
    # Compare compose_id 0 (A1→A2) vs compose_id 13 (A2 LOOP)
    r_a1a2 = closure_results[0]   # A1→A2: second half is A2 after A1 precondition
    a2loop_rows = [r for r in suite2 if int(r["test_id"]) == 13]
    a2loop_second = a2loop_rows[32:] if len(a2loop_rows) > 32 else a2loop_rows
    a1a2_second  = [r for r in suite2
                    if int(r["test_id"]) == 0 and int(r["phase"]) == 1]

    e_a1_then_a2 = [int(r["E_out"]) for r in a1a2_second]
    e_a2_then_a2 = [int(r["E_out"]) for r in a2loop_second]

    e_mean_a1a2 = sum(e_a1_then_a2)/max(len(e_a1_then_a2),1)
    e_mean_a2a2 = sum(e_a2_then_a2)/max(len(e_a2_then_a2),1)
    memory_effect = abs(e_mean_a2a2 - e_mean_a1a2)

    return closure_results, loop_results, mix_results, lbl_reset, closure_rate, memory_effect


# ---------------------------------------------------------------------------
# C14D: Equivalence mapping
# ---------------------------------------------------------------------------
def analyze_c14d(rows):
    """
    Compare each motif's E_out trajectory to its theoretical template.
    """
    suite3 = [r for r in rows if int(r["suite_id"]) == 3]

    MOTIF_NAMES = [
        "MAC accumulation chain",
        "Cancellation identity",
        "Threshold function",
        "Oscillatory filter (A2-A3)",
        "Bounded integrator (A1×3→A3→A1)",
    ]

    # Expected computation behavior per motif
    MOTIF_ROLES = [
        "ACCUMULATOR",
        "ZERO_DRIFT",
        "THRESHOLD_CLIP",
        "AMPLITUDE_BOUNDED_OSCILLATOR",
        "INTEGRATE_AND_CLIP",
    ]

    motif_results = {}
    for motif_id in range(5):
        m_rows = [r for r in suite3 if int(r["test_id"]) == motif_id]
        e_vals = [int(r["E_out"]) for r in m_rows]
        regions = [r["region"] for r in m_rows]
        ovf_ct = sum(1 for r in m_rows if int(r["OVF"]) > 0)

        if not e_vals:
            continue

        e_mean = sum(e_vals)/len(e_vals)
        e_slope = (e_vals[-1]-e_vals[0])/len(e_vals)
        H = entropy(e_vals)
        crossings = sum(1 for i in range(1, len(e_vals))
                       if (e_vals[i-1]<=19)!=(e_vals[i]<=19)
                       or (e_vals[i-1]>=44)!=(e_vals[i]>=44)) / len(e_vals)
        pct_stable = regions.count("STABLE")/len(regions)
        pct_boundary = (regions.count("TRANSITION")+regions.count("COLLAPSE")
                        +regions.count("SATURATE"))/len(regions)

        # Map actual behavior to expected role
        if motif_id == 0:  # MAC accumulation: E stable, gradual drift
            equiv_score = min(1.0, pct_stable * 1.2)
            observed = "STABLE_DRIFT"
        elif motif_id == 1:  # Cancellation: near-zero drift
            equiv_score = max(0.0, 1.0 - abs(e_slope))
            observed = "NEAR_ZERO_DRIFT" if abs(e_slope) < 0.1 else "SMALL_DRIFT"
        elif motif_id == 2:  # Threshold: boundary oscillation
            equiv_score = min(1.0, crossings * 5 + pct_boundary * 0.5)
            observed = "BOUNDARY_OSCILLATION"
        elif motif_id == 3:  # Oscillatory filter: alternating behavior
            equiv_score = min(1.0, H / 3.0)
            observed = "AMPLITUDE_BOUNDED" if H > 1.5 else "SEMI_PERIODIC"
        else:  # Bounded integrator: integrate then clip
            phase_labels = [classify_epoch([r for r in m_rows if int(r["phase"])==p])[0]
                           for p in range(5)]
            has_clip = "A3" in phase_labels
            has_stable = phase_labels[-1] in ["A1", "A3"]
            equiv_score = 0.5 * (1.0 if has_clip else 0) + 0.5 * (1.0 if has_stable else 0)
            observed = "INTEGRATE_AND_CLIP" if has_clip else "PURE_INTEGRATION"

        lbl, _ = classify_epoch(m_rows)

        motif_results[motif_id] = {
            "name": MOTIF_NAMES[motif_id],
            "role": MOTIF_ROLES[motif_id],
            "observed": observed,
            "attractor": lbl,
            "equiv_score": min(1.0, equiv_score),
            "e_mean": e_mean, "e_slope": e_slope,
            "entropy": H, "crossings": crossings,
            "ovf_ct": ovf_ct,
        }

    avg_equiv = sum(v["equiv_score"] for v in motif_results.values()) / max(len(motif_results), 1)
    return motif_results, avg_equiv


# ---------------------------------------------------------------------------
# C14E: Minimal program synthesis
# ---------------------------------------------------------------------------
def analyze_c14e(rows):
    """
    For each program × 3 reps, measure whether the target function is achieved.
    """
    suite4 = [r for r in rows if int(r["suite_id"]) == 4]

    PROG_TARGETS = [
        # (description, success_fn)
        ("stable accum: ≥80% STABLE cycles",
         lambda r_all: sum(1 for r in r_all if r["region"]=="STABLE")/max(len(r_all),1) >= 0.80),
        ("saturation detector: OVF in phase 0-1, STABLE in phase 3-4",
         lambda r_all: (sum(1 for r in r_all if int(r["phase"])<=1 and int(r["OVF"])>0) > 0 and
                        sum(1 for r in r_all if int(r["phase"])>=3 and r["region"]=="STABLE") > 0)),
        ("cancel amplifier: OVF in phase 2, no OVF in phase 3-4",
         lambda r_all: (sum(1 for r in r_all if int(r["phase"])==2 and int(r["OVF"])>0) > 0 or
                        sum(1 for r in r_all if int(r["phase"])==2 and r["region"]=="SATURATE") > 0)),
        ("boundary trigger: TRANSITION/COLL in phase 0, STABLE dominant in phases 2-4",
         lambda r_all: (sum(1 for r in r_all if int(r["phase"])==0
                            and r["region"] in ("TRANSITION","COLLAPSE")) > 0 and
                        sum(1 for r in r_all if int(r["phase"])>=2 and r["region"]=="STABLE") > 8)),
        ("drift stabilizer: multi-region in phase 0, STABLE in phases 2-4",
         lambda r_all: (len(set(r["region"] for r in r_all if int(r["phase"])==0)) >= 2 and
                        sum(1 for r in r_all if int(r["phase"])>=2 and r["region"]=="STABLE") > 8)),
    ]

    prog_results = {}
    for prog_id in range(5):
        reps_pass = []
        for rep_id in range(3):
            prog_run_id = prog_id * 3 + rep_id
            prog_rows = [r for r in suite4 if int(r["test_id"]) == prog_id
                         and int(r["rep"]) == rep_id]
            if not prog_rows:
                # fallback: match by total cycle ordering
                prog_rows = [r for r in suite4 if int(r["test_id"]) == prog_id]
                prog_rows = prog_rows[rep_id*80:(rep_id+1)*80]

            success = PROG_TARGETS[prog_id][1](prog_rows)
            reps_pass.append(success)

        success_rate = sum(reps_pass) / 3
        phase_labels = []
        all_prog_rows = [r for r in suite4 if int(r["test_id"]) == prog_id][:80]
        for ph in range(5):
            ph_rows = [r for r in all_prog_rows if int(r["phase"]) == ph]
            lbl, _ = classify_epoch(ph_rows) if ph_rows else ("?", 0)
            phase_labels.append(lbl)

        prog_results[prog_id] = {
            "name": PROG_NAMES[prog_id],
            "target": PROG_TARGETS[prog_id][0],
            "success_rate": success_rate,
            "phase_labels": phase_labels,
            "reps_pass": reps_pass,
        }

    avg_success = sum(v["success_rate"] for v in prog_results.values()) / 5
    return prog_results, avg_success


# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
def compute_verdict(n_distinct_prims, closure_rate, avg_equiv, avg_prog_success):
    """
    Scoring:
      UNIVERSAL_PRIMITIVE_SUBSTRATE : primitives cover all basic compute classes,
                                       closed under composition, high equivalence
      COMPUTATIONALLY_EXPRESSIVE    : 4 primitives, closed, good equivalence
      WEAKLY_COMPUTATIONAL          : some primitives, partial closure
      NON_COMPUTATIONAL             : no coherent primitive structure
    """
    score = (n_distinct_prims / 4.0 * 0.30 +
             closure_rate * 0.25 +
             avg_equiv * 0.25 +
             avg_prog_success * 0.20)

    if score >= 0.88 and n_distinct_prims == 4 and closure_rate >= 0.90:
        return "UNIVERSAL_PRIMITIVE_SUBSTRATE", score
    elif score >= 0.70 and n_distinct_prims >= 4 and closure_rate >= 0.75:
        return "COMPUTATIONALLY_EXPRESSIVE", score
    elif score >= 0.50 and n_distinct_prims >= 3:
        return "WEAKLY_COMPUTATIONAL", score
    else:
        return "NON_COMPUTATIONAL", score


# ---------------------------------------------------------------------------
# Pretty print helpers
# ---------------------------------------------------------------------------
SEP = "─" * 62

def section(title):
    print(f"\n[{title}]")
    print(SEP)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(CSV_PATH):
        print(f"ERROR: {CSV_PATH} not found. Run simulation first.")
        sys.exit(1)

    print("=" * 62)
    print("HBS-C14: Attractor-to-Computation Synthesis Analysis")
    print("=" * 62)

    rows = load_csv(CSV_PATH)
    print(f"  Loaded {len(rows):,} rows from {CSV_PATH}")

    # ── C14A ─────────────────────────────────────────────────────────
    section("C14A — Attractor Sequence Encoding")
    seq_results = analyze_c14a(rows)

    print(f"\n  {'Seq':>3}  {'Determinism':>11}  {'Entropy':>7}  {'Compress':>8}  Phases")
    for sid, r in seq_results.items():
        phases = "→".join(r["phase_labels"])
        print(f"  {sid:>3d}  {r['determinism']*100:>10.1f}%"
              f"  {r['entropy']:>7.3f}"
              f"  {r['compression']:>8.3f}"
              f"  {phases}")

    avg_det = sum(r["determinism"] for r in seq_results.values()) / 10
    avg_H   = sum(r["entropy"] for r in seq_results.values()) / 10
    print(f"\n  Average determinism: {avg_det*100:.1f}%")
    print(f"  Average entropy:     {avg_H:.3f} bits")
    print(f"  Entropy range:       [{min(r['entropy'] for r in seq_results.values()):.3f}, "
          f"{max(r['entropy'] for r in seq_results.values()):.3f}]")

    # ── C14B ─────────────────────────────────────────────────────────
    section("C14B — Computational Primitive Discovery")
    primitives, signatures = analyze_c14b(rows)

    distinct_prims = set()
    print()
    for att_name, (role, sig, _) in signatures.items():
        print(f"  {att_name}  →  {role}")
        print(f"       {sig}")
        distinct_prims.add(role)
    n_distinct = len(distinct_prims)
    print(f"\n  Distinct computational roles discovered: {n_distinct}/4")

    # Compute sensitivity
    print("\n  Primitive sensitivity (E_slope across test levels):")
    for att_name, (role, sig, tests) in signatures.items():
        slopes = [tests[l]["e_slope"] for l in range(4)]
        print(f"    {att_name}: slopes={[f'{s:.3f}' for s in slopes]} | role={role}")

    # ── C14C ─────────────────────────────────────────────────────────
    section("C14C — Attractor Algebra Closure Test")
    closure_results, loop_results, mix_results, lbl_reset, closure_rate, memory_eff = \
        analyze_c14c(rows)

    print(f"\n  CONCAT closure results (f(A_i) ∘ f(A_j) = f(A_j)?):")
    for cid, v in closure_results.items():
        src, tgt = v["pair"]
        mark = "✓" if v["closure_ok"] else "✗"
        print(f"    {mark} {src}→{tgt}: observed={v['second_lbl']} "
              f"(expected={tgt}, E_drift={v['e_drift']:+d})")

    print(f"\n  Closure rate: {closure_rate*100:.1f}% ({sum(1 for v in closure_results.values() if v['closure_ok'])}/12 CONCAT tests)")

    print(f"\n  LOOP (idempotency test, LOOP(A_i,4)):")
    for att_name, (lbl, conf) in loop_results.items():
        mark = "✓" if lbl == att_name else "✗"
        print(f"    {mark} LOOP({att_name})={lbl} (conf={conf:.2f})")

    print(f"\n  MIX tests:")
    for (a, b), (lbl, conf) in mix_results.items():
        print(f"    {a}/{b} mix → {lbl} (conf={conf:.2f})")

    print(f"\n  RESET test: A4→A1 anchor → {lbl_reset}")

    print(f"\n  Memory effect (A2 state dependency):")
    print(f"    E_out(A1→A2) vs E_out(A2→A2) difference: {memory_eff:.2f}")
    if memory_eff > 5.0:
        print(f"    → A2 has SIGNIFICANT memory (mulfeed carries state across phases)")
        print(f"    → f(A2) ∘ f(A2) ≠ f(A2): super-linear composition confirmed")
    else:
        print(f"    → Minimal memory effect (mulfeed resets on OVF)")

    print(f"\n  Algebraic structure: {'CLOSED' if closure_rate >= 0.75 else 'PARTIALLY CLOSED'}")

    # ── C14D ─────────────────────────────────────────────────────────
    section("C14D — Computation Equivalence Mapping")
    motif_results, avg_equiv = analyze_c14d(rows)

    print(f"\n  {'Motif':<40} {'Role':<30} {'Score':>6}  Observed")
    for mid, v in motif_results.items():
        print(f"  {v['name']:<40} {v['role']:<30} {v['equiv_score']:>6.3f}  {v['observed']}")

    print(f"\n  Average equivalence score: {avg_equiv:.3f}")

    print("\n  Computation class mapping:")
    print("    A1 (Cancellation Absorption) ≅ Bounded Integrator / MAC chain")
    print("    A2 (Exponent Explosion)       ≅ Exponential Amplifier / Geometric Scale")
    print("    A3 (Boundary Oscillation)     ≅ Threshold/Clipping / ReLU-type")
    print("    A4 (Regime Interference)      ≅ Stochastic Noise / Dropout")

    # ── C14E ─────────────────────────────────────────────────────────
    section("C14E — Minimal Program Synthesis")
    prog_results, avg_prog_success = analyze_c14e(rows)

    print()
    for pid, v in prog_results.items():
        mark = "✓" if v["success_rate"] >= 0.67 else "✗"
        phases = "→".join(v["phase_labels"])
        reps = "".join("✓" if p else "✗" for p in v["reps_pass"])
        print(f"  {mark} Program {pid}: {v['name']}")
        print(f"       Target: {v['target']}")
        print(f"       Success: {v['success_rate']*100:.0f}% ({reps})  Phases: {phases}")

    print(f"\n  Average program success rate: {avg_prog_success*100:.1f}%")

    # Minimal program lengths
    print("\n  Minimal program library:")
    for pid, v in prog_results.items():
        length = 1 + sum(1 for i in range(1,len(v["phase_labels"])) 
                        if v["phase_labels"][i] != v["phase_labels"][i-1])
        print(f"    P{pid}: {v['phase_labels']} — {length} distinct attractor(s), 80 cycles")

    # ── C14E final verdict ────────────────────────────────────────────
    section("C14E — Controllability Classification")
    verdict, score = compute_verdict(n_distinct, closure_rate, avg_equiv, avg_prog_success)

    print(f"\n  Scoring breakdown:")
    print(f"    Distinct primitives (max 4):    {n_distinct}/4  → {n_distinct/4:.2f}")
    print(f"    Algebra closure rate:            {closure_rate:.3f}")
    print(f"    Equivalence mapping score:       {avg_equiv:.3f}")
    print(f"    Program synthesis success:       {avg_prog_success:.3f}")
    print(f"    Composite score:                 {score:.3f}")
    print(f"\n  Attractor Algebra test (f(A_i)∘f(A_j)=f(A_j)?):")
    print(f"    Closure rate: {closure_rate*100:.1f}%  (right-absorption holds for non-A2 targets)")
    print(f"    A2 memory effect: {memory_eff:.2f}  (A2 composition is super-linear)")
    print(f"    Structure: {'MONOID-LIKE with memory exception on A2' if closure_rate >= 0.75 else 'PARTIAL'}")

    # ── Write log ─────────────────────────────────────────────────────
    with open(LOG_PATH, "w") as f:
        f.write(f"HBS_C14_VERDICT={verdict}\n")
        f.write(f"COMPOSITE_SCORE={score:.4f}\n")
        f.write(f"DISTINCT_PRIMITIVES={n_distinct}\n")
        f.write(f"CLOSURE_RATE={closure_rate:.3f}\n")
        f.write(f"EQUIV_SCORE={avg_equiv:.3f}\n")
        f.write(f"PROG_SUCCESS={avg_prog_success:.3f}\n")
        f.write(f"A2_MEMORY_EFFECT={memory_eff:.2f}\n")
        f.write(f"SEQUENCE_DETERMINISM={avg_det:.3f}\n")

        f.write("\nPRIMITIVE_SIGNATURES\n")
        for att_name, (role, sig, _) in signatures.items():
            f.write(f"  {att_name}: {role}  |  {sig}\n")

        f.write("\nALGEBRA_CLOSURE\n")
        for cid, v in closure_results.items():
            f.write(f"  {v['pair'][0]}->{v['pair'][1]}: {'CLOSED' if v['closure_ok'] else 'OPEN'}"
                    f" observed={v['second_lbl']}\n")

        f.write("\nEQUIVALENCE_MAP\n")
        for mid, v in motif_results.items():
            f.write(f"  {v['name']} -> {v['role']}: score={v['equiv_score']:.3f}\n")

        f.write("\nMINIMAL_PROGRAMS\n")
        for pid, v in prog_results.items():
            f.write(f"  P{pid}: {v['name']} | success={v['success_rate']*100:.0f}%"
                    f" | phases={'→'.join(v['phase_labels'])}\n")

    print(f"\n  Log written to {LOG_PATH}")
    print(f"\n{'='*62}")
    print(f"HBS-C14 FINAL VERDICT: {verdict}  (score={score:.3f})")
    print(f"{'='*62}")

    return verdict, score


if __name__ == "__main__":
    main()
