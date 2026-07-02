# Horus Design Limitations

**Document scope:** architectural trade-offs and constraints of Horus NFE v3,
observed in simulation and analysis. Items marked **v4 target** are acknowledged
gaps identified through review and stress testing — not hidden defects.

For design identity and the Digital Physics paradigm, see
[ARCHITECTURE_PHILOSOPHY.md](ARCHITECTURE_PHILOSOPHY.md).

---

## 1. Architectural Trade-offs (Intentional)

Horus NFE v3 makes three deliberate departures from IEEE-754 semantics.
These are **not bugs** — they are the price of **single-cycle MAC throughput**
on a 13-bit inference substrate.

| Trade-off | v3 behavior | Why we accept it |
|-----------|-------------|------------------|
| **Hard floor (no subnormals)** | Exponent underflow → `13'h000` + `underflow_flag` pulse | Eliminates denormal shifter chains and variable-latency MAC paths; bounded, flaggable edge behavior for edge AI. |
| **Saturating arithmetic (no NaNs)** | Exponent overflow → `13'hFFF` + `exp_ovf_flag`; no NaN/Inf domain | Removes exception muxes and undefined-state propagation; outliers saturate predictably in heavy-tailed activation distributions. |
| **Fixed-resolution mantissa (6-bit fraction)** | Hidden-bit normalize on MUL; MUL ≤ ~1.5% max vs FP64 on tested sweeps | Keeps mantissa multiply + renormalize in one cycle; 13-bit operand density beats wider formats on ops/mm² for blocked inference. |

**Throughput contract:** The MAC hot path (`horus_nfe`) completes ADD/SUB/MUL in
**one cycle** (SUB Guard-B adds a documented 2-cycle bubble on the borrow path
only). Introducing IEEE-style subnormal handling, dynamic alignment trees, or
NaN domains would break this contract and is explicitly out of scope for v3.

These trade-offs define Horus as a **Quantized Event Accumulation Engine** —
stable, saturating, deterministic — not a general-purpose floating-point unit.

**Evidence:** `tb/tb_boundary_stress.v` Cases 1–2 (floor / saturate);
`sim/horus_nfe_analysis.py` v3 adversarial sweep (0.31% mean, 0 Ghost Zero on MUL).

---

## 2. Fidelity Analysis vs. Dynamic Range

The architectural fidelity stress test (`tb/tb_fidelity_benchmark.v`) runs a
1024-cycle deep-chain accumulation with noise-injected fractional deltas and
compares the hardware running state (`decode(result)`) against an ideal FP64
golden model.

**Observed behavior (seed `0xDEAD_BEEF`, monotonic ADD chain):**

| Milestone | Cycle | Observation |
|-----------|------:|-------------|
| 1% relative divergence | 278 | Hardware state departs >1% from FP64 ideal |
| Saturation plateau | 384 | Horus output clamps (~4.26×10⁹); golden continues |

Deep chain accumulation shows **1% divergence at Cycle 278** and **saturation
at Cycle 384**. This behavior is **by design**, providing stable saturation
bounds for inference-style quantization — the MAC path retains single-cycle
throughput and bounded flaggable edge behavior rather than IEEE-754 exception
domains or unbounded dynamic range.

Reproduce: `make fidelity` (outputs in `sim/`). See README § Fidelity Analysis.

**v4 mitigation (planned):** Saturating Right-Shift normalization on `accum_out`
— insertion points documented in `rtl/horus_system.v`.

---

## 3. How to Read This Document

Horus is a **Quantized Event Accumulation Engine**, not a general-purpose
math unit. Limitations listed below are **architectural constraints** — boundaries
of the v3 contract — not defects to be patched silently without a version bump.

| Category | Meaning |
|----------|---------|
| **Observed (v3)** | Reproduced in RTL simulation or analysis scripts in this repo |
| **Analytical** | Derived from format/spec; not fully stress-tested in silicon |
| **v4 target** | Planned architectural extension; not implemented in current RTL |

---

## 4. Architectural Constraints — v4 Targets

These two items define the primary engineering gap between v3 (inference
substrate) and a fully self-contained quantization-aware accelerator.

### 4.1 Scale-Aware Weighting — **v4 target**

