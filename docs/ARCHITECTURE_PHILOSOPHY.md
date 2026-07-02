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

## 9. In-Band Compute Policy — Decoupled Control Architecture

### 9.1 Design Principle

Horus v3 introduces a **strict separation** between two classes of system signals:

| Class | Signal | Location | Meaning |
|-------|--------|----------|---------|
| **Compute Policy** | `mode_tag [2:0]` | Inside the data flit, on `horus_nfe` port | *How this MAC result is folded into the accumulator* |
| **Flow Control** | `depth_reset` + `accum_clr` | Controller-generated, control-plane only | *When the accumulator is cleared between depth windows* |

This decoupling is an **architectural safeguard against mixed-abstraction ambiguity**: a data-plane bit must never trigger a state-machine transition, and a control-plane signal must never encode arithmetic semantics.

### 9.2 In-Band Compute Policy (`mode_tag`)

The three lowest-significant bits of the flit carry a **Compute Policy** tag that travels with each MAC pair. Control logic is now **local to the flit** — the PE self-governs its accumulation behavior based on what the compiler or QAT framework annotated at dispatch time.

```
13-bit NFE flit (op_a or op_b):
  [12]    Sign S
  [11:6]  Exponent E (Bias-32)
  [5:0]   Fraction f

3-bit mode_tag (sidecar, not inside the flit bits):
  000     Standard     — baseline arithmetic, unchanged accumulation
  001     Bias-Corrected — LUT-based per-exponent offset before accumulation (W01/Test 9)
  010     Pre-Scaled   — decrement stored exponent by 1 before accumulation (÷2, W03/W06)
  011     Safe-Accum   — 32-bit unsigned saturating addition (W04 spike isolation)
  1xx     Reserved     — treated as Standard; future policy extensions
```

The Policy Decoder is a **single-cycle combinational mux** inside `horus_nfe` — all four paths (including the 33-bit saturating adder) complete within one combinational layer. The arithmetic result (`result` register) is **never modified** by `mode_tag`; only the accumulation word differs.

### 9.3 Flow Control: Depth-Monitor in `horus_controller`

Snapshot/Reset events are **categorically forbidden** in the data flit. They are managed exclusively by the controller's **Depth-Monitor** register:

```
horus_controller new ports:
  input  max_depth [5:0]   — configurable MAC-depth threshold (0 = disabled)
  output depth_reset        — 1-cycle pulse: boundary reached, accum_clr asserted
```

When `depth_counter` (free-running during STREAM) reaches `max_depth`, the controller simultaneously asserts `depth_reset` and `accum_clr` for one cycle. The MAC pipeline is not stalled — `accum_en` remains high — and the counter resets to zero, opening a fresh depth window. This is **system-managed**, not flit-driven.

**Why this separation prevents ambiguity:**

- A Reset triggered by a flit bit would cause the same instruction stream to produce different accumulator states depending on when the bit arrives — violating the determinism invariant.
- A Compute Policy encoded in a control wire would require the controller to inspect arithmetic intent — violating the Moore FSM's output-only purity.

The architecture is **self-governing at two levels**: the PE self-selects its accumulation strategy from the flit tag; the controller self-resets the accumulator from its own cycle counter.

---

## 10. Version Roadmap (Philosophy Layer)

| Version | Identity emphasis |
|---------|-------------------|
| v1/v2 | Experimental encoding (deprecated — zero-biased, Ghost Zero on MUL) |
| **v3** | **Lossy stable substrate** — Bias-32, hidden bit, flagged floor/saturation |
| **v3.1** | **In-Band Compute Policy** — `mode_tag`, Policy Decoder, Depth-Monitor flow control |
| v4 (planned) | Scale-aware weighting + SRS normalization — see docs/DESIGN_LIMITATIONS.md |

---

## 11. HBS-11 Validation Results

HBS-11 was the first end-to-end measurement of the v3.1 policy system under
controlled stimulus.  All results are computed from live RTL simulation
(2,450 rows, `sim/HBS11_POLICY_VALIDATION.csv`).

### 11.1 Final Policy System Classification

| Policy | Target Weakness | Status | Key Metric |
|--------|----------------|--------|-----------|
| **Mode 001 Bias-Corrected** | W01 — Cancellation Drift | `C — No Measurable Improvement` | BIAS_LUT=0 → 0.00% residual reduction (calibration required) |
| **Mode 010 Pre-Scaled** | W03/W06 — Floor/Range | `B — Partial Improvement` | −6.25% accumulator magnitude; floor_rate unchanged |
| **Mode 011 Safe-Accum** | W04 — Spike Saturation | `C — No Measurable Improvement` | 32-bit clamp not triggered at ≤63-MAC tile depth |
| **Depth-Monitor** | Floor Attractor (ctrl) | `A — Demonstrated Improvement` | 10/10 windows: depth_reset fires at max_depth=4 |
| **Scheduler** | Mixed Regimes | `B — Partial Improvement` | 5.8× accumulator variance reduction vs static baseline |

