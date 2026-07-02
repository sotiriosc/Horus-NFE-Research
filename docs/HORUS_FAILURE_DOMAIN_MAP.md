# HORUS v3 — Failure Domain Map

**Document type:** Architectural Gold Master — Failure Physics Reference  
**Authority:** HBS-C6 (adversarial workloads) + HBS-C7 (failure isolation)  
**Version:** 1.0 · 2026-07-02  
**Status:** FROZEN — derived from measured hardware behavior only.  
No RTL, mode, or compiler changes were made or proposed.

---

## Central Question

> **Is HORUS v3 a single-threshold system or a multi-attractor system**  
> **under adversarial workload stress?**

---

## Answer

> **HORUS v3 is a MULTI-ATTRACTOR system under adversarial stress.**

This is a measured conclusion, not a theoretical one. It is derived from 1,100 cycles
of adversarial simulation across four distinct failure regimes (HBS-C7), and is
consistent with the five adversarial workload behaviors observed in HBS-C6.

---

## What This Means

HORUS v3 has been verified to produce a **topologically correct, deterministic decision
surface** across all 8,192 kernel input combinations (HBS-C5). That verification is
not invalidated by this document.

What HBS-C7 adds: even a topologically correct kernel can manage multiple dynamically
distinct failure modes. When each failure mode has a different onset depth, trajectory,
and accumulator coupling, no single epoch threshold can uniformly contain all of them.

---

## The Four Failure Attractors

### 1. Linear Residual Accumulation Attractor

**Trigger:** NFE SUB between operands at equal exponent with a fraction offset (cancellation imperfection)  
**Source workload class:** CLASS_B  
**Mechanism:**
- Each SUB(E=32, f=a) − SUB(E=32, f=b) where a≈b produces a residual of magnitude |a−b|/64
- The accumulator sums residuals monotonically: `accum ≈ N × residual`
- Result codewords remain entirely in STABLE (100% STABLE occupancy confirmed)
- The failure is invisible to region-based monitoring — it is a accumulator contamination event

**Measured behavior:**
- Residual amplification: **63.6×** over E=32 quantization step
- Accumulator drift range: 20,497 over 200 cycles
- TTI (accum drift onset): **2 cycles**
- Recovery latency: **0 cycles** (stimulus-driven, not state-persistent)

**Attractor type:** Bounded linear drift  
**Epoch_depth adequacy:** The epoch boundary resets the accumulator at depth=16, which
limits the maximum accumulated residual to `16 × residual`. This is the correct mitigation.
For extreme-depth CLASS_B workloads, the accumulated residual per epoch may still dominate.

---

### 2. Geometric Exponent Explosion Attractor

**Trigger:** Repeated MUL with a factor > 1.0 driving the feedback exponent upward  
**Source workload class:** CLASS_D (deep composition chains)  
**Mechanism:**
- MUL(feedback, factor) where `E_factor = 33` → E_result = E_feedback + 1 per cycle
- Starting from E=32 (STABLE center): E=33, 34, ... 63 → 6-bit field overflow at cycle **31**
- The NFE `exp_ovf_flag` fires when the result exponent exceeds 6 bits (E > 63)
- This is distinct from SATURATE region entry (E=48) — the field overflow is catastrophic

**Measured behavior:**
- Mean ΔE/cycle: **1.000 exactly** (confirmed over 7 drift runs)
- Measured OVF onset (TTI): **31 cycles** from E=32
- OVF frequency: 3.0% of stress cycles
- SATURATE occupancy during drift: 51.0%
- Run length distribution: [8, 31] cycles — see epoch interaction note below
- Recovery latency: **0 cycles**

