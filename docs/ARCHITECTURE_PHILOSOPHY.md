# Horus Architecture Philosophy

**Document scope:** canonical identity statement for the Horus (Native
Fractional Engine project). Read this before interpreting RTL, testbenches,
or benchmark scripts as a general-purpose arithmetic engine.

---

## 1. Identity: Quantized Event Accumulation Engine

Horus is a **Quantized Event Accumulation Engine (QEA)** — not a floating-point
coprocessor, not a scientific compute unit, and not an IEEE-754 semantic clone.

At the system level it comprises:

```
Host / mesh router
    └── Tile (horus_system)
            └── NFE MAC core (horus_nfe)
                    └── Quantized Feature Event Counter (32-bit accum_reg)
    └── Systolic fabric (horus_systolic_array)
            └── 4×4 grid of MAC + counter PEs
```

**Operational contract:**

1. Operands arrive as **13-bit encoded events** (activations, weights).
2. Each MAC produces a **13-bit result event** (product or fractional update).
3. Each PE **counts** result events by **integer addition** into a 32-bit
   register — a **Quantized Feature Event Counter**.
4. Row outputs sum counter values for downstream consumption.

The accumulator answers: *"How many encoded MAC events occurred, weighted by
their codeword magnitude?"* — not *"What is the real-valued dot product?"*

---

## 2. Digital Physics Paradigm

Horus is built on a **Digital Physics** model of computation: values are not
continuous real numbers flowing through IEEE-754 pipelines — they are
**quantized code-indices** on a discrete lattice, and inference is the
**stable accumulation of MAC events** on that lattice.

```
Continuous model (IEEE-754)          Digital Physics (Horus NFE)
─────────────────────────            ───────────────────────────
Real-valued operands                 13-bit encoded code-indices
Exponent alignment + rounding        Single-cycle hidden-bit MAC
NaN / Inf exception domains          Floor + saturate flags (bounded)
FMA partial sums in float space      Integer event counter (accum_reg)
Variable latency (denormals)         Fixed 1-cycle MAC (no subnormal path)
```

### 2.1 Why code-indices, not floats

Each 13-bit word is an **index into a quantized magnitude table** — sign,
biased exponent, and 6-bit fraction define a lattice point
`V = (−1)^S × 2^(E−32) × (1 + f/64)`. Multiplication is **integer mantissa
multiply + exponent add + renormalize**, not general real arithmetic. The
accumulator does not reconstruct `Σ(aᵢ × bᵢ)` in ℝ; it **counts and sums
result codewords** as stable discrete events.

This avoids the explosive silicon complexity of IEEE-754: no subnormal
shifter chains, no NaN propagation muxes, no dynamic exponent-alignment
trees on the MAC hot path.

### 2.2 Why this is optimal for AI inference

| Property | Benefit for edge AI |
|----------|---------------------|
| **Determinism** | Same inputs → same flags and codewords every cycle; no denormal stalls or exception traps. |
| **Area efficiency** | 13-bit operands, single-cycle MAC, no metadata fetch — higher ops/mm² than FP32 FMA arrays at comparable inference accuracy targets. |
| **Predictable latency** | One MAC per cycle regardless of operand magnitude; systolic fill and mesh routing stay timing-closed. |
| **Stable saturation** | Outliers floor or saturate with named flags — bounded behavior for heavy-tailed activation distributions. |
| **Event semantics** | Partial sums as counted events map naturally to blocked GEMM and attention accumulation patterns. |

The design goal is **high-throughput, stable, saturating inference** — not
bit-exact scientific computation.

---

## 3. Design Philosophy

> **Prioritizing deterministic throughput and stable, saturating accumulation
> over continuous-space mathematical fidelity.**

### 3.1 What we optimize for

| Priority | Rationale |
|----------|-----------|
| **Deterministic throughput** | Inference SLAs are latency-bound; scale-fetch and calibration stalls are excluded from the MAC hot path where possible. |
| **Stable edge behavior** | Floors and saturates are preferred over NaN/Inf propagation or silent ghost results. |
| **Encoding density** | 13 bits per value, 52-bit AXI beat packing (4×13), no per-block metadata on the operand path. |
| **Simulation-verifiable contracts** | Behavior is defined by RTL + C-model within stated domains, not by appeal to IEEE semantics. |

### 3.2 What we explicitly de-prioritize

| De-prioritized | Why |
|----------------|-----|
| Bit-exact IEEE-754 fidelity | Wrong optimization target for blocked quantized inference. |
| Graceful subnormal underflow | Replaced by explicit floor + flag — simpler silicon, bounded behavior. |
| Real-valued accumulator reconstruction | Host or graph compiler must not assume `accum_out` decodes to a float sum. |
| Training-time gradient precision | ADD_FRAC delta path is inference-oriented; see docs/DESIGN_LIMITATIONS.md. |

---

## 4. Lossy, Stable Substrate

Horus implements a **Lossy, Stable Substrate (LSS)** for neural inference:

```
        ┌─────────────────────────────────────────┐
        │  LOSSY                                 │
        │  • 6-bit fraction (MUL ≤ ~1.5% vs FP64)│
        │  • Quantized operand encoding           │
        │  • Integer event counter (not float Σ)  │
        ├─────────────────────────────────────────┤
        │  STABLE                                 │
        │  • Underflow → floor + underflow_flag   │
        │  • Overflow  → saturate + exp_ovf_flag  │
        │  • No NaN domain                        │
        │  • Deterministic flag pulses (1 cycle)  │
        └─────────────────────────────────────────┘
```

