#!/usr/bin/env python3
"""
sim/analyze_hbs_c13_attractor_control.py
=========================================
HBS-C13: Attractor Controllability & Phase Steering Suite
Reads HBS_C13_CONTROL.csv and produces:
  - Attractor transition success matrix (4×4)
  - Minimal control signal table
  - Basin geometry classification
  - Control cost ranking
  - Reachability graph
  - Controllability verdict
  - HBS_C13_SUMMARY.log
"""
import csv, os, sys, math
from collections import defaultdict, Counter

CSV_PATH  = "HBS_C13_CONTROL.csv"
LOG_PATH  = "HBS_C13_SUMMARY.log"
EPOCH_LEN = 16
ATT_NAMES = ["A1", "A2", "A3", "A4"]
BASELINE_CYCS = 100
TARGET_CYCS   = 160
TRANS_CYCS    = 260
SUCCESS_THRESH = 0.70   # target attractor ≥ 70% of next 10 epochs

# ---------------------------------------------------------------------------
# Epoch classifier (inherited + refined from C10)
# ---------------------------------------------------------------------------
def classify_epoch(rows):
    if not rows:
        return "A1", 0.50

    ops      = [r["op"] for r in rows]
    E_vals   = [int(r["E_out"]) for r in rows]
    regions  = [r["region"] for r in rows]
    ovf_ct   = sum(1 for r in rows if int(r["OVF"]) > 0)
    uf_ct    = sum(1 for r in rows if int(r["UF"]) > 0)
    n        = len(rows)

    mul_frac  = ops.count("MUL") / n
    sub_frac  = ops.count("SUB") / n
    add_frac  = ops.count("ADD") / n

    pct_stable = regions.count("STABLE") / n
    pct_coll   = regions.count("COLLAPSE") / n
    pct_sat    = regions.count("SATURATE") / n
    pct_tran   = regions.count("TRANSITION") / n

    E_mean = sum(E_vals) / n
    E_var  = sum((e - E_mean)**2 for e in E_vals) / n
    E_max  = max(E_vals)
    E_min  = min(E_vals)

    E_slope = (E_vals[-1] - E_vals[0]) / max(n, 1)

    # boundary crossings: count transitions between E ≤ 19 and E ≥ 20
    crossings = sum(1 for i in range(1, n)
                    if (E_vals[i-1] <= 19) != (E_vals[i] <= 19)
                    or (E_vals[i-1] >= 44) != (E_vals[i] >= 44)) / n

    up_moves   = sum(1 for i in range(1, n) if E_vals[i] > E_vals[i-1])
    up_frac    = up_moves / max(n - 1, 1)

    # A2: geometric drift — MUL chain, upward E
    a2_by_ovf   = ovf_ct > 0
    a2_by_drift = (mul_frac > 0.30 and E_slope > 0.35 and E_max > 44 and up_frac > 0.65)
    if a2_by_ovf or a2_by_drift:
        conf = min(0.99, 0.90 + 0.05 * min(ovf_ct, 2))
        return "A2", conf

    # A3: boundary oscillation — ADD near boundary, high crossings or constant TRANSITION
    in_boundary_zone = (pct_coll + pct_sat + pct_tran) > 0.80
    oscillating      = (crossings > 0.20 or E_var < 5.0)
    if in_boundary_zone and oscillating:
        if sub_frac > 0.50:
            return "A1", 0.75   # cancellation at boundary → still A1 type
        return "A3", min(0.99, 0.80 + 0.05 * crossings)

    # A4: entropic regime — mixed ops, multiple regions coexist
    region_variety = sum(1 for p in [pct_stable, pct_coll, pct_sat, pct_tran] if p > 0.10)
    if region_variety >= 3 and add_frac < 0.70 and mul_frac < 0.60:
        return "A4", 0.80

    # A1: cancellation residual — SUB dominant in STABLE
    if sub_frac >= 0.50 and pct_stable > 0.60:
        return "A1", min(0.99, 0.80 + 0.10 * sub_frac)

    # Fallback
    if pct_stable > 0.70:
        return "A1", 0.70
    if pct_coll > 0.50:
        return "A3", 0.65
    if pct_sat > 0.50:
        return "A2", 0.65
    return "A4", 0.55


