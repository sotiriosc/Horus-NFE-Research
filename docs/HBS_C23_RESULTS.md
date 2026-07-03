# HBS-C23: Observer-Decoupling Falsification Suite
## Do HORUS v3 Attractors Survive When the Coordinate System Is Destroyed?

**Date:** 2026-07-02  
**Engineer:** Principal Architect / Verification Engineer  
**Predecessor:** HBS-C22 (Exogenous injection — MI confirms arithmetic causal closure)  
**Task type:** Ontological falsification — testing whether attractors are intrinsic or observer-defined

---

## 1. The Deep Question

Every experiment from C18 to C22 asked: *"Does the system behave consistently under different workloads and injections?"*

C23 asks something fundamentally different:

> **"Does the attractor system survive when the coordinate system itself is destroyed?"**

A genuine dynamical invariant (like temperature in a gas, or attractor basin in a nonlinear ODEs system) is **coordinate-independent**: it exists regardless of how you measure it.  The HORUS v3 attractor classification (A1–A4) is defined by a specific extraction rule:

```
E_obs = result[11:6]    →    classify by threshold
```

If A1–A4 are **intrinsic** properties of the computation, they should survive when we use a different extraction formula on the same output.  If they are **observer artifacts**, they will change or disappear when the coordinate system is altered.

---

## 2. Four Observer Transforms (Applied Simultaneously)

All transforms operated on the same running DUT over 6,000 cycles.  The DUT was never modified.

| Transform | E-field extraction | Description |
|-----------|-------------------|-------------|
| **STD** | `result[11:6]` | Ground truth — standard E-field |
| **R1** | `result[9:4] ^ result[12:7]` | Two overlapping 6-bit windows XOR'd — mixes E, f, and sign bits |
| **R2** | `popcount(result ^ accum_reg[12:0])` | Hamming distance between NFE output and accumulator — nonlinear domain |
| **R3** | `result(t-1)[11:6]` | 1-cycle lag — tests temporal locality of attractor identity |
| **R4** | `rotl13(result, k) ^ epoch_mask` | Epoch-varying 13-bit rotation + XOR mask — changes every 16 cycles |

---

## 3. Measured Results

### 3.1 Summary Table

| Transform | Disagree% | Max Δdist | MI (bits) | P(A3\|A3) | P(A2\|A1) |
|-----------|-----------|-----------|-----------|----------|----------|
| R1 Desync | **35.4%** | 0.003 | 0.015 | **0.000** | 0.000 |
| R2 PopCount | **22.1%** | **0.212** | 0.101 | **0.000** | 0.000 |
| R3 Lag-1 | **5.95%** | 0.0002 | **0.731** | **0.123** | 0.000 |
| R4 Rotation | **37.7%** | 0.010 | **0.002** | **0.000** | **0.218** |

Threshold: disagree < 5%, dist shift < 10 pp, MI > 0.05 bits, P(A3\|A3) ≥ 0.5, P(A2\|A1) ≤ 0.10

### 3.2 Conditional Survival  P(attr_T = x | attr_STD = x)

| Attractor | STD | R1 Desync | R2 Pop | R3 Lag | R4 Rot |
|-----------|-----|-----------|--------|--------|--------|
| **A1** | 100% | 9% | 100% | 1% | 4% |
| **A2** | 100% | 24% | 0.2% | 92% | 21% |
| **A3** | 100% | **0%** | **0%** | **12%** | **0%** |
| **A4** | 100% | 78% | 100% | 98% | 76% |

### 3.3 Transition Entropy (bits per step)

| Observer | Transition entropy |
|----------|-------------------|
| STD (ground truth) | 0.208 bits |
| R1 Desync | **0.728 bits** (3.5× increase) |
| R2 PopCount | 0.139 bits (decrease) |
| R3 Lag-1 | 0.209 bits (preserved) |
| R4 Rotation | **0.926 bits** (4.5× increase) |

---

## 4. Per-Transform Analysis

### R1 — E-field Desynchronization (35.4% disagree, MI = 0.015 bits)

`E_alt = result[9:4] ^ result[12:7]` mixes:
- `result[9:4]` = `{E[3:0], f[5:4]}` — lower 4 bits of exponent + upper 2 bits of mantissa
- `result[12:7]` = `{sign, E[5:1]}` — sign bit + upper 5 exponent bits

The XOR of these two 6-bit windows creates a scrambled signal that lands almost uniformly in the A4 range regardless of the original attractor.  MI = 0.015 bits — the R1 observer shares essentially no information with the standard observer about which attractor is present.