**Constraint (v3):** Each NFE word carries its **own biased exponent**. There is
**no hardware block-scale register** that pre-normalizes a weight or activation
tile to a shared dynamic range before MAC. Operands at mismatched exponent
scales accumulate as **raw codeword integers**, not scale-aligned real values.

**Observed behavior:**

- Mixed tiny + large accumulation (`tb/tb_boundary_stress.v`, Case 3) **propagates**
  monotonically — the counter sums codewords without collapse, but the integer
  sum does **not** equal a scale-correct real dot product.
- ADD_FRAC treats `op_b` as a **raw fractional delta** without exponent
  alignment — updates below `2^actual_E / 64` are silently dropped
  (`horus_nfe_analysis.py` §2).

**Impact:**

- Host / compiler must pre-quantize operands to compatible exponent bands.
- Training-style weight updates on large-magnitude weights lose sub-LSB
  deltas unless MUL-based update paths are used.

**v4 target:**

- Tile-level **shared block exponent** register (analogous to OCP MX block scale).
- Optional **scale-aware weighting** stage before MAC: shift operands by
  `block_exp` so MAC events share a common Q-format within a tile.
- Documented host API for scale assignment per graph node.

**Status:** Not in v3 RTL. Listed in README §3 and ARCHITECTURE_PHILOSOPHY §6.3.

---

### 4.2 Normalization — **v4 target**

**Constraint (v3):** Horus provides **per-operation** normalization (Thoth
Rollover on ADD, Guard-B two-cycle pipeline on SUB, hidden-bit normalize on
MUL). It does **not** provide **tensor-level normalization** (LayerNorm,
RMSNorm, softmax division) as a first-class hardware primitive.

**Observed behavior:**

- Guard-B reduces **per-SUB** borrow-path bias but does not eliminate
  **cross-layer drift** when hundreds of SUB normalizations chain in software.
- SUB Guard-B adds **2-cycle latency**; consumer must insert NOP bubble
  (documented in `rtl/horus_nfe.v`).
- Accumulator **does not re-normalize** partial sums — row outputs are raw
  integer sums of codewords.

**Impact:**

- LayerNorm / RMSNorm stacks mapped naïvely onto ADD_FRAC/SUB_FRAC will hit
  the **delta precision floor** at high stored exponents.
- Deep normalization sequences remain a **graph-compiler concern** in v3.

**v4 target:**

- Optional **Saturating Right-Shift** normalization on `accum_out` — see
  insertion points documented in `horus_system.v` (Insertion A/B/C).
- Optional **normalization unit** (running variance / RMS estimate) per tile
  row or per block, with defined rounding mode.
- **Scale-normalized accumulator** mode: re-quantize `accum_reg` to target
  `stored_E` every *N* MAC events (configurable).
- Explicit **LayerNorm Cascade** testbench on real activation traces (Llama-3
  / Mistral — planned in BENCHMARKS.md).

**Status:** Partial mitigation in v3 (Guard-B). Full normalization semantics
are **v4 target**.

---

## 5. Encoding and Arithmetic Constraints (v3, Observed)

### 5.1 Not IEEE-754

| Property | v3 behavior |
|----------|-------------|
| NaN | Not representable — by design (see §1) |
| Infinity | Replaced by saturation (`13'hFFF` + `exp_ovf_flag`) |
| Subnormals | Not supported — hard floor at `13'h000` + `underflow_flag` |
| Real-valued Σ | Not guaranteed — integer codeword sum only |

**Reference:** `tb/tb_boundary_stress.v` Cases 1–2; ARCHITECTURE_PHILOSOPHY §5.

---

### 5.2 ADD_FRAC delta precision floor — **Observed**

In ADD_FRAC (`op_sel = 2'b00`), `op_b` is a raw fraction delta:

```
delta_value = m_b / 64
minimum non-zero delta = 1/64 at operand scale
absolute floor = 2^actual_E / 64
```

Updates below this threshold are **silently truncated** (no flag).

**Mitigation (host-side, v3):**

- MUL-based weight updates: `(1 + η∇L) × weight`.
- Pre-scale via block exponent before ADD_FRAC.
- Clamp weights to `stored_E ≤ 36` during training export.

**v4 link:** Addressed by Scale-Aware Weighting (§4.1).