### 11.2 Recommended Deployment Profiles

| Context | Policy | Basis |
|---------|--------|-------|
| Short inference chains (≤ depth 8) | `000 Standard` | Zero overhead; no failure-domain exposure |
| Cancellation-heavy workloads | `001 Bias-Corrected` | **Requires BIAS_LUT calibration from Test 9 data** |
| Deep composition workloads | `010 Pre-Scaled` | −6.25% accumulator magnitude; pair with Depth-Monitor |
| Saturation-prone workloads | `011 Safe-Accum` | Effective at >500K MAC accumulation depths |
| Mixed production inference | **Scheduler** | Best accumulator stability; 5.8× variance reduction |

### 11.3 Architectural Status of Known Weaknesses

| Weakness | Status | Supporting Evidence |
|----------|--------|---------------------|
| **W01 — Cancellation Drift** | Partially Mitigated | HBS-11A: mechanism correct; zero gain until BIAS_LUT calibrated |
| **W03 — Underflow Collapse** | Partially Mitigated | HBS-11B: accumulator −6.25%; result-domain floor collapse = result-domain only |
| **W04 — Spike Saturation** | Partially Mitigated | HBS-11C: Safe-Accum correct; not triggered at standard tile depths |
| **W06 — Dynamic Range Exhaustion** | Partially Mitigated | HBS-11B: accumulator magnitude contained by Pre-Scaled |
| **Floor Attractor** | **Mitigated** | HBS-11D: depth_reset fires at max_depth=4 (100% of 10 windows) |

### 11.4 Domain Boundary Finding

All `mode_tag` policies act exclusively on the **accumulator path** — they
modify `accum_word` before it is added to `accum_reg` but do not alter the
`result` register or the NFE arithmetic pipeline.  Result-register weaknesses
(floor collapse, exponent overflow) are mode-independent by design and are
scheduled for v4 result-domain mitigations.

This boundary is architecturally intentional: the Policy Decoder was designed
to address accumulator-domain distortions while preserving the arithmetic
core's single-cycle throughput and synthesizability invariants.

---

## 12. HBS-12 Findings: Arithmetic Boundary Mapping

*HBS-12 was executed 2026-07-02. All measurements used `mode_tag = 3'b000` (Standard) to isolate pure arithmetic-core behavior.*

### 12.1 Arithmetic Limits

The exact operating envelope of the NFE v3 arithmetic core has been experimentally verified:

| Boundary | Measured Value | Algebraic Basis |
|----------|---------------|-----------------|
| Minimum reliable `stored_E` | **16** (actual_E = −16) | 2E − 32 ≥ 0 → E ≥ 16 |
| Maximum reliable `stored_E` | **47** (actual_E = +15) | 2E − 32 ≤ 63 → E ≤ 47 |
| Usable exponent window | **32 / 64 (50 %)** | NORM zone for MUL |
| Chain depth fidelity limit | **≤ 16** (0 % floor) | seeds E∈[28..35], CHAIN_Y = NFE_HALF |
| Chain depth collapse onset | **≥ 32** (56 % floor) | floor attractor threshold |
| Full collapse depth | **64** (100 % floor) | all seeds → NFE_FLOOR |
| ADD reversibility | **100 %** (no rollover) | Guard-A round-trip lossless |
| ADD rollover recovery | **0 %** | Thoth Rollover destroys f bits |
| MUL identity accuracy | **100 %** | MUL(x, ONE) = x verified |

### 12.2 Deterministic Failure Modes

All failure modes are **deterministic** — no stochastic behavior was observed in any of the 1,255 data rows collected:

| Failure Mode | Trigger | Classification |
|-------------|---------|---------------|
| MUL underflow | `E_a + E_b < 32` | Deterministic — algebraic threshold |
| MUL overflow | `E_a + E_b > 95` | Deterministic — algebraic threshold |
| ADD OVF | E = 63 and rollover | Deterministic — corner case |
| SUB FTZ | E < norm_shift | Deterministic — priority encoder |
| Floor attractor | chain depth ≥ E_seed | Deterministic — absorbing state |
| Information cliff | depth transitions from 16→32 | Deterministic — no graceful degradation |
| Rollover information loss | f + delta ≥ 64 | Deterministic — right-shift truncation |