**A3 completely disappears** (P(A3\|A3) = 0.0): when E=63 (A3), E_alt evaluates to a mid-range value (always in A4).

Transition entropy triples: R1 sees far more "transitions" because consecutive cycles that were both A4 in the standard frame now appear to cycle through many values.

### R2 — Nonlinear Re-Embedding (22.1% disagree, MI = 0.101 bits)

`popcount(result[12:0] ^ accum_reg[12:0])` computes Hamming distance between the NFE word and the running accumulator state.

The popcount distribution over 13 bits is approximately binomial with mean ~6.5 when result and accum_reg are independent.  This creates:

| Attractor proxy | Condition | Frequency |
|-----------------|-----------|-----------|
| A1_pop | pop = 0 | ~0.01% (result = accum bit-for-bit) |
| A2_pop | pop ≥ 12 | ~0.03% (near-maximum Hamming) |
| A3_pop | pop = 13 | ~0.03% (all bits differ) |
| A4_pop | 1 ≤ pop ≤ 11 | **~99.9%** (mid-range Hamming) |

The standard A2 attractor (20% of cycles) collapses almost entirely into A4_pop.  The standard A3 attractor (1.77% of cycles) also collapses into A4_pop.

**Key finding**: A1 is PRESERVED (100% survival) because the popcount classifier and the E-field classifier both assign label A1 to the minimum-energy state — though for completely different reasons.  A1_std (E=0) and A1_pop (popcount=0) both identify "identical zero-energy" conditions, just in different spaces.  This is a coincidental semantic alignment, not coordinate invariance.

Distribution shift: **max 21.2 pp** (far above the 10 pp threshold).

### R3 — Lagged Observation (5.95% disagree, MI = 0.731 bits)

The 1-cycle lag reveals the **temporal topology of the attractor cycle**:

```
E-field sweep:  ... 62 → 63 → 0 → 1 → 2 ...
Standard view:  ... A2 → A3 → A1 → A4 → A4 ...
Lagged view:    ... A4 → A2 → A3 → A1 → A4 ...
```

The E-field sweep is a continuous sequence 0→63 cycling.  A3 (E=63) appears when the sweep reaches 63, and the previous cycle had E=62 (A2).  So the lagged observer sees A2 just before A3 transitions to A1.

**A3 lagged reality (n=106 cycles where STD = A3):**
- 87.7% → lagged observer sees A2 (E=62 at t-1)
- 12.3% → lagged observer sees A3 (E=63 repeated at t-1)

