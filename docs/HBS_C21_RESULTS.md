# HBS-C21: Controlled Feedback Coupling Experiment
## Option A — Accumulator Right-Shift Injection

**Date:** 2026-07-02  
**Engineer:** Principal Architect / Verification Engineer  
**Predecessor:** HBS-C20 (Closure Firewall Localization — STRONGLY_CLOSED, step-function boundary)  
**Task type:** Emergence measurement — not a falsification test

---

## 1. Objective

Introduce ONE controlled side-channel coupling from the state subsystem into the arithmetic observation path and measure whether:

- Attractors become computationally visible in the modulated output
- Closure breaks gradually or catastrophically
- The system self-stabilizes into a new invariant

**Scientific question:**  What is the boundary between a *digital arithmetic system* (dynamics → accumulation only) and a *computational dynamical system* (dynamics modulate the function itself)?

---

## 2. Architectural Invariant (enforced)

The following are untouched in this experiment:

| Component | Status |
|-----------|--------|
| `horus_nfe.v` RTL | **UNCHANGED** |
| `horus_system.v` RTL | **UNCHANGED** |
| `computed = f(op_a, op_b, op_sel)` | **UNCHANGED** |
| All attractor dynamics | **UNCHANGED** |

The modulation term is **computed entirely in the testbench observer layer** — it is a hypothetical output path, not a real feedback loop.

---

## 3. Coupling Formula (Option A)

```
coupling_term = (accum_reg >> k) & 0x1FFF       [13-bit truncation]
computed_mod  = computed + coupling_term          [13-bit wrap-around]
```

Three coupling strengths tested:

| Regime | Shift k | Attenuation | Layer affected |
|--------|---------|-------------|----------------|
| R1 | 12 | ~÷4096 | Mantissa only (bits 5:0) |
| R2 | 10 | ~÷1024 | Low E-field bits (bits 7:6) |
| R3 | 8  | ~÷256  | Full E-field range (bits 11:6) |

**Input pattern** (identical across all regimes for fair comparison):
- `op_a`: E-field sweeps 0→63 cyclically, f-field from LFSR
- `op_b`: fixed `{0, E=0, f=16}`
- `op_sel`: ADD
- `mode_tag`: Standard (000)
- `accum_en=1`, `depth=63`, periodic clear every 64 cycles

---

## 4. New Metrics Introduced

### AII — Attractor Imprint Index
Measures how much of `computed_mod` variance is explained by the BASE attractor classification of `computed`.

```
AII_base  = η²(computed, attr_base)        [intrinsic self-correlation]
AII_mod   = η²(computed_mod, attr_base)    [with coupling]
AII_delta = AII_mod − AII_base             [COUPLING-INDUCED imprint]
```

`AII_base` is naturally high (≈0.54) because E-field classification IS derived from the computed value.  `AII_delta` is the relevant metric: it measures whether the coupling adds NEW attractor structure.

### CPR — Causal Penetration Ratio
```
CPR = Var(coupling_term) / Var(computed_mod)
```
Fraction of total `computed_mod` variance attributable to the injected coupling term.

### PIG — Phase Injection Gain
At attractor transition cycles (where base attractor classification changes):
```
PIG = mean(|Δcomputed_mod|) / mean(|Δcomputed|)  at transition cycles
```
PIG > 1 means transitions are amplified by the coupling.

### SLF — Stability Loss Function
```
SLF = E[(computed_mod − computed)²] / Var(computed)  [in dB]
```
Measures energy of the coupling-induced deviation relative to signal energy.

---

## 5. Results

### 5.1 Critical Preliminary Finding

| Metric | Value |
|--------|-------|
| `r(coupling_term, computed)` | **0.969** |

The coupling term `(accum_reg >> k)` is almost perfectly correlated with `computed` (r ≈ 0.97 across all regimes).

**Why?** Because `accum_reg` is the time-integral of `accum_word`, which is a function of `computed` and accumulation policy. With standard mode and periodic resets every 64 cycles, `accum_reg(t) ≈ Σ computed(τ)` for the last 64 cycles — a running sum of the arithmetic outputs.  Feeding it back via `computed_mod = computed + accum_reg >> k` is therefore **adding a time-averaged echo of the arithmetic history back to itself**, not injecting genuine new state information.