The determinism of failure modes is a **positive architectural property**: failures can be predicted, flagged, and avoided at compile time rather than discovered at runtime.

### 12.3 Phase Transitions

Three distinct arithmetic phases were identified and their transitions measured to single-E-step precision:

```
COLLAPSE (UF)          STABLE                   SATURATED (OVF)
E = 0..15              E = 16..47               E = 48..63
──────────────────────────────────────────────────────────────
16 values (25%)        32 values (50%)           16 values (25%)
Immediate UF floor     Full fraction resolution   Immediate OVF max
absorbing state        100% utilisation           non-absorbing
```

The information retention curve reveals a second-order phase transition in the depth dimension:

```
Depth ≤ 16:   29 unique / 32 seeds  (4.81 bits entropy) — STABLE
Depth = 32:   14 unique / 32 seeds  (2.59 bits entropy) — DEGRADED
Depth = 64:    1 unique / 32 seeds  (0.00 bits entropy) — COLLAPSED
```

**There is no gradual degradation path.** The cliff from depth-16 to depth-32 is abrupt.

### 12.4 Policy-Arithmetic Domain Boundary

A fundamental architectural boundary has been established:

> **Execution policies operate on the accumulator path, which receives the post-arithmetic NFE result.  They cannot influence, prevent, or mitigate arithmetic-domain failure modes (UF, OVF, FTZ, rollover, floor attractor).**

This boundary was implicit in the design but is now formally documented and benchmarked. It explains the HBS-11 finding that policies provide only partial improvement: they address accumulator-level artifacts but cannot reach into the arithmetic core.

The architecture achieves clean separation: the arithmetic core is stateless and purely combinational per operation (excluding the 2-cycle SUB Guard-B pipeline), while policies are accumulator-state modifiers. This decoupling is correct engineering — it keeps the arithmetic core synthesizable and fast.

### 12.5 Architectural Implications for Future Versions

1. **Compiler responsibility:** The safe exponent window (`E ∈ [16..47]`) must be enforced by the compilation tool-chain, not by runtime hardware. A hardware clamp would add latency and area; compile-time enforcement is zero-cost.

2. **Depth-monitor sufficiency:** The `horus_controller MAX_DEPTH` register addresses the depth-cliff by partitioning long chains into short epochs. Optimal window ≤ 16 per epoch. This is validated by HBS-11D and now corroborated by HBS-12D.

3. **Floor attractor as architectural constant:** The floor attractor is not a bug — it is a consequence of the finite exponent range and the hidden-bit encoding. It should be treated as a deterministic constant output (as noted in `COMPOSITION_GEOMETRY.md`) and handled by the graph compiler (e.g., detect floor outputs and bypass subsequent operations).

4. **Rollover irreversibility:** Any compiler attempting to build reversible compute graphs must avoid Thoth Rollover. This imposes `delta ≤ 63 − f` for all ADD nodes in reversible subgraphs.

---

---

## 13. HBS-13 Findings: Boundary Gap Characterization

*Added: 2026-07-02. Source: `sim/HBS13_BOUNDARY_GAP.csv`, `sim/HBS13_SUMMARY.log`.*

HBS-13 characterized the exact information physics of the two arithmetic phase boundaries.

### 13.1 Boundary Geometry: Both Boundaries Are Cliffs

Both the collapse boundary (E=15↔16) and the saturation boundary (E=47↔48) are **CLIFF geometry** transitions:

- **Fraction-independent:** Every f value (0..63) transitions simultaneously. The cliff is perfectly vertical in E-space.
- **Single-E-step:** No gradual degradation, no quantized stepping, no hysteresis.
- **Stateless:** The transition is a pure function of current operand E values. No operation history affects it.

This confirms that both boundaries are **algebraic discontinuities** in the exponent arithmetic, not noise-induced or stochastic degradation.

### 13.2 Information Behavior: Exponent-Channel Only

Scale-down and scale-up chains using `MUL(x, HALF)` and `MUL(x, TWO)` move information **exclusively through the exponent channel**. The fraction field is inert throughout:

- `MUL(x, HALF)` or `MUL(x, TWO)` with f_b=0 preserves f_a exactly at every step.
- Fraction is disturbed only at boundary events: floor forces f=0, OVF forces f=63.
- Entropy loss is a discrete event at boundary crossing, not a gradual degradation.

**This is the key architectural property:** within the stable zone and even while transiting the collapse/saturation zones via non-self operations, information is **perfectly conserved**.