---

### 5.3 Ghost Zero (MUL) — **Mitigated in v3, observed in v1/v2**

Deprecated v1/v2 encoding produced silent zero products on MUL (16/32 events,
40.59% mean error on adversarial block — `horus_nfe_analysis.py` §0).

v3 mitigation: hidden-bit MUL, Bias-32, `underflow_flag` on exponent wrap.
**Not observed** on v3 MUL adversarial sweep.

**Scope limit:** Does not apply to ADD_FRAC silent truncation (§5.2).

---

### 5.4 Quantized Feature Event Counter semantics — **Observed**

```verilog
accum_reg <= accum_reg + zero_extend(result);
```

- Accumulator sums **13-bit integer codewords**, not decoded floats.
- Underflow floor events add `0x000` to the counter when `accum_en` is active.
- Overflow saturate events add `0xFFF` when `accum_en` is active.
- `accum_out` trails `accum_reg` by 1 cycle.

**Misinterpretation risk:** Treating `accum_out` as a fixed-point or IEEE
partial sum without decode + scale policy.

---

## 6. System Integration Constraints

| Constraint | Description | Status |
|------------|-------------|--------|
| Power gate `depth=0` | Closes accumulator gate (not unlimited) | Observed — `horus_pgate_ctrl.v` |
| 32-bit counter width | Overflows after ~524K full-scale MACs | Analytical |
| SUB Guard-B latency | 2 cycles; NOP bubble required | Observed — `tb/tb_horus_nfe.v` |
| Mesh verification | 2×2 mesh only | Simulated 7/7 |
| FPGA timing | 250 MHz constraints; no board closure | Planned |
| End-model benchmarks | No Llama/Mistral/ViT runs | Planned — BENCHMARKS.md |
| Systolic fill latency | 7 cycles to corner PE | Observed — `tb/tb_horus_system.v` |

---

## 7. Validation Gaps (Honest Scope)

What v3 **has** been shown to do (within tested domains):

- 26/26 RTL simulation tests pass.
- C-model vs FP64: ADD/SUB 0.00%; MUL ≤ 1.49% max.
- Boundary stress: floor, saturate, mixed accumulate behaviors characterized.
- Adversarial encoding: 0.31% mean vs E4M3/MXFP8 on 32-element synthetic block.

What v3 **has not** been shown to do:

- End-to-end transformer accuracy retention.
- Scale-mismatched operand tiles without host pre-normalization.
- Deep LayerNorm stacks without compiler-side compensation.
- Silicon timing closure or power measurement.

---

## 8. v4 Roadmap Summary

| ID | Constraint | v4 target | Priority |
|----|------------|-----------|----------|
| L1 | Scale-Aware Weighting | Block exponent + pre-MAC shift stage | **High** |
| L2 | Normalization | Saturating right-shift on accum_out; tile RMS/LayerNorm unit | **High** |
| L3 | ADD_FRAC silent truncation | Flag or widen delta path | Medium |
| L4 | Accumulator decode mode | Optional real-space estimate port | Low |
| L5 | Larger mesh verification | 8×8+ routing stress | Medium |
| L6 | Silicon sign-off | FPGA + ASIC timing/power | Planned |

---

## 9. Related Documents

| Document | Role |
|----------|------|
| [ARCHITECTURE_PHILOSOPHY.md](ARCHITECTURE_PHILOSOPHY.md) | Digital Physics; why these are trade-offs, not bugs |
| [NUMERICS.md](NUMERICS.md) | Format definition |
| [README.md](../README.md) | Project overview and fidelity summary |
| [tb/tb_boundary_stress.v](../tb/tb_boundary_stress.v) | Floor / saturate / mixed accum evidence |
| [rtl/horus_system.v](../rtl/horus_system.v) | Saturating right-shift insertion points |
| [sim/horus_nfe_analysis.py](../sim/horus_nfe_analysis.py) | ADD_FRAC floor + adversarial encoding |
| [sim/analyze_fidelity.py](../sim/analyze_fidelity.py) | Deep-chain fidelity plots |

---

*Horus (Native Fractional Engine project) · Design Limitations v2 ·
Architectural trade-offs · v4 targets: Scale-Aware Weighting, Normalization*