This single finding reframes the entire experiment: the "feedback" is a self-reinforcing circular reference in the observer layer, not a cross-domain coupling.

---

### 5.2 Per-Regime Measurements

| Regime | k | AII_base | AII_delta | CPR | SLF (dB) | PIG |
|--------|---|----------|-----------|-----|----------|-----|
| R1 | 12 | 0.5362 | **0.0014** | 0.000066 | −38.4 dB | 1.008 |
| R2 | 10 | 0.5362 | **0.0054** | 0.001013 | −26.2 dB | 1.032 |
| R3 | 8  | 0.5362 | **0.0197** | 0.013598 | −14.1 dB | 1.129 |

**AII_base = 0.5362** in all regimes — this is the intrinsic self-correlation of `computed` with its own attractor classification.  It is independent of the coupling and serves as the baseline.

---

### 5.3 Regime Classifications

| Regime | k | Classification | Rationale |
|--------|---|----------------|-----------|
| R1 | 12 | **REGIME_1_NO_PENETRATION** | AII_delta=0.0014 < 0.01, CPR=0.007% < 1% |
| R2 | 10 | **REGIME_1_NO_PENETRATION** | AII_delta=0.0054 < 0.01, CPR=0.101% < 1% |
| R3 | 8  | **REGIME_2_LINEAR_BLEED**   | AII_delta=0.0197 ≥ 0.01, CPR=1.36% (measurable) |

---

### 5.4 Attractor Distribution Shift (Regime 3)

Even in the strongest coupling (k=8), the attractor distribution shifts are small:

| Attractor | Base computed | computed_mod | Shift |
|-----------|--------------|--------------|-------|
| A1 (cancel) | 1.0% | 2.5% | +1.5 pp |
| A2 (explode) | 20.2% | 16.9% | **−3.3 pp** |
| A3 (rollover) | 1.8% | 0.8% | −1.0 pp |
| A4 (entropic) | 77.0% | 79.8% | +2.8 pp |

The coupling term, being a positive bias (accum_reg >> k ≥ 0), systematically shifts `computed_mod` downward relative to `computed` on a wrapped 13-bit number line, moving E-field values out of the A2/A3 range into the A4 range.

**E-field mean shift (Regime 3):** −4.15 units (out of 64 possible) = 6.5% downward bias.

---

### 5.5 Phase Injection Gain at Transitions

| Regime | PIG | Interpretation |
|--------|-----|----------------|
| R1 k=12 | 1.008 | +0.8% amplification — negligible |
| R2 k=10 | 1.032 | +3.2% amplification — weak |
| R3 k=8  | 1.129 | +12.9% amplification — measurable |

At attractor boundary crossings, `computed_mod` shows larger jumps than `computed` in all regimes.  This is expected: at boundaries (where `computed` is near an E-field threshold), a positive bias `coupling_term` pushes `computed_mod` further across the boundary, amplifying the transition magnitude.

The maximum PIG = 1.129 in Regime 3 means transitions are 12.9% larger in the modulated output.  This is the first measurable sign of the coupling affecting the attractor geometry — though still bounded and proportional (not a runaway amplification).

---

### 5.6 CPR Scaling with k

```
k=12: CPR = 0.000066  (0.007% of variance)
k=10: CPR = 0.001013  (0.101% of variance)
k= 8: CPR = 0.013598  (1.360% of variance)
```

CPR increases by roughly ×15 for each 2-step reduction in k (×4 expected from bit-shift).  The super-linear scaling is because at k=8, the coupling term starts affecting E-field bits and creates larger absolute deviations.

Maximum CPR = **1.36%** — firmly in the "boundary zone" but below the 10% threshold for "computational dynamics."

---

## 6. Scientific Interpretation

### 6.1 Why the Coupling is Self-Reinforcing, Not Cross-Domain

The fundamental reason `r(coupling, computed) = 0.97` is that the feedback path carries arithmetic history, not state policy:

```
State policy path (C19 confirmed closed):
  mode_tag   ──→  accum_word policy  ──→  accum_reg           [→ NO path to computed]
  accum_clr  ──→  accum_reg reset                             [→ NO path to computed]

Arithmetic echo path (C21 discovered):
  computed  ──→  accum_word  ──→  accum_reg  ──→  coupling_term
                 ↑                                            ↓
                 └──────────────────────────────── ─ ─ ─ ─ ─ (observer feedback)
                                                              ↓
                                              computed_mod = computed + coupling_term
```