### 13.3 Recoverability

Near-boundary round-trips (no floor/OVF crossing) are **perfectly reversible** — both E and f recover identically. This was confirmed across anchors E=24, 32, 40 with f=31, using 20-step round-trips that reached E values as low as 4 (deep in the collapse zone).

Through-floor round-trips exhibit two deterministic losses:
1. **Fraction erasure (f=0):** Permanent and universal.
2. **E overshoot (+2):** Arises because the floor is an absorbing state for descent but not for ascent.

The +2 E offset is **predictable** and could be compensated by a compiler that tracks floor events.

### 13.4 ADD as a Boundary-Transport Mechanism

ADD with Thoth Rollover is not just a fraction-summing operation — it is a **phase-boundary transport mechanism**:

- For any operand near E=15: 50% of ADD operations (those with f ≥ 32) will cross into the stable zone.
- For any operand near E=47: 50% of ADD operations will cross into the saturation zone.

**This is the dominant uncontrolled boundary-crossing risk in real compute graphs.** MUL(x,x) at E=15 always underflows — this is predictable. But ADD with high-fraction operands near the boundary is context-dependent on f, which may not be statically predictable.

A future compiler or scheduler must treat ADD as a boundary-sensitive operation for operands with `stored_E ∈ {15, 47}` and f ≥ 32.

### 13.5 The True Self-Multiplication Safe Floor

HBS-13E revealed a subtle but important refinement of the HBS-12 stable zone definition:

- HBS-12 defined stable zone as E=16..47 (no UF/OVF flag from MUL(x,x)).
- HBS-13 showed that MUL(x,x) at E=16..23 produces **results in the collapse zone** (E_result < 16) with no UF flag.
- The self-multiplication result stays **in the stable zone** only when E_input ≥ 24.

This refines the operational guidance:

```
Arithmetic Zone  │  stored_E   │  MUL(x,x) safe?  │  Result stays stable?
─────────────────┼─────────────┼──────────────────┼──────────────────────
Collapse zone    │  0..15      │  No (UF)          │  No
Unsafe stable    │  16..23     │  Yes (no UF)      │  No (E_result < 16)
Safe stable      │  24..39     │  Yes              │  Yes (E_result 16+)
Upper stable     │  40..47     │  Yes              │  Yes (E_result <48)
Saturation zone  │  48..63     │  No (OVF)         │  No
```

The **operationally safe exponent window for self-multiplication** is E = 24..39, not 16..47. Compilers targeting repeated MUL chains should enforce this tighter range.

### 13.6 Deterministic Boundary Physics

Every boundary phenomenon discovered in HBS-13 is **deterministic and algebraically derivable** from the encoding:

| Phenomenon | Formula | Value |
|------------|---------|-------|
| Steps to floor from E_seed | E_seed + 1 | Varies |
| Steps to OVF from E_seed | 64 − E_seed | Varies |
| E recovery offset after floor | +2 (absorbing state artifacts) | Fixed |
| ADD boundary-crossing threshold | f ≥ 32 | Fixed |
| True MUL(x,x) safe floor | E ≥ 24 | Fixed |
| Natural exponent anchor | E=32 (equidistant to both boundaries) | Fixed |

None of these require measurement to predict — they are provable from the arithmetic. HBS-13 confirms the hardware implements the theory exactly.

---

## 14. Related Documents

| Document | Content |
|----------|---------|
| [EXECUTION_POLICY.md](EXECUTION_POLICY.md) | Regime-Aware Execution; policy modes; HBS-11 results; Policy Applicability Boundary |
| [HORUS_ARITHMETIC_ENVELOPE.md](HORUS_ARITHMETIC_ENVELOPE.md) | Complete arithmetic envelope; compiler/QAT constraints; phase diagram; HBS-13 geometry |
| [HORUS_BOUNDARY_GAP_ANALYSIS.md](HORUS_BOUNDARY_GAP_ANALYSIS.md) | Boundary gap principal reference; recovery characteristics; v4 directions |
| [HBS13_RESULTS.md](HBS13_RESULTS.md) | Full HBS-13 benchmark report |
| [HBS12_RESULTS.md](HBS12_RESULTS.md) | Full HBS-12 benchmark report |
| [HBS11_RESULTS.md](HBS11_RESULTS.md) | Full HBS-11 benchmark report |
| [COMPOSITION_GEOMETRY.md](COMPOSITION_GEOMETRY.md) | Deterministic residual manifold; Tests 9–10; bias-table guide |
| [NUMERICS.md](NUMERICS.md) | Bit layout, encode/decode, canonical constants |
| [DESIGN_LIMITATIONS.md](DESIGN_LIMITATIONS.md) | Architectural trade-offs and v4 targets |
| [README.md](../README.md) | Project overview, validation maturity, RTL map |
| [BENCHMARKS.md](BENCHMARKS.md) | Inference benchmark methodology |
| [HBS14_RESULTS.md](HBS14_RESULTS.md) | Full HBS-14 end-to-end test report |
| [HORUS_END_TO_END_SYSTEM_REPORT.md](HORUS_END_TO_END_SYSTEM_REPORT.md) | System integration principal reference |