# ---------------------------------------------------------------------------
# Helper: classify windows of EPOCH_LEN rows
# ---------------------------------------------------------------------------
def epoch_labels(rows):
    labels = []
    for i in range(0, len(rows), EPOCH_LEN):
        chunk = rows[i:i+EPOCH_LEN]
        if chunk:
            lbl, _ = classify_epoch(chunk)
            labels.append(lbl)
    return labels


# ---------------------------------------------------------------------------
# Load CSV
# ---------------------------------------------------------------------------
def load_csv(path):
    rows = []
    with open(path, newline="") as fh:
        rdr = csv.DictReader(fh)
        for r in rdr:
            rows.append(r)
    return rows


# ---------------------------------------------------------------------------
# C13A: Transition success matrix
# ---------------------------------------------------------------------------
def analyze_c13a(rows):
    """
    Returns:
      success_matrix: dict (src_att, tgt_att) → success_rate
      latency_matrix: dict (src_att, tgt_att) → avg_latency_epochs
      cost_matrix:    dict (src_att, tgt_att) → description str
    """
    TRANS_MAP = [
        (0, 1), (0, 2), (0, 3),  # A1→A2, A1→A3, A1→A4
        (1, 0), (1, 2), (1, 3),  # A2→A1, A2→A3, A2→A4
        (2, 0), (2, 1), (2, 3),  # A3→A1, A3→A2, A3→A4
        (3, 0), (3, 1), (3, 2),  # A4→A1, A4→A2, A4→A3
    ]

    suite0 = [r for r in rows if int(r["suite_id"]) == 0]
    success_matrix   = {}
    latency_matrix   = {}
    baseline_verify  = {}

    for tid, (src, tgt) in enumerate(TRANS_MAP):
        src_name = ATT_NAMES[src]
        tgt_name = ATT_NAMES[tgt]

        trans_rows = [r for r in suite0 if int(r["test_id"]) == tid]
        base_rows  = [r for r in trans_rows if int(r["phase"]) == 0]
        tgt_rows   = [r for r in trans_rows if int(r["phase"]) == 1]

        # Verify baseline
        base_labels = epoch_labels(base_rows)
        base_ok = base_labels.count(src_name) / max(len(base_labels), 1)

        # Target phase success (10 epochs of 16 cycles each)
        tgt_labels = epoch_labels(tgt_rows)
        n_tgt = len(tgt_labels)
        n_success = tgt_labels.count(tgt_name)
        rate = n_success / max(n_tgt, 1)

        # Latency: first epoch index where target appears
        latency = None
        for i, lbl in enumerate(tgt_labels):
            if lbl == tgt_name:
                latency = i
                break
        if latency is None:
            latency = n_tgt  # never succeeded

        key = (src_name, tgt_name)
        success_matrix[key]  = rate
        latency_matrix[key]  = latency
        baseline_verify[key] = (base_ok, base_labels)

    return success_matrix, latency_matrix, baseline_verify


# ---------------------------------------------------------------------------
# C13B: Minimal control signal
# ---------------------------------------------------------------------------
def analyze_c13b(rows):
    """
    For each (perturb_att, perturb_level), measure target attractor occupancy.
    Returns: minimal_level per transition pair.
    """
    PERTURB_TRANS = [
        ("A1", "A2"),
        ("A1", "A3"),
        ("A2", "A1"),
        ("A3", "A1"),
    ]
    LEVEL_NAMES = [
        "FULL_TARGET",
        "HALF_INTERLEAVE",
        "E_SHIFT_±1",
        "SOURCE_ONLY",
        "1_IN_8_INJECTION",
    ]

    suite1 = [r for r in rows if int(r["suite_id"]) == 1]
    results = {}
    sensitivity = {}

    for att_idx, (src, tgt) in enumerate(PERTURB_TRANS):
        results[(src, tgt)] = {}
        for level in range(5):
            pid = att_idx * 5 + level
            rows_p = [r for r in suite1 if int(r["test_id"]) == pid]
            tgt_rows = [r for r in rows_p if int(r["phase"]) == 1]
            lbl, _ = classify_epoch(tgt_rows) if tgt_rows else ("UNKNOWN", 0)
            rate = (1.0 if lbl == tgt else 0.0) if tgt_rows else 0.0
            results[(src, tgt)][level] = (LEVEL_NAMES[level], rate, lbl)

        # Minimal level: first non-source-only level with success
        minimal_lvl = None
        for lvl in range(5):
            if lvl == 3:
                continue  # skip SOURCE_ONLY (forced fail)
            _, rate, _ = results[(src, tgt)][lvl]
            if rate >= SUCCESS_THRESH:
                minimal_lvl = lvl
                break
        sensitivity[(src, tgt)] = minimal_lvl

    return results, sensitivity, LEVEL_NAMES