The coupling_term is derived from the arithmetic signal's own past values, not from the genuine state variables (`mode_tag`, `accum_clr`). This is why:
- AII_delta ≈ 0 (the "state" being fed back is just arithmetic history — same attractor structure)
- CPR < 1.4% (almost all of `computed_mod` variance = `computed` variance)
- The feedback creates a mild self-correlation but not new dynamics

### 6.2 What Would True Cross-Domain Coupling Look Like?

For this experiment to exhibit genuine state-to-arithmetic coupling, the coupling term would need to carry **policy-dependent information** — something that reflects `mode_tag` choices or `accum_clr` schedules rather than arithmetic outputs.

A true cross-domain coupling would show:
- `r(coupling, computed) < 0.3`  (coupling term uncorrelated with arithmetic output)
- `AII_delta > 0.1`  (state attractor structure appears in output)
- `CPR > 0.10`  (state variables contribute > 10% of output variance)

None of these thresholds are reached by Option A.

### 6.3 The System Self-Stabilized

Rather than "breaking closure" or "creating a new invariant," the system demonstrated a third outcome not explicitly listed in the expected outcomes:

**The coupling is absorbed into the arithmetic signal's self-correlation.**

Because `accum_reg` integrates `computed` values, the feedback creates a mild positive bias on `computed_mod` — but that bias is **already explained by the existing arithmetic structure** (it's just a scaled version of the signal itself). The result is not a new regime but a slightly magnified version of the existing one.

---

## 7. Boundary Classification

| Boundary | HORUS v3 status |
|----------|----------------|
| Digital arithmetic (closed) | ✓ Arithmetic core unmodified |
| State-to-arithmetic coupling | ✗ Not achieved via Option A |
| Self-referencing echo | **Observed** — accum_reg carries arithmetic history |
| Computational dynamical system | Not reached — CPR_max = 1.4% |

**HORUS v3 with Option A coupling sits firmly in the digital arithmetic regime.**  The observer-layer feedback creates a mild self-reinforcing echo effect, but not a genuine cross-domain modulation.

---

## 8. Implications for Future Experiments

Option A with accum_reg right-shift cannot achieve genuine state-to-arithmetic coupling because **accum_reg is derived from computed**, making the coupling circular within the arithmetic domain.

To achieve true cross-domain coupling, a future experiment (HBS-C22) could:
- **Option B**: `computed_mod = computed ^ mode_tag_mask` — directly injects policy bits, bypassing the arithmetic echo
- **Option C**: Boundary-gated injection at attractor transitions — activates coupling only when E-field is near threshold, using pure mode_tag (not accum_reg) as the injection term
- **Option D**: Use `accum_reg` from a PARALLEL, DIFFERENT input stream — so the accumulated state is not correlated with the current computed value

---

## 9. Final Verdict

```
HORUS v3 HBS-C21 VERDICT: NO_PENETRATION (k=12, k=10)  /  LINEAR_BLEED (k=8)
```

**The arithmetic core remains structurally dominant.**  Even with an explicit mathematical coupling formula applied at the observer layer, the coupling term (r=0.97 with computed) is so highly correlated with the arithmetic signal that it cannot introduce new attractor structure.

> "A closed system fed its own history does not open — it deepens its existing structure."

The causal partition identified in HBS-C18 through HBS-C20 holds. The arithmetic subspace cannot be modulated by a signal derived from itself.

---

## 10. Output Files

| File | Description |
|------|-------------|
| `sim/HBS_C21_FEEDBACK_TRACE.csv` | 6,000-cycle per-cycle trace (computed, accum_reg, coupling_term, computed_mod, attractors, deltas) |
| `sim/HBS_C21_REGIME_RESULTS.csv` | Per-regime summary (AII_base, AII_delta, CPR, PIG, SLF, classification) |
| `sim/HBS_C21_SUMMARY.log` | Full analysis log |
| `sim/HBS_C21_ANALYSIS.py` | Analysis script (AII, CPR, PIG, SLF + regime classification) |
| `tb/tb_hbs_c21_feedback_probe.v` | Simulation testbench (Option A coupling, k=12/10/8) |