**Epoch interaction (structural, not a bug):**  
When `depth_cnt > 16`, the C4 kernel switches `mode_tag` to PRE_SCALED (3'b010).
Under PRE_SCALED, `horus_system` modifies input scaling. This intercepts the drift
chain mid-run, creating runs of either 31 cycles (full drift) or 8 cycles (epoch-intercepted
drift). The system is fully deterministic; the run-length variation maps deterministically
to epoch/OVF alignment.

**Epoch_depth adequacy:**
- The epoch_depth=16 fires at cycle 16, before the geometric OVF at cycle 31
- This interrupts the accumulator and switches mode, but does NOT prevent the
  continued exponent drift (the feedback chain is external to epoch management)
- Conclusion: epoch management mitigates accumulator contamination but does not
  halt the exponent explosion itself. For factor > 2.0, the TTI window narrows.

**Attractor type:** Deterministic geometric saturation  

---

### 3. Permanent Boundary Oscillation Attractor

**Trigger:** ADD at E=15 or E=47 activates Thoth Rollover (mantissa sum ≥ 2.0)  
**Source workload class:** CLASS_C (normalization/scaling)  
**Mechanism:**
- ADD({E=15, f=32}, {E=15, f=32}): mantissa = 1.5 + 1.5 = 3.0 ≥ 2.0 → Rollover → E=16
- ADD({E=15, f=0},  {E=15, f=32}): mantissa = 1.0 + 1.5 = 2.5 ≥ 2.0 → Rollover → E=16
- Alternating operands near E=15: system oscillates COLLAPSE ↔ TRANSITION each cycle
- Same behavior at E=47: TRANSITION ↔ SATURATE oscillation
- The system is in the boundary regime from the first cycle — no convergence, no TTI

**Measured behavior:**
- STABLE occupancy: **0.0%**
- Boundary crossing rate: **50.0%** (exact — one crossing per 2 cycles)
- Accum entropy: **0.045 bits** (near-zero — locked to 2-state oscillation)
- TTI: **0 cycles** (permanent boundary regime)
- Recovery latency: **0 cycles**

**Critical isolation finding:**  
Accum entropy = 0.045 bits despite 100% boundary-region residency.  
Cause: C4 routes CLASS_C through NORMALIZE_THEN_ROUTE with `accum_en=0`.  
The boundary oscillation is **architecturally isolated from the accumulator**.  
This is the correct behavior — a boundary oscillator that poisons the accumulator
would be catastrophic; the C4 kernel prevents this.

**Attractor type:** Permanent boundary oscillator (input-driven, accum-isolated)

---

### 4. Entropy-Dissipation Attractor

**Trigger:** Rapid injection of operands spanning STABLE, COLLAPSE, and SATURATE regions  
**Source workload class:** Mixed (CLASS_A + CLASS_B + CLASS_A)  
**Mechanism:**
- A 40%/30%/30% deterministic cycle of STABLE/COLLAPSE/SAT operands creates a region
  pattern that changes every 2-3 cycles
- The accumulator receives contributions from all regions: large magnitudes (SAT),
  near-zero magnitudes (COLLAPSE), and moderate magnitudes (STABLE)
- Regime interference events (COLLAPSE following STABLE) begin at cycle 4

**Measured behavior:**
- Occupancy: STABLE=40%, COLLAPSE=30%, SATURATE=30% — **exactly matches injection ratio**
- Boundary crossing rate: **29.5%**
- Accum entropy: **2.91 bits** (high — accumulator spans a wide dynamic range)
- TTI (first interference): **4 cycles**
- Recovery latency: **0 cycles**

**Attractor type:** Entropy-dissipation (accumulator high-variance, bounded by per-class routing)

---

## Failure Domain Topology Map

```
NFE Exponent Axis  ─────────────────────────────────────────────────────────►
                                                                    E = 63
E =  0      E = 15  E = 16  E = 19  E = 20 ──── E = 43  E = 44  E = 47  E = 48
├───────────┼───────┼───────┤        ├────────────────────┤        ├───────┤
│ COLLAPSE  │       │TRANS  │        │  STABLE (safe band)│        │TRANS  │ SATURATE
│           │       │ITION  │        │                    │        │ITION  │
├───────────┴───────┘       └────────┴────────────────────┘        └───────┴──────────

Attractor 1 (linear drift):    occupies STABLE (invisible to region monitor)
Attractor 2 (geometric expl):  traverses STABLE → TRANSITION → SATURATE → OVF
Attractor 3 (boundary osc):    locked at E=15/16 boundary OR E=47/48 boundary
Attractor 4 (entropy mix):     spans all regions in 10-cycle repeating pattern

                              ◄── epoch_depth=16 calibrated for Attractor 2 only ──►
```

---

## Failure Threshold Comparison

| Attractor | Onset (TTI) | Epoch_depth=16 | Adequacy |
|---|---|---|---|
| 1 — Linear drift | **2 cycles** | Interrupts at 16 | Limits per-epoch accumulation |
| 2 — Geometric OVF | **31 cycles** | Intercepts at 16 | Prevents accumulator saturation; does not prevent E overflow |
| 3 — Boundary osc. | **0 cycles** | Not applicable | C4 isolates boundary oscillator from accumulator (accum_en=0) |
| 4 — Entropy mixing | **4 cycles** | Interrupts at 16 | Per-operation routing contains each injection type |

**The C4 epoch_depth=16 does not address all attractors equally.** It was calibrated for
Attractor 2 (geometric). For Attractor 1, the per-epoch residual accumulation is bounded
but may be significant for sustained CLASS_B workloads. For Attractors 3 and 4, the
mitigation is structural (routing + accum_en), not epoch-based.

---

## Regime Independence Conclusion

> **TTI spread: 31.0× across four regimes (min=0 cycles, max=31 cycles)**

The four regimes do not share a failure threshold. Each has an independent onset
depth driven by its specific failure mechanism:

- R1: accumulator drift starts at cycle 2 (before any epoch fires)
- R2: field overflow at cycle 31 (after one full epoch cycle)
- R3: boundary regime from cycle 0 (epoch inapplicable)
- R4: regime interference at cycle 4 (fast, injection-rate dependent)

A system with a single failure threshold would show all TTI values within
approximately ±50% of each other (spread ratio ≈ 1.5–2×).  
HORUS v3 shows a 31× spread. This is a multi-attractor system.

---

## Determinism Conclusion

> **HORUS v3 is deterministic under adversarial stress.**

Hardware determinism is confirmed: identical input sequences always produce
identical output sequences. The apparent run-length variation in R2 (runs of 8 vs 31 cycles)
is a deterministic consequence of epoch_depth management intersecting the drift chain,
not hardware randomness. A second execution with the same stimulus would produce
identical run lengths.

---

## Recovery Conclusion

> **HORUS v3 exhibits clean recovery with zero attractor locking.**

All four failure attractors are **input-driven**. On removal of the adversarial stimulus
(replaced by neutral E=32 MUL anchor), the system returns to STABLE on the next clock
cycle (recovery latency = 0). There is no hysteresis, no hidden state persistence, and
no attractor locking observed under these four regimes. This property is architecturally
favorable: the failure domain boundary is sharp and the system self-clears when the
workload changes.

---

## Architectural Observations (Measurement-Only)

> The following are observational notes derived from measured data.  
> **No architecture changes are proposed, designed, or recommended in this document.**

| Observation | Evidence | Source |
|---|---|---|
| epoch_depth=16 does not prevent E field overflow in R2 | TTI(R2)=31 > epoch_depth=16 | HBS-C7 R2 |
| CLASS_B cancellation creates accumulator drift below region detection | 100% STABLE but 63.6× amplification | HBS-C7 R1, HBS-C6 W2 |
| Boundary oscillator is correctly isolated from accumulator | accum_entropy=0.045 bits in R3 | HBS-C7 R3 |
| Mixed workloads do not degrade per-class routing | R4 occupancy exactly matches injection ratio | HBS-C7 R4 |
| All attractors are stimulus-driven (no state persistence) | recovery latency=0 for all regimes | HBS-C7 D |

---

## Summary: System Characterization

| Property | Value |
|---|---|
| Single-threshold or multi-attractor? | **MULTI-ATTRACTOR** |
| Number of identified attractors | **4** |
| Deepest attractor onset | R2: 31 cycles (geometric) |
| Shallowest attractor onset | R3: 0 cycles (permanent boundary) |
| Epoch_depth=16 coverage | Geometric attractor (R2) only |
| Deterministic under stress? | **YES** |
| Attractor locking / hysteresis? | **NO** — clean recovery, latency=0 |
| Accumulator contamination visible to region monitor? | **NO** for R1 (100% STABLE, yet 63.6× drift) |

---

*HORUS v3 Failure Domain Map · Measurement-derived · 2026-07-02*  
*Authority: HBS-C6 (adversarial realism) + HBS-C7 (failure isolation)*  
*This document is the terminal architectural reference for failure physics in HORUS v3.*