# ---------------------------------------------------------------------------
# C13C: Basin boundary mapping
# ---------------------------------------------------------------------------
def analyze_c13c(rows):
    """
    Maps (op, E) → dominant attractor.
    """
    BASIN_OP  = ["ADD", "SUB", "MUL"]
    BASIN_E   = [12, 32, 47]
    BASIN_LABEL = [
        ("ADD", 12), ("ADD", 32), ("ADD", 47),
        ("SUB", 12), ("SUB", 32), ("SUB", 47),
        ("MUL", 12), ("MUL", 32), ("MUL", 47),
    ]

    suite2 = [r for r in rows if int(r["suite_id"]) == 2]
    basin_map = {}

    for bid, (op, e) in enumerate(BASIN_LABEL):
        basin_rows = [r for r in suite2 if int(r["test_id"]) == bid]
        lbl, conf = classify_epoch(basin_rows) if basin_rows else ("A1", 0.5)
        basin_map[(op, e)] = (lbl, conf)

    # Classify basin geometry
    # Count how many unique attractors each op class spans
    attractor_by_e = {e: [] for e in BASIN_E}
    for (op, e), (lbl, _) in basin_map.items():
        attractor_by_e[e].append(lbl)

    geometry = {}
    for op in BASIN_OP:
        pts = [(op, e, basin_map[(op, e)][0]) for e in BASIN_E]
        labels_here = [p[2] for p in pts]
        if len(set(labels_here)) == 1:
            geometry[op] = "CONVEX (single attractor)"
        elif labels_here[0] == labels_here[2] and labels_here[0] != labels_here[1]:
            geometry[op] = "DISCONTINUOUS (isolated middle)"
        else:
            geometry[op] = "PIECEWISE FLAT (monotone)"

    return basin_map, geometry, BASIN_LABEL


# ---------------------------------------------------------------------------
# C13D: Steering under noise
# ---------------------------------------------------------------------------
def analyze_c13d(rows):
    """
    Compare steering success under noise vs C13A noiseless results.
    noise_level 0 = NL2 (30% fraction), 1 = NL4 (E±1)
    actual_trans maps to: {0=A1→A2, 1=A1→A3, 2=A2→A1, 3=A3→A1, 4=A4→A1, 5=A4→A2}
    """
    TRANS_C13D = [
        ("A1","A2"), ("A1","A3"), ("A2","A1"),
        ("A3","A1"), ("A4","A1"), ("A4","A2"),
    ]
    NL_NAMES = ["NL2_30pct_frac", "NL4_E±1_jitter"]

    suite3 = [r for r in rows if int(r["suite_id"]) == 3]
    results = {}

    for nl in range(2):
        for atid, (src, tgt) in enumerate(TRANS_C13D):
            nid = nl * 6 + atid
            noise_rows = [r for r in suite3 if int(r["test_id"]) == nid]
            tgt_rows   = [r for r in noise_rows if int(r["phase"]) == 1]
            tgt_labels = epoch_labels(tgt_rows)
            n_tgt = len(tgt_labels)
            rate  = tgt_labels.count(tgt) / max(n_tgt, 1)
            results[(NL_NAMES[nl], src, tgt)] = rate

    return results, TRANS_C13D, NL_NAMES


# ---------------------------------------------------------------------------
# C13E: Controllability classification
# ---------------------------------------------------------------------------
def controllability_verdict(success_matrix):
    """Determine final verdict from 4×4 transition success matrix."""
    non_self = {k: v for k, v in success_matrix.items() if k[0] != k[1]}
    n_total   = 12  # 4×3 = 12 unique transitions
    n_pass    = sum(1 for v in non_self.values() if v >= SUCCESS_THRESH)
    n_partial = sum(1 for v in non_self.values() if 0.40 <= v < SUCCESS_THRESH)

    if n_pass == n_total:
        return "FULLY_CONTROLLABLE", n_pass, n_partial
    elif n_pass >= 10:
        return "CONTROLLABLE", n_pass, n_partial
    elif n_pass >= 6:
        return "PARTIALLY_CONTROLLABLE", n_pass, n_partial
    elif n_pass >= 1:
        return "REGIONALLY_CONTROLLABLE", n_pass, n_partial
    else:
        return "UNCONTROLLABLE", n_pass, n_partial