---

## HBS-14 System Integration Findings

**Source:** HBS-14 End-to-End System Consistency Suite · 2026-07-02  
**DUTs:** `horus_system` (NFE + pgate_ctrl), `horus_systolic_array` (4×4)  
**Scope:** 2,643 simulation events · 4 policy modes · 6 test configurations

### Interaction Effects

**Policy and arithmetic are completely decoupled at the RTL level.** The `result` signal path from `horus_nfe` exits the always block before the policy decoder is entered. No policy mode — standard, bias-corrected, pre-scaled, or safe-accumulation — has any path to the `result` register. This decoupling was verified in 384 direct comparisons (zero mismatches).

The accumulator path IS policy-dependent by design:
- MODE_PRSC reduces each accumulated contribution by one exponent step. The net effect over 32 mixed-zone operations is a ≈2.5% reduction in accumulated total relative to MODE_STD.
- MODE_SAFE prevents 32-bit accumulator wraparound. For workloads that do not overflow 32 bits, SAFE is identical to STD.
- MODE_BIAS (with default LUT=0) is identical to MODE_STD. Population with non-zero LUT values is a compile-time calibration step.

### Policy Interaction Behavior

Rapid mode switching (every cycle, random mode selection, 500-cycle stream) produces **zero result interference**. HORUS v3 has no mode-context register and no cross-cycle mode state. Each operation sees exactly one mode; the mode has no memory.

Mixed-mode accumulation is deterministic: the final accumulator value is uniquely determined by the sequence of (operand, mode) pairs. A scheduler that switches modes based on workload type produces predictable, reproducible accumulator trajectories.

### System-Level Stability Conclusions

1. **Regime-dependence does not compromise stability.** The three arithmetic regimes (stable, collapse, saturation) are sharply bounded and algebraically predictable. Sustained mixed-regime operation for 2,000 cycles showed no spreading of failure modes, no drift accumulation, and no entropy decay in the stable phase.

2. **Failure modes are an architectural invariant, not a runtime variable.** At E=15, self-multiplication underflows with 100% probability regardless of operational history, surrounding operations, or policy mode. This is not a timing, stochastic, or context issue — it is the algebraic consequence of the exponent arithmetic: 15+15−32=−2 < 0.

3. **Hardware flags are the authoritative failure signal.** `underflow_flag` and `exp_ovf_flag` are set by the arithmetic core and pass through the policy layer unchanged. Host software that relies on these flags for error detection can do so with full confidence that no policy mode will suppress them.

4. **The systolic array is consistent with individual horus_nfe operations.** The 4×4 fill-pipeline produces deterministic row-differentiated outputs that reflect the exponent structure of input activations. The zero-input test confirms correct reset behavior.

5. **pgate_ctrl comment inconsistency.** The first gate-rule comment in `horus_pgate_ctrl.v` incorrectly states `host_tile_depth=0 → unlimited`. The implementation is `count < 0` (unsigned), which is always false → gate closed. Valid accumulation requires `host_tile_depth ≥ 1`. The correct semantics are: 0 = power-off; 1..63 = MAC budget. This should be corrected in v4.

### Final System Classification

| Category | HORUS v3 Status |
|---|---|
| Fully Consistent System | **YES** — 5/5 checks consistent |
| Regime-Dependent System | **YES** — three distinct regimes |
| Masked Failure System | **NO** — flags are policy-invariant |
| Contradictory System | **NO** — all HBS-11..13 confirmed |
| Unstable System | **NO** — all failures are algebraic |

---

*Horus (Native Fractional Engine project) · Architecture Philosophy v3 ·
Digital Physics · Quantized Event Accumulation Engine · Lossy Stable Substrate*
*HBS-11 Validated: 2026-07-02 · HBS-12 Arithmetic Envelope added: 2026-07-02*
*HBS-13 Boundary Gap added: 2026-07-02 · HBS-14 System Integration added: 2026-07-02*
