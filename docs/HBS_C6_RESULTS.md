# HBS-C6: Adversarial Real-World Workload Stress-Test — Results

**Document type:** Verification Results — External Realism Validation  
**Authority:** C4/C5 frozen kernel · C5.1 semantic correction applied  
**Version:** 1.0 · 2026-07-02  
**Status:** MEASURED — no RTL or compiler changes

---

## Executive Summary

HBS-C6 evaluated the C4 kernel under five adversarial workloads (W1, W2, W3, W4, W5) totaling 2500 cycles. Average KL divergence from the C5 uniform baseline was **0.8641 nats**, confirming that real workloads produce significantly different region distributions than the exhaustive-grid C5 scan.

The C4 partition topology (routing decisions) remained structurally valid under all workloads. Region boundaries continued to behave as step functions. Depth management remained independent of chain content. However, collapse exposure varied from 0.0% to 25.2% across workloads, compared to the 25% C5 uniform baseline.

---

## Workload Results

### W1: Sparse MAC bursts (CLASS_A, 5% spikes)

| Metric | Value |
|---|---|
| Accum std | 10354.3 |
| Boundary crossing rate | 9.8% |
| UF rate | 0.0% |
| OVF rate | 0.0% |
| KL divergence (vs C5) | 0.8026 nats |

Region occupancy:

| Region | W1 | C5 baseline | Δ |
|---|---|---|---|
| COLLAPSE | 0.000 | 0.250 | -0.250 |
| TRANSITION | 0.000 | 0.125 | -0.125 |
| STABLE | 0.950 | 0.375 | +0.575 |
| SATURATE | 0.050 | 0.250 | -0.200 |

### W2: Cancellation chains (CLASS_B, ±5–10% jitter)

| Metric | Value |
|---|---|
| Accum std | 5955.7 |
| Boundary crossing rate | 0.0% |
| UF rate | 0.0% |
| OVF rate | 0.0% |
| KL divergence (vs C5) | 0.9808 nats |

Region occupancy:

| Region | W2 | C5 baseline | Δ |
|---|---|---|---|
| COLLAPSE | 0.000 | 0.250 | -0.250 |
| TRANSITION | 0.000 | 0.125 | -0.125 |
| STABLE | 1.000 | 0.375 | +0.625 |
| SATURATE | 0.000 | 0.250 | -0.250 |

### W3: Boundary oscillation (CLASS_C, E=14/16/47/48)

| Metric | Value |
|---|---|
| Accum std | 274.8 |
| Boundary crossing rate | 74.6% |
| UF rate | 0.0% |
| OVF rate | 0.0% |
| KL divergence (vs C5) | 0.5185 nats |

Region occupancy:

| Region | W3 | C5 baseline | Δ |
|---|---|---|---|
| COLLAPSE | 0.252 | 0.250 | +0.002 |
| TRANSITION | 0.248 | 0.125 | +0.123 |
| STABLE | 0.000 | 0.375 | -0.375 |
| SATURATE | 0.500 | 0.250 | +0.250 |

### W4: Deep transformer chain (CLASS_D, feedback)

| Metric | Value |
|---|---|
| Accum std | 3163.9 |
| Boundary crossing rate | 0.2% |
| UF rate | 0.0% |
| OVF rate | 60.4% |
| KL divergence (vs C5) | 1.3223 nats |

Region occupancy:

| Region | W4 | C5 baseline | Δ |
|---|---|---|---|
| COLLAPSE | 0.000 | 0.250 | -0.250 |
| TRANSITION | 0.014 | 0.125 | -0.111 |
| STABLE | 0.000 | 0.375 | -0.375 |
| SATURATE | 0.986 | 0.250 | +0.736 |

### W5: Saturation spike injection (CLASS_A, 10% spikes)

| Metric | Value |
|---|---|
| Accum std | 7823.3 |
| Boundary crossing rate | 19.8% |
| UF rate | 0.0% |
| OVF rate | 0.0% |
| KL divergence (vs C5) | 0.6963 nats |

Region occupancy:

| Region | W5 | C5 baseline | Δ |
|---|---|---|---|
| COLLAPSE | 0.000 | 0.250 | -0.250 |
| TRANSITION | 0.000 | 0.125 | -0.125 |
| STABLE | 0.900 | 0.375 | +0.525 |
| SATURATE | 0.100 | 0.250 | -0.150 |

---

## D. Cancellation Realism Error (W2)

W2 generates near-cancellation pairs (SUB with ±5–10% fraction jitter). Mean residual per operation: **0.993531** (amplification factor: **63.6×** over the E=32 quantization step of 1/64 ≈ 0.0156).

Assessment: **AMPLIFIED**. Accum drift range over 500 cycles: 20497.

---

## F. Time-to-Failure-Bound

Measures cycles from each epoch reset until accumulator reaches 50% of observed max value. A TTFB > 16 confirms pgate_ctrl is never surprised by accumulator saturation within an epoch.

| Workload | Mean TTFB | Min TTFB | Exceeds epoch threshold (16)? |
|---|---|---|---|
| W1 | 9.6 | 9 | NO |
| W2 | 10.7 | 9 | NO |
| W3 | ∞ (never reached threshold) | — | YES |
| W4 | 5.0 | 5 | NO |
| W5 | 9.3 | 9 | NO |

---

## Required Validation Questions

**Q1: Does real workload distribution preserve C5 partition topology?**  
PARTIAL — some workloads do not visit all regions under adversarial stimulus.

**Q2: Is stable-band occupancy still dominant under adversarial workloads?**  
WORKLOAD-DEPENDENT — STABLE dominant for 3/5 workloads. Non-dominant: ['W3', 'W4'].

**Q3: Do cancellation workloads amplify residual drift or remain bounded?**  
AMPLIFIED — W2 cancellation residual is 63.6× the E=32 quantization step (0.9935 vs step=0.0156). NFE SUB at equal exponents does not produce true zero; the subtraction residual equals approximately the jitter magnitude, not the cancellation gap. This is the HBS-9 cancellation bias: NFE is not a cancellation-safe arithmetic. C4 routes CLASS_B through NORMALIZE_THEN_EXECUTE precisely because of this.

**Q4: Does depth behavior remain independent under real transformer-like chains?**  
YES — depth override produces mode=010 consistently in W4; depth management is independent of chain content.

**Q5: Is collapse rate invariant or workload-sensitive?**  
WORKLOAD-SENSITIVE — collapse rate varies from 0.0% to 25.2% (range=25.2%). C5 uniform baseline was 25%. Real distributions shift collapse exposure significantly.

**Q6: Is Time-to-Failure-Bound consistently > epoch depth threshold (16)?**  
WARNING — some workloads reach 50% saturation in ≤16 cycles: ['W1', 'W2', 'W4', 'W5']. Epoch depth threshold may be insufficient for these workloads.

---

## Figures

- `sim/hbs_c6_workload_heatmap.png` — Region occupancy per workload (KL annotated)
- `sim/hbs_c6_collapse_exposure.png` — Collapse/Saturation exposure vs C5 baseline
- `sim/hbs_c6_cancellation_drift.png` — W2 accum drift and residual magnitude
- `sim/hbs_c6_deepchain_degradation.png` — W4 depth vs accum/UF/stable retention

---

*HBS-C6 · HORUS v3 · 2026-07-02*