**Lossy** means information is discarded at encode, multiply, and accumulate
boundaries — by design.

**Stable** means discarded information produces **named, flagged, repeatable
hardware states** — not undefined behavior.

Boundary-stress simulation (`tb/tb_boundary_stress.v`) observed:

- MUL underflow → `result = 13'h000`, `underflow_flag = 1` (floor, not silent).
- MUL overflow → `result = 13'hFFF`, `exp_ovf_flag = 1` (saturate, then accumulate).
- Mixed tiny + large accumulation → monotonic integer growth in `accum_reg`
  (propagate, no collapse).

---

## 5. Contrast with IEEE-754

Horus borrows **hidden-bit mantissa** notation from IEEE-754 but rejects its
**exception and continuity model**.

| Aspect | IEEE-754 | Horus NFE v3 |
|--------|----------|--------------|
| **Purpose** | General real arithmetic | Blocked inference MAC |
| **NaN** | Defined | **Not present** |
| **Infinity** | Defined | **Replaced by saturation** |
| **Subnormals** | Gradual underflow | **Hard floor** at `13'h000` sentinel |
| **Underflow signal** | Exception flags (optional) | **`underflow_flag` pulse** |
| **Overflow signal** | ±Inf | **`exp_ovf_flag` + max codeword** |
| **Accumulator** | Real sum (in FPUs) | **Integer sum of codewords** |
| **Semantic portability** | Cross-platform | **Requires Horus quantization contract** |

**Misinterpretation to avoid:** comparing Horus MUL error to FP64 and concluding
"near-IEEE accuracy." The correct comparison is against **quantized inference
requirements** — latency, outlier handling, and end-model accuracy under a
fixed encoding — not against continuous R^n arithmetic.

---

## 6. Quantized Feature Event Counter (PE Accumulator)

Inside each `horus_nfe` instance:

```verilog
accum_reg <= accum_reg + {{19{1'b0}}, result};  // 13-bit zero-extended
accum_out <= accum_reg;                          // 1-cycle registered mirror
```

### 6.1 Semantics

| Term | Meaning |
|------|---------|
| **Event** | One MAC operation produced a 13-bit `result` codeword |
| **Quantized** | The codeword is a discrete lattice point, not a continuous value |
| **Counter** | `accum_reg` performs unsigned integer addition of codewords |
| **Feature** | In inference context, accumulated activations / partial sums |

### 6.2 What the counter is NOT

- Not a fixed-point accumulator with a global binary point.
- Not an IEEE-754 fused multiply-add partial sum.
- Not guaranteed to equal `Σ decode(op_a[i]) × decode(op_b[i])` in real space.

### 6.3 Host interpretation

To recover approximate real-space meaning, the host must:

1. Decode each accumulated codeword under the NFE v3 format (see NUMERICS.md).
2. Apply any **scale-aware weighting** or block-exponent policy defined at
   graph-compile time (not yet in v3 RTL — v4 target).
3. Accept that intermediate accumulation is **lossy** and **non-associative**
   in continuous space.

---

## 7. System-Level Dataflow

```
Activations (13-bit events)
        │
        ▼
  Input skew buffer ──► Systolic mesh ──► MAC (horus_nfe)
        │                      │                │
        │                      │                ▼
        │                      │         result event (13-bit)
        │                      │                │
        │                      │                ▼
        │                      │         Event Counter (accum_reg)
        │                      │                │
        ▼                      ▼                ▼
  Weights (13-bit events)   row_out_*     op_count / flags
```

The **mesh router** (`horus_router`) moves encoded events between tiles.
The **power gate** (`horus_pgate_ctrl`) bounds how many events each counter
accepts per tile — a throughput / memory-budget control, not a precision fix.

---

## 8. Intended Workloads

**In scope (v3):**

- Blocked GEMM inference kernels (HBS-1 target)
- Attention projection layers with heavy-tailed outliers
- FPGA/ASIC inference accelerators with fixed quantization tables

**Out of scope (v3):**

- General scalar math libraries
- FP64 training with backward-pass gradient fidelity
- Portable "drop-in FP32" libraries without requantization

---

## 9. Version Roadmap (Philosophy Layer)

| Version | Identity emphasis |
|---------|-------------------|
| v1/v2 | Experimental encoding (deprecated — zero-biased, Ghost Zero on MUL) |
| **v3** | **Lossy stable substrate** — Bias-32, hidden bit, flagged floor/saturation |
| v4 (planned) | Scale-aware weighting + normalization constraints — see docs/DESIGN_LIMITATIONS.md |

---

## 10. Related Documents

| Document | Content |
|----------|---------|
| [NUMERICS.md](NUMERICS.md) | Bit layout, encode/decode, canonical constants |
| [DESIGN_LIMITATIONS.md](DESIGN_LIMITATIONS.md) | Architectural trade-offs and v4 targets |
| [README.md](../README.md) | Project overview, validation maturity, RTL map |
| [BENCHMARKS.md](../BENCHMARKS.md) | Inference benchmark methodology |

---

*Horus (Native Fractional Engine project) · Architecture Philosophy v2 ·
Digital Physics · Quantized Event Accumulation Engine · Lossy Stable Substrate*