def build_reachability_graph(success_matrix):
    """Build reachability dict: A → set of B reachable."""
    graph = defaultdict(set)
    for (src, tgt), rate in success_matrix.items():
        if src != tgt and rate >= SUCCESS_THRESH:
            graph[src].add(tgt)
    return dict(graph)


def min_cost_ranking(success_matrix, latency_matrix):
    """Rank transitions by cost = (1 - success_rate) + latency / 10"""
    costs = {}
    for k, rate in success_matrix.items():
        if k[0] == k[1]:
            continue
        lat = latency_matrix.get(k, 10)
        costs[k] = (1.0 - rate) + lat / 10.0
    return sorted(costs.items(), key=lambda x: x[1])


# ---------------------------------------------------------------------------
# Pretty print
# ---------------------------------------------------------------------------
def pp_matrix(matrix, title, fmt_fn):
    print(f"\n{title}")
    print("─" * 56)
    hdr = f"{'':8s}" + "".join(f"{a:>10s}" for a in ATT_NAMES)
    print(hdr)
    for src in ATT_NAMES:
        row_str = f"{src:<8s}"
        for tgt in ATT_NAMES:
            if src == tgt:
                row_str += f"{'─':>10s}"
            else:
                val = matrix.get((src, tgt), 0.0)
                row_str += f"{fmt_fn(val):>10s}"
        print(row_str)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(CSV_PATH):
        print(f"ERROR: {CSV_PATH} not found. Run simulation first.")
        sys.exit(1)

    print("=" * 60)
    print("HBS-C13: Attractor Controllability Analysis")
    print("=" * 60)

    rows = load_csv(CSV_PATH)
    print(f"  Loaded {len(rows):,} rows from {CSV_PATH}")

    # ── C13A ─────────────────────────────────────────────────────────────
    print("\n[C13A] Directed Attractor Steering")
    success_mx, latency_mx, base_verify = analyze_c13a(rows)

    pp_matrix(success_mx, "Success Rate (target attractor ≥70% of next 10 epochs)",
              lambda v: f"{v*100:.1f}%")
    pp_matrix(latency_mx, "Latency (epochs until first target attractor)", lambda v: str(int(v)))

    # Verify baselines
    print("\n  Baseline verification (source attractor hold rate):")
    for (src, tgt), (base_ok, base_lbl) in sorted(base_verify.items()):
        print(f"    {src}→{tgt}: baseline {src} hold = {base_ok*100:.1f}%")

    # ── C13B ─────────────────────────────────────────────────────────────
    print("\n[C13B] Minimal Control Signal Discovery")
    ctrl_results, sensitivity, lvl_names = analyze_c13b(rows)

    print("\n  Perturbation sensitivity per transition:")
    for key, min_lvl in sensitivity.items():
        src, tgt = key
        lvl_str = lvl_names[min_lvl] if min_lvl is not None else "NONE_SUFFICIENT"
        print(f"    {src}→{tgt}: minimal signal = Level {min_lvl} ({lvl_str})")
        for lvl in range(5):
            nm, rate, obs = ctrl_results[key][lvl]
            mark = "✓" if rate >= SUCCESS_THRESH else "✗"
            print(f"      {mark} Lvl{lvl} {nm:30s} → observed={obs} rate={rate:.0%}")

    # ── C13C ─────────────────────────────────────────────────────────────
    print("\n[C13C] Attractor Basin Boundary Mapping")
    basin_map, geometry, basin_labels = analyze_c13c(rows)

    print("\n  Basin map (op, E_in) → dominant attractor:")
    for op in ["ADD", "SUB", "MUL"]:
        print(f"    {op}:", end="")
        for e in [12, 32, 47]:
            lbl, conf = basin_map.get((op, e), ("?", 0))
            print(f"  E={e:2d}→{lbl}({conf:.2f})", end="")
        print()

    print("\n  Basin geometry classification:")
    for op, geom in geometry.items():
        print(f"    {op}: {geom}")

    # ── C13D ─────────────────────────────────────────────────────────────
    print("\n[C13D] Control Stability Under Noise")
    noise_results, trans_c13d, nl_names = analyze_c13d(rows)

    print("\n  Steering success under noise vs noiseless C13A:")
    for src, tgt in trans_c13d:
        c13a_rate = success_mx.get((src, tgt), 0.0)
        print(f"    {src}→{tgt}: noiseless={c13a_rate*100:.1f}%", end="")
        for nl_name in nl_names:
            nr = noise_results.get((nl_name, src, tgt), 0.0)
            deg = (c13a_rate - nr) * 100
            print(f"  |  {nl_name}={nr*100:.1f}% (Δ={-deg:+.1f}%)", end="")
        print()

    # Average noise degradation
    degradations = []
    for (nl_name, src, tgt), nr in noise_results.items():
        c13a_rate = success_mx.get((src, tgt), 0.0)
        degradations.append(c13a_rate - nr)
    avg_deg = sum(degradations) / max(len(degradations), 1)
    print(f"\n  Average steering degradation under noise: {avg_deg*100:.1f}%")

    # ── C13E ─────────────────────────────────────────────────────────────
    print("\n[C13E] Controllability Classification")
    verdict, n_pass, n_partial = controllability_verdict(success_mx)
    print(f"  Transitions passing (≥70%): {n_pass}/12")
    print(f"  Transitions partial (40-70%): {n_partial}/12")
    print(f"  Final verdict: {verdict}")

    graph = build_reachability_graph(success_mx)
    print("\n  Reachability graph (→ = achievable):")
    for src in ATT_NAMES:
        targets = sorted(graph.get(src, set()))
        print(f"    {src} → {', '.join(targets) if targets else '(none)'}")

    cost_rank = min_cost_ranking(success_mx, latency_mx)
    print("\n  Control cost ranking (lowest cost = easiest to steer):")
    for i, ((src, tgt), cost) in enumerate(cost_rank[:8], 1):
        rate = success_mx.get((src, tgt), 0)
        lat  = latency_mx.get((src, tgt), 10)
        print(f"    {i:2d}. {src}→{tgt}  rate={rate*100:.1f}%  lat={lat:d}ep  cost={cost:.3f}")

    # Controllability matrix (4×4 rates)
    pp_matrix(success_mx, "Full 4×4 Controllability Matrix",
              lambda v: f"{v*100:.0f}%")

    # ── Write log ─────────────────────────────────────────────────────────
    with open(LOG_PATH, "w") as f:
        f.write(f"HBS_C13_VERDICT={verdict}\n")
        f.write(f"TRANSITIONS_PASS={n_pass}\n")
        f.write(f"TRANSITIONS_PARTIAL={n_partial}\n")
        f.write(f"AVG_NOISE_DEGRADATION={avg_deg*100:.2f}\n")

        f.write("\nTRANSITION_SUCCESS_MATRIX\n")
        for (src, tgt), rate in sorted(success_mx.items()):
            if src != tgt:
                lat = latency_mx.get((src, tgt), -1)
                f.write(f"  {src}->{tgt}: rate={rate:.3f} latency={lat}ep\n")

        f.write("\nMINIMAL_CONTROL_SIGNALS\n")
        for (src, tgt), min_lvl in sorted(sensitivity.items()):
            if min_lvl is not None:
                f.write(f"  {src}->{tgt}: level={min_lvl} ({lvl_names[min_lvl]})\n")
            else:
                f.write(f"  {src}->{tgt}: INSUFFICIENT\n")

        f.write("\nBASIN_MAP\n")
        for (op, e), (lbl, conf) in sorted(basin_map.items()):
            f.write(f"  ({op}, E={e:2d}): attractor={lbl} conf={conf:.2f}\n")

        f.write("\nBASIN_GEOMETRY\n")
        for op, geom in geometry.items():
            f.write(f"  {op}: {geom}\n")

        f.write("\nREACHABILITY_GRAPH\n")
        for src in ATT_NAMES:
            targets = sorted(graph.get(src, set()))
            f.write(f"  {src}: {', '.join(targets) if targets else 'NONE'}\n")

        f.write("\nCONTROL_COST_RANKING\n")
        for i, ((src, tgt), cost) in enumerate(cost_rank, 1):
            f.write(f"  {i:2d}. {src}->{tgt}: cost={cost:.3f}\n")

    print(f"\n  Log written to {LOG_PATH}")
    print(f"\n{'='*60}")
    print(f"HBS-C13 FINAL VERDICT: {verdict}")
    print(f"{'='*60}")

    return verdict


if __name__ == "__main__":
    main()