The 12.3% A3 self-survival occurs when the E-field sweep produces two consecutive E=63 cycles (which happens during LFSR f-field variation that doesn't change E).

**A1 almost fully disappears** (1.3% survival): when STD=A1 (E=0), the previous cycle had E=63 → lagged observer sees A3.

Despite these boundary-attractor failures, the overall MI = 0.731 bits is high — the lag mostly preserves A2 and A4 identity.  This reveals that the 5.95% disagreement is concentrated entirely at the A3/A1 boundary in the E-field sweep cycle — a topological adjacency artifact.

### R4 — Epoch-Varying Rotation (37.7% disagree, MI = 0.002 bits)

`x' = rotl13(result, k) ^ epoch_mask`, with k cycling through all 13 rotation amounts (step +3 mod 13) and epoch_mask driven by an independent LFSR updated every 16 cycles.

**MI = 0.002 bits** — the closest to zero of any transform.  The rotated observer is informationally independent of the standard observer.  A1/A2 swap rate = **21.8%** — far exceeds the 10% threshold.

Per-rotation-amount disagreement:

| rot_k | Disagree% |
|-------|-----------|
| 0 | 38.9% |
| 6 | 34.3% (minimum) |
| 9 | 43.1% (maximum) |

Even rot_k=0 (identity rotation) shows ~39% disagreement because the epoch_mask XOR term is applied even at rot_k=0 for most epochs (only the first epoch has mask=0).  The combination of rotation and XOR mask completely randomizes which bits appear in positions [11:6] relative to the original E-field.

A3 survival = 0% across all rotation amounts: the specific bit pattern of E=63 (6'b111111 at bits [11:6]) is never preserved when those bit positions are scrambled.

---

## 5. Pass/Fail Verdict

### FAIL CONDITIONS TRIGGERED — MODEL BREAKS

| Condition | Observed | Threshold | Status |
|-----------|----------|-----------|--------|
| R1 disagree < 5% | **35.4%** | < 5% | ✗ |
| R2 disagree < 5% | **22.1%** | < 5% | ✗ |
| R3 disagree < 5% | **5.95%** | < 5% | ✗ |
| R4 disagree < 5% | **37.7%** | < 5% | ✗ |
| R2 dist shift < 10 pp | **21.2 pp** | < 10 pp | ✗ |
| R3: P(A3\|A3) ≥ 0.5 | **0.123** | ≥ 0.5 | ✗ |
| R4: P(A2\|A1) ≤ 0.10 | **0.218** | ≤ 0.10 | ✗ |

**VERDICT: MODEL BREAKS**

The attractor system does NOT survive coordinate system destruction.

---

## 6. What This Means

### What Is Destroyed

The claim that A1–A4 are **intrinsic dynamical invariants** of HORUS v3.

With the standard E-field observer:
- A1 = "cancellation residual absorption basin"
- A2 = "geometric exponent explosion approach"
- A3 = "Thoth rollover boundary oscillation"
- A4 = "entropic regime mid-range"

These ARE REAL as descriptions of specific computational behaviors.  But they are real because the E-field `result[11:6]` is a meaningful physical quantity in the NFE encoding.  Change the quantity you extract and the attractor taxonomy collapses.

### What Is Preserved

**The computation itself is untouched.**  `computed = f(op_a, op_b, op_sel)` is the same in all four transforms.  The arithmetic is invariant.  The causal closure theorem (C18–C22) still holds.  What changes is the LABEL applied to that computation.

### The Correct Characterization After C23

| Property | Status | Evidence |
|----------|--------|----------|
| Arithmetic computation | **Frame-independent invariant** | C18–C22 |
| Causal closure (mode_tag can't change computed) | **Proved** | C22 MI_arith = 0 |
| A1–A4 attractor labels | **Frame-dependent observer artifacts** | C23 |
| Attractor structure under standard E-field | **Stable and reproducible** | C19, C23-STD |
| Attractor structure under arbitrary transforms | **Not invariant** | C23 R1–R4 |

### The MI Sensitivity Spectrum

The four transforms reveal a spectrum of "how much attractor information they preserve":

```
MI preserved:  R3(lag) = 0.731 >> R2(pop) = 0.101 >> R1(desync) = 0.015 >> R4(rot) = 0.002
```

- **R3 (lag, 0.73 bits)**: Preserves most structure; fails only at boundary attractors A3/A1 due to E-field sweep topology
- **R2 (popcount, 0.10 bits)**: Weak alignment — only A1 semantic analog survives (minimum energy ↔ zero Hamming)
- **R1 (desync, 0.015 bits)**: Bit-scrambling nearly destroys all correlation
- **R4 (rotation, 0.002 bits)**: Random rotation completely decorrelates — attractors become noise

This spectrum quantifies the "brittleness" of the attractor taxonomy: it requires a specific, physically motivated extraction rule to be stable.

---

## 7. Cross-Experiment Series Summary (C18–C23)

| HBS | Question tested | Answer |
|-----|----------------|--------|
| C18 | Is HORUS formally closed? | YES — formal structural proof |
| C19 | Does closure survive adversarial stress? | YES — STRONGLY_CLOSED |
| C20 | Where is the causal firewall? | Exactly at B0\|B1, zero-thickness |
| C21 | Does accum feedback open closure? | NO — Arithmetic Echo Effect |
| C22 | Does exogenous injection open closure? | NO — MI_arith = 0 |
| **C23** | **Are attractors coordinate-invariant?** | **NO — observer-frame artifacts** |

The C18–C22 proof sequence establishes: *the ARITHMETIC is a closed, frame-independent, causally isolated process.*

C23 establishes: *the ATTRACTOR TAXONOMY is a frame-dependent labeling of that arithmetic, meaningful and reproducible in the standard coordinate system, but not a coordinate-invariant property of the underlying dynamical system.*

---

## 8. Output Files

| File | Description |
|------|-------------|
| `sim/HBS_C23_OBSERVER_TRACE.csv` | 6,000-cycle trace with all 4 transforms |
| `sim/HBS_C23_REGIME_RESULTS.csv` | Summary metrics per transform |
| `sim/HBS_C23_SUMMARY.log` | Full analysis log |
| `sim/HBS_C23_ANALYSIS.py` | Analysis script (MI, survival, disagreement, entropy) |
| `tb/tb_hbs_c23_observer_decoupling.v` | Testbench (all 4 simultaneous transforms) |
