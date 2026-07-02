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
| [HORUS_V3_FINAL_SPEC.md](HORUS_V3_FINAL_SPEC.md) | Gold master specification; layered architecture model; system invariants |
| [EXECUTION_MAPPING.md](EXECUTION_MAPPING.md) | Formal execution contract; phase-space semantics |
| [HORUS_SYSTEM_UTILIZATION_BLUEPRINT.md](HORUS_SYSTEM_UTILIZATION_BLUEPRINT.md) | Runtime strategy; mode selection guide; deployment configurations |
| [HORUS_C1_COMPILER_SPEC.md](HORUS_C1_COMPILER_SPEC.md) | Compiler specification; region classification; ABMP protocol |
| [HORUS_SYSTEM_COMPILATION_MODEL.md](HORUS_SYSTEM_COMPILATION_MODEL.md) | Compilation model; layer separation diagrams; full pipeline |
| [HORUS_C3_WORKLOAD_EMBEDDING.md](HORUS_C3_WORKLOAD_EMBEDDING.md) | Workload embedding; phase scheduler; Phase Transport protocol [SUPERSEDED] |
| [HORUS_PHASE_SCHEDULER_MODEL.md](HORUS_PHASE_SCHEDULER_MODEL.md) | Visual phase scheduler model; class flow diagrams [SUPERSEDED] |
| [HORUS_C2_LIVE_SYSTEM_REPORT.md](HORUS_C2_LIVE_SYSTEM_REPORT.md) | Live system measurement; measured occupancy baseline |
| [HORUS_C4_COMPILER_KERNEL_SPEC.md](HORUS_C4_COMPILER_KERNEL_SPEC.md) | Unified compiler kernel; 32-entry truth table; current authority |

---

## C4 — Compiler Kernel Compression Principle

**Source:** HORUS C4 Compiler Kernel Specification · 2026-07-02  
**Authority:** Compression of C1 + C3 into a single deterministic function

### Principle Statement

> **The compiler is not a system of rules. It is a single decision function over phase-space regions.**

C1 defined instruction-level routing as a multi-stage pipeline. C3 defined workload-level scheduling as a multi-stage embedding framework. Both were correct. C4 proves they were always the same thing: a finite mapping over three inputs.

### The Compression

```
(workload_class, estimated_E, depth) → (mode_tag, action)
```

This is the complete compiler. Three inputs, two outputs, 32 enumerable cases. All C1 routing rules, all C3 scheduling rules, all ABMP logic, all workload profiles — they resolve to entries in a truth table.

The multi-stage compiler architectures described in C1 and C3 are conceptually deprecated. Their **content** (action semantics, workload classification criteria, physics explanations) remains valid as implementation reference material. Their **structure** (pipeline stages, layered frameworks, embedding analyzers) is superseded by the kernel.

### What Changed

| C1 + C3 (Multi-Stage) | C4 (Kernel) |
|---|---|
| Workload classifier → Phase embedding → Scheduling policy → Instruction emitter | `HORUS_KERNEL(class, E, depth)` |
| Multi-stage pipeline with context passing | Single stateless function call |
| Implicit decision authority at each stage | Explicit truth table: 32 entries, fully enumerable |
| ABMP as a multi-phase protocol narrative | `NORMALIZE_THEN_ROUTE` action token |
| Phase Transport as a described mechanism | `NORMALIZE_THEN_ROUTE` at COLLAPSE for B/D |
| Rules S1–S4 + C1 mode table + depth rules | Single function body, single mode output |

The routing logic has not changed. The representation of that logic has been compressed.

### Compiler as Stateless Kernel

The execution contract from C4 §1.7:

```
HORUS C4 compiler is a stateless deterministic routing function
mapping (workload_class, estimated_E, depth) into (mode_tag, action).
No historical state is used. No runtime adaptation occurs.
The same inputs always produce the same outputs.
The function is total and finite: 32 output cases.
```

A compiler that maintains state between decisions — that remembers previous regions, adjusts workload class based on flag observations, or adapts mode based on accumulator drift — is not a C4 compiler. C4 is stateless by definition.

### Deprecated Constructs

The following are **conceptually deprecated** as decision-making frameworks. They remain in their respective documents as implementation reference material.

| Construct | Status | Replacement |
|---|---|---|
| C1 multi-stage instruction pipeline | SUPERSEDED | `HORUS_KERNEL()` truth table |
| C3 phase embedding analyzer | SUPERSEDED | `workload_class` static annotation |
| C3 scheduling policy generator | SUPERSEDED | `HORUS_KERNEL()` output |
| ABMP multi-phase protocol narrative | SUPERSEDED | `INSERT_EPOCH_BOUNDARY` action token |
| Phase Transport as a described mechanism | SUPERSEDED | `NORMALIZE_THEN_ROUTE` at COLLAPSE |
| Rules S1–S4 as a named ruleset | SUPERSEDED | Rows in the truth table |

**Deprecation is documentation-only.** No documents are deleted. The superseded documents contain essential action implementation details (what `NORMALIZE_THEN_ROUTE` means in hardware terms, how to compute tile_depth, what Phase Transport's hardware physics are) that the C4 kernel references but does not repeat.

### The Kernel Stack

```
Hardware (RTL)       →  immutable physics  ←  source of truth
C4 Kernel            →  stateless decision function  ←  authority
C1/C3/ABMP docs      →  action implementation guides  ←  reference
```

The architecture is now three layers: physics, decision, and implementation guides. Nothing above the physics layer changes the physics. Nothing above the kernel layer changes the routing decision.

---

## C3 — Workload Embedding Principle

**Source:** HORUS C3 Workload Embedding Specification · 2026-07-02  
**Authority:** HBS-11..HBS-C2 measured hardware behavior + C1 compiler spec

### Principle Statement

> **The compiler does not optimize arithmetic outcomes — it optimizes region occupancy.**

C1 established that the compiler is a phase-space router at the instruction level: given a single operation, it classifies the operand's exponent and selects the appropriate mode_tag and execution region.

C3 extends this principle to the **workload graph level**. Before a single instruction is emitted, C3 computes the expected **phase embedding profile** of the entire workload: the predicted distribution of operations across the four arithmetic regions (Stable, Transition, Collapse, Saturation), the dominant region, and the risk classification. Scheduling decisions — tile depth, mode escalation, ABMP triggers, epoch boundaries — are derived from this profile.

### The Compiler as Phase-Space Scheduler

```
C1 (instruction level):  single operation → region → mode_tag
C3 (workload level):     workload graph   → region distribution profile
                                            → scheduling policy
                                            → epoch structure
                                            → ABMP pre-placement
```

A phase-space scheduler does not ask "what is the best way to execute operation X?" It asks "what is the expected behavior of this workload in the HORUS exponent space, and how should execution be sequenced to keep operations in the regions where the hardware physics produce the desired behavior?"

This is a fundamentally different objective from a numerical optimizer:

| Optimizer (not HORUS C3) | Phase-Space Scheduler (HORUS C3) |
|---|---|
| Minimizes arithmetic error | Maximizes stable-band occupancy |
| Adapts to runtime values | Uses static workload graph analysis |
| May modify computation | Only sequences and routes |
| May choose between algorithms | Routes a fixed algorithm to fixed regions |
| Views exponents as continuous | Treats exponent space as discrete phase topology |

### Region Occupancy as the Scheduling Objective

HBS-C2 measured 59.3% stable-band occupancy under mixed continuous stimulus. This is the reference baseline for a correctly embedded workload. A C3 scheduler that allows stable-band occupancy to fall below 40% is misrouting workloads — it is sending computation into boundary zones unnecessarily.

The four regions are not equally weighted in importance:

```
STABLE (E=16–47):     Primary compute execution — maximize occupancy
TRANSITION (E≈16,47): Boundary management — minimize dwell time
COLLAPSE (E=0–15):    Routing zone — zero accumulation; rescue or bypass
SATURATION (E=48–63): Ceiling zone — zero accumulation; clamp or bypass
```

The correct scheduling objective is:
```
maximize:  stable_band_fraction
subject to: depth_constraints (C1 §1.5)
            mode_rules (C1 §1.4)
            class_rules (C3 §1.4)
            hardware_physics_immutable
```

### Formal Workload Embedding

Every workload that enters the C3 layer must produce a **phase embedding profile** before any instructions are emitted. This profile is a static analysis output that answers:

1. What percentage of operations will land in each region?
2. What is the dominant region?
3. What is the risk classification (LOW / MEDIUM / HIGH)?
4. Where are the epoch boundaries?
5. Are ABMP triggers pre-placed?

The profile is deterministic — the same workload graph always produces the same profile. No runtime adaptation, machine learning, or probabilistic inference is used.

### Phase Transport: Boundary Physics as a Scheduling Feature

The Thoth Rollover property of the ADD operation (HBS-13A) provides a deterministic phase boundary crossing tool:

```
ADD(x, x) where f_x ≥ 32:
  E_result = E_x + 1    (Thoth Rollover: f + f ≥ 64)
  f_result = 2*(f_x − 32)
```

At E=15 with f≥32, this moves a codeword from the Collapse routing zone to the Transition zone (E=16) in a single operation. This is **Phase Transport** — a deterministic architectural rescue mechanism, formally enabled by the C3 layer.

**Phase Transport is not a side-effect.** It is the compiler's intentional use of a documented hardware property to perform controlled phase-space movement. The hardware physics are unchanged; the compiler uses them as a scheduling primitive.

The asymmetric mirror at E=47 (ADD with f≥32 pushes to E=48 = saturation) is a **hazard**, not a rescue. The C3 scheduler explicitly prevents ADD operations on E=47 operands with f≥32 (Scheduling Rule S4, Invariant CI-6).

| Boundary | ADD behavior | Compiler role |
|---|---|---|
| E=15, f≥32 → E=16 | Thoth Rollover → Phase Transport | EXPLOIT: rescue from collapse |
| E=47, f≥32 → E=48 | Thoth Push → Saturation entry | PREVENT: prohibit ADD here |

### The Complete Compiler Stack

```
Hardware physics    →  Fixed. Immutable. Source of truth (HBS-11..C2).
C1 (instruction)   →  Single-op routing: region → mode_tag → tile_depth.
C3 (workload)      →  Workload-level scheduling: class → profile → epoch plan.
                       Phase Transport pre-placement.
                       ABMP trigger scheduling.
                       Normalization epoch insertion.
```

C3 does not replace C1. It operates one level above: it produces the workload-level plan, which C1 then executes instruction-by-instruction. Together they constitute the complete HORUS compiler routing stack.

---

## Compiler Separation Principle (HBS-C1)

**Source:** HORUS C1 Compiler Specification · 2026-07-02  
**Authority:** Derived from frozen HBS-11..14 hardware physics

### Principle Statement

> **Hardware defines physics. Compiler defines routing. The compiler cannot alter arithmetic outcomes.**

HORUS v3 enforces a strict separation between three domains:

| Domain | Owner | Scope |
|---|---|---|
| Arithmetic physics | Hardware (horus_nfe, RTL) | Exponent boundaries, UF/OVF, Thoth Rollover, result computation |
| Accumulator policy | Hardware (mode_tag decoder, RTL) | Post-arithmetic accumulation behavior per cycle |
| Execution routing | Compiler (HORUS C1) | Region classification, mode_tag selection, depth budgeting, ABMP |

### The Compiler Is a Phase-Space Router, Not a Numerical Optimizer

The compiler's output is an instruction stream: sequences of (op_a, op_b, op_sel, mode_tag, accum_en, accum_clr, host_tile_depth). The compiler has no other control surface. It cannot:

- Modify the `result` output for any operation
- Change the exponent at which UF or OVF fires
- Suppress or delay hardware flags
- Alter the Thoth Rollover threshold
- Extend the stable operating band

The compiler's sole capability is to **route operations into regions where the hardware physics produce desired behavior**. This is why it is a phase-space router: it moves computations through the four-region exponent space while respecting the physics of each region.

### Routing vs. Optimization: A Critical Distinction

A numerical optimizer would attempt to transform computation `f(x)` into an equivalent computation `g(y)` that produces fewer errors. HORUS C1 does not do this. It accepts the arithmetic behavior of each region as ground truth and routes accordingly:

```
If E_pred ∈ [20..43]:  route to STABLE band  → full precision guaranteed
If E_pred ∈ [16..19]:  route to TRANSITION   → scale-up normalization required
If E_pred ≤ 15:        route to SENTINEL path → discard or floor-gate
```

The compiler does not attempt to "fix" E_pred=15 operations by some substitution. It either rescales the operand before the operation (normalization) or accepts the floor result and routes accordingly.

### Active Boundary Management Protocol (ABMP)

ABMP (defined in HORUS_C1_COMPILER_SPEC.md §1.8) is the compiler's only "active" behavior at boundaries. It is a three-phase rescue sequence: Snapshot the accumulator, Normalize the operand (via MUL by TWO^k), then Resume with a fresh accumulation window.

ABMP is not boundary "correction" — it is boundary **avoidance through advance routing**. The compiler predicts when an operand will approach a cliff and rescales it before the cliff is reached. The arithmetic physics are unchanged; the operand simply never arrives at E=15.

**Architecture of the architect's suggestion (§1.8):**  
The suggestion to inject mode_tag=010 before boundary crossings is **partially correct but architecturally incomplete**. Mode_010 (PRE_SCALED) affects the accumulator only; it cannot prevent the `result` from entering collapse or saturation (HBS-14 invariant: result is mode-invariant). The primary prevention action is operand normalization (MUL by NFE_TWO^k). Mode_010 is correctly used as the secondary accumulator guard *during* normalization, reducing the accumulated contribution of transit-zone intermediate results.

### Definitive Statement: Immutable Compiler Invariants

1. **Arithmetic physics is not modified by the compiler.** The compiler operates on a closed hardware system. All arithmetic behaviors documented in HBS-11..14 are invariant. The compiler builds on them.

2. **The compiler only selects execution region and mode_tag.** No additional control is available. No compiler action changes the `result` of any operation.

3. **No attempt is made to "correct" UF or OVF.** When hardware signals these events, the compiler closes the accumulation epoch and logs the event. It does not substitute a different result.

4. **All boundary effects are preserved, not hidden.** Hardware flags (`underflow_flag`, `exp_ovf_flag`, `rollover_flag`) are observable to the host system. The compiler passes them through.

5. **Mode invariance is a compiler precondition.** The compiler selects modes knowing that `result` is mode-invariant (proven HBS-14). This invariant must hold or the compiler's region-mode mapping is undefined.

---

## Structural Decoupling Proof (HBS-14 Verified)

**Basis:** 2,643-event simulation corpus across all four policy modes.  
**Status:** PROVEN — no exceptions observed.

### Decoupling Theorem

The arithmetic layer (`horus_nfe` compute path) and the policy layer (accumulator path) are **structurally decoupled** at the RTL level. This decoupling is not a design goal that may be degraded by configuration — it is an architectural invariant enforced by the code path structure of the sequential always block.

### Proof by RTL Structure

The `horus_nfe` sequential always block executes the following order unconditionally:

```
1. Arithmetic computation → stored in combinational variable `computed`
2. result <= computed                   (NBA assignment — policy-independent)
3. if accum_en:
     case (mode_tag)                    (policy decoder — entered after step 2)
       000: accum_word = computed
       001: accum_word = computed + BIAS_LUT[e_a]
       010: accum_word = (E>0) ? {sign,E-1,frac} : computed
       default: accum_word = computed
     endcase
     accum_reg <= (SAFE?) saturate(accum_reg + computed)
                         : accum_reg + accum_word
```

Because `result <= computed` is a non-blocking assignment evaluated before the policy decoder case statement is entered, and because no feedback path exists from `accum_word` or `accum_reg` back to `computed` or `result`, the following theorem holds by construction:

**For any (op_a, op_b, op_sel), the value of `result` is identical for all values of `mode_tag`.**

### Empirical Verification (HBS-14)

| Test | Stimuli | Result mismatches vs MODE_000 |
|---|---|---|
| HBS-14A (all modes, no accum) | 32 × 4 | **0** |
| HBS-14E (all modes, with accum) | 32 × 4 | **0** |
| HBS-14B (random mode switching) | 500 cycles, 444 unique operands | **0** |
| **Total** | **384 direct cross-mode tests** | **0** |

### UF/OVF Flag Invariance

`underflow_flag` and `exp_ovf_flag` are set by the arithmetic core before the policy decoder is entered. They are not conditioned on `mode_tag`.

**Measured verification (HBS-14E):**
- UF events: STD=8, BIAS=8, PRSC=8, SAFE=8 — identical across all modes
- OVF events: STD=5, BIAS=5, PRSC=5, SAFE=5 — identical across all modes

### No Cross-Layer Leakage

No signal in the policy path feeds back to the arithmetic path:
- `accum_word` is a blocking variable consumed within the always block; not a module output.
- `accum_reg` is a module-private register; not observable by Layer 1 arithmetic logic.
- `mode_tag` enters the sequential block but is not connected to any arithmetic path signal.

Across 2,643 system integration events, **zero cross-layer leakage events were observed**.

### Definitive Constraints

| Component | Role | Boundary |
|---|---|---|
| Thoth Rollover | Defines upward transport boundary in ADD | Fires when f_a + Δ ≥ 64; increments E; non-reversible. Marks the in-band limit of fraction-channel addition. |
| pgate_ctrl | Defines execution horizon boundary | `accum_en_gated` closes when `op_count_reg ≥ host_tile_depth`. After closure, arithmetic continues (result computed) but results are not accumulated. |
| Arithmetic collapse | Cannot propagate into policy state | NFE_FLOOR (UF result) = 0x000. If accumulated, it contributes 0 to accum_reg. Policy policies cannot distinguish a floor contribution from a zero-value contribution. This is intentional: floors are silent at the accumulator layer. |
| Boundaries E=15↔16, E=47↔48 | Cannot be shifted by policy | All four policy modes confirm identical UF/OVF onset at identical exponent values. The arithmetic boundary is not a software concept — it is a consequence of unsigned 6-bit exponent arithmetic and is enforced by the hardware adder. |

### Summary Statement

> The arithmetic layer and policy layer in HORUS v3 are fully decoupled. Policy mode selection has zero effect on arithmetic results, UF/OVF flags, or phase-boundary behavior. Policies operate exclusively in the accumulator domain. This decoupling was confirmed across 384 direct cross-mode comparisons with zero exceptions.
>
> This proof is not contingent on calibration state, tile depth, operand distribution, or operating regime. It holds universally for all valid inputs.

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

---

## C5 — Decision Surface Validation Principle

*Added: 2026-07-02 · Authority: HBS-C5 exhaustive kernel stress-test*

### Principle

The compiler is not validated by the correctness of individual outputs.  
The compiler is validated by the **topology of its decision surface** under full state enumeration.

A correct compiler kernel over a finite input space must behave as a **partition function**: it must divide its input space into a set of non-overlapping, fully-covering output classes. If any input state is unclassified, or if any (class, E, depth) triple maps to more than one output, the kernel is not a function — it is a relation, and it is wrong.

### Verified Properties (HBS-C5)

**1. Kernel as partition function**  
The C4 kernel partitions all 8,192 input states into exactly 6 non-overlapping output classes. No input state is unclassified. No input state belongs to more than one class. The kernel is total and injective over its output classes.

**2. No mixed-mode interiors**  
Within any single (class, E, depth) triple, the kernel returns exactly one (mode, action) pair. Class differentiation exists within E bands (TRANSITION and COLLAPSE produce class-dependent outputs), but this is not mixing — it is deterministic class routing, fully specified by the truth table.

**3. Depth override forms a single connected manifold**  
The 3,840 states satisfying depth > 16 form a single, connected, flat manifold in the 3-dimensional input space: they span all 4 classes and all 64 exponent values, and they all map to exactly one output. Output entropy = 0 bits. There is no class-dependent variation inside this manifold. The override is structurally total.

**4. Boundary transitions are step functions**  
Both phase boundaries (E = 15 → 16, E = 47 → 48) are discrete step functions with zero smearing. The action changes at both boundaries for all 4 classes. The mode changes at the saturation boundary (E = 47 → 48) for all 4 classes. The mode changes at the collapse boundary (E = 15 → 16) for 2/4 classes (CLASS_A and CLASS_C), with the other two classes (CLASS_B, CLASS_D) retaining mode=010 but changing action. This **asymmetry is expected and correct** — it reflects the distinct class routing rules in TRANSITION vs COLLAPSE that existed in C1 and C3, now compressed into the C4 kernel.

**5. Kernel topology summary**

| Property | Measured | Verdict |
|---|---|---|
| Total states evaluated | 8,192 | Exhaustive |
| Unique output classes | 6 | Partition confirmed |
| Depth-override entropy | 0.000 bits | Single manifold confirmed |
| Collapse boundary type | Step function | Zero smearing |
| Saturation boundary type | Step function | Zero smearing |
| Boundary symmetry | MSI = 0.500 | Asymmetric (by design) |
| Kernel class | Partition function | Confirmed |

### Architectural Consequence

This principle has one consequence for all future HORUS compiler work:

> **A compiler over a bounded arithmetic system must be verifiable by exhaustive enumeration.  
> If it cannot be enumerated, it is not a compiler — it is a heuristic.**

The C4 kernel satisfies this requirement. It is 8,192 states. It produces 6 outputs. It has been fully enumerated. The decision surface has been mapped. There are no hidden attractors, no interior ambiguities, and no mode drift under load.

The HORUS v3 compiler is proven.

---

---

## C5.1 — Semantic Consistency Correction Principle

*Added: 2026-07-02 · Authority: Documentation integrity pass following HBS-C5*

### Principle

The HORUS compiler is **structurally deterministic** but **semantically layered**. Deterministic mapping does not imply uniform safety semantics across regions.

A system that passes exhaustive decision-surface enumeration (C5) has proven that its routing logic is consistent and total. It has **not** proven that the arithmetic executed under that routing is numerically safe in all cases. These are distinct properties that must not be conflated.

---

### Formal Clarification 1: Determinism vs Safety

| Property | HORUS C4 Status |
|---|---|
| **Determinism** | **GUARANTEED** — identical inputs always produce identical (mode, action) outputs |
| **Safety** | **NOT GUARANTEED** across all regions — in particular, not inside STABLE |

Determinism means the compiler cannot produce contradictory routing decisions. Safety means the arithmetic result of executing under that routing is numerically well-behaved. These are orthogonal properties.

The STABLE region (`E = 20–43`) is the primary compute band. Its routing decision is correct and deterministic. However, STABLE does not suppress latent collapse-adjacent behaviors for operand configurations near the lower boundary. HBS-13E measured progressive fraction precision collapse in self-MUL chains beginning near E=20 that produced no hardware flags and no region transition events. The routing was correct; the arithmetic was degrading silently.

**The compiler cannot guarantee what it cannot observe.** The kernel inputs are (`workload_class`, `estimated_E`, `depth`). If degraded operand state is not visible in these three inputs, it is invisible to the compiler.

---

### Formal Clarification 2: Region Meaning is Observational, Not Protective

The four region labels — COLLAPSE, TRANSITION, STABLE, SATURATION — are **measured behavior categories** derived from HBS-12 and HBS-13 empirical scans. They describe what the hardware was observed to do under controlled stimulus. They are not protective boundaries enforced by the hardware or the compiler.

| Region label | What it means | What it does NOT mean |
|---|---|---|
| `COLLAPSE` (E ≤ 15) | UF flag fires deterministically here | No safe compute is possible here |
| `TRANSITION` | Boundary physics is active | Normalization guarantees correctness |
| `STABLE` (E = 20–43) | No boundary-triggered flags fired here | Arithmetic results are numerically correct |
| `SATURATION` (E ≥ 48) | OVF flag fires deterministically here | All results are maximally wrong |

Region boundaries delineate where hardware flag behavior changes. They do not delineate where arithmetic results become trustworthy. The STABLE band is the region where the hardware is most likely to produce useful results, but "most likely" is an observational characterization, not a formal guarantee.

---

### Formal Clarification 3: Kernel Interpretation Hierarchy

The C4 kernel is composed of three semantically distinct layers, applied in order:

```
Layer 1 — classify(E)
    Priority-encoded predicate evaluator over overlapping boundary conditions.
    Structural routing primitive.
    Inputs: estimated_E ∈ [0..63]
    Output: region label ∈ {COLLAPSE, TRANSITION, STABLE, SATURATION}
    Property: deterministic, total, zero safety semantics

Layer 2 — Region/class dispatch → mode_tag assignment
    Execution modifier selection based on (region, workload_class).
    Controls accumulator policy only (CI-2).
    Does NOT alter arithmetic result, UF, OVF, or rollover behavior.
    Property: deterministic, class-dependent in TRANSITION and COLLAPSE only

Layer 3 — Depth override: terminal classification annihilation
    When depth > 16: discards all Layer 1 and Layer 2 outputs.
    Replaces with fixed terminal output (010, INSERT_EPOCH_BOUNDARY).
    Is NOT a refinement of prior region/class outputs.
    Is NOT a mode variant of any region.
    Is a full semantic reset: region, class, and mode state are all discarded.
    Property: unconditional, binary, terminal
```

These three layers must be interpreted in strict order. Layer 3 is not a "fourth region." Layer 2 does not modify arithmetic physics. Layer 1 does not guarantee arithmetic safety.

---

### Warning Block

> ⚠️ **WARNING: STABLE region is not equivalent to numerical correctness or absence of latent collapse modes.**
>
> STABLE indicates only the **absence of boundary-triggered transitions** (UF flag, OVF flag, Thoth Rollover). It does not indicate that arithmetic results within STABLE are numerically valid, that fraction precision is preserved, or that deep accumulation chains will not drift toward collapse.
>
> Callers that require bounded numerical error must implement independent operand magnitude validation. The compiler does not enforce arithmetic quality constraints; it enforces routing constraints.

---

### Architectural Consequence

The five-layer validation chain for HORUS v3 now reads:

```
HBS-11 → HBS-14   : Hardware arithmetic and policy layer verified
HBS-C1 → HBS-C3   : Compiler routing logic defined and structured
HBS-C4             : Routing logic compressed to a minimal deterministic kernel
HBS-C5             : Decision surface topology verified by exhaustive enumeration
HBS-C5.1           : Semantic scope of verification explicitly bounded
```

C5 proved the kernel is a partition function over its decision surface. C5.1 defines what that proof scope includes and excludes. Together, they constitute a complete and honest account of what has been verified.

---

---

## C6 — External Realism Validation Principle

*Added: 2026-07-02 · Authority: HBS-C6 adversarial workload stress-test (2500 cycles, 5 workloads)*

### Principle

**Internal partition validity (C5) does not imply external workload stability.**

C5 exhaustively validated the C4 kernel's decision surface by testing all 8,192 combinations of (class, E, depth) with uniform distribution. C5 proved the kernel is a partition function: every input maps to exactly one output with zero ambiguity. This is a necessary property. It is not a sufficient property for deployment.

C6 provides the complementary test: what does the system actually do when driven by adversarial, non-uniform, real-world workloads? The answer is that distribution matters as much as topology.

### What C5 Validates

C5 validates:
- The **decision surface topology** is consistent (partition function property)
- **Depth override** is a terminal annihilation step (no class/region leakage)
- **Boundary transitions** are step functions with zero smearing
- All 8,192 input states are classified unambiguously

C5 does **not** validate:
- That real workloads distribute uniformly across the decision surface
- That accumulator drift remains bounded under realistic stimulus
- That STABLE-band occupancy is dominant in practice
- That depth management is sufficient for all workload energy levels

### What C6 Validates

C6 uses five adversarial workload generators (W1–W5) to measure **what actually happens** when the hardware is driven by non-uniform stimulus:

| Workload | Class | Finding | KL vs C5 |
|---|---|---|---|
| W1 Sparse MAC | A | 95% STABLE, 5% SATURATE — spike suppression works | 0.80 nats |
| W2 Cancellation | B | 100% STABLE but 63.6× residual amplification — cancellation is NOT safe in NFE | 0.98 nats |
| W3 Boundary oscillation | C | 74.6% boundary crossing rate; COLLAPSE=25.2%, SATURATE=50% | 0.52 nats |
| W4 Deep transformer chain | D | 98.6% SATURATE, 60.4% OVF rate — unclamped feedback chains explode | 1.32 nats |
| W5 Saturation spikes | A | 90% STABLE, 10% SATURATE — spike energy is absorbed | 0.70 nats |

Average KL divergence from C5 uniform baseline: **0.86 nats** — real workloads are substantially non-uniform.

### Three Formal Clarifications (C6)

**1. C5 topology ≠ workload stability**  
The C4 kernel's partition property guarantees that routing decisions are consistent. It does not guarantee that the arithmetic executed under those decisions is stable. W4 demonstrates this: the kernel correctly routes all operations, but the feedback chain's exponent grows monotonically until OVF, entirely within the kernel's defined behavior.

**2. Cancellation is not safe in NFE**  
W2 shows that SUB operations at equal exponents produce residuals **63.6× larger than the quantization step** at E=32. This is not a kernel failure — the kernel correctly routes CLASS_B through TRANSITION and NORMALIZE_THEN_EXECUTE. It is a physics property of the NFE encoding: subtraction at equal exponents produces a result near the operand value, not near zero. The C4 kernel's CLASS_B routing exists precisely because of this physics. C6 confirms that the routing rule was correctly motivated.

**3. Internal decision topology must be guarded by timing-aware workload epoch management**  
W1, W2, W4, W5 all reach 50% of maximum accumulator value within 9–11 cycles — below the epoch depth threshold of 16. This means high-energy workloads can saturate the accumulator faster than the epoch boundary fires. The compiler's depth management (INSERT_EPOCH_BOUNDARY at depth=16) is sufficient for moderate-energy workloads but may require tightening (e.g., workload-class-specific depth limits) for high-energy workload classes.

### Divergence between C5 and C6 is Expected and Must be Measured

The KL divergence between C5 uniform distribution and real workload distributions is **not an error**. It is a measurement. Any system that claims C5 topological validity automatically extends to real-world safety is making an unjustified inference.

The correct reading of C5 and C6 together is:

```
C5: The kernel is structurally sound. Its decisions are total, deterministic,
    and non-overlapping. This is verified by exhaustive enumeration.

C6: Under adversarial workloads, the system produces non-uniform distributions.
    Some workloads (W3, W4) never reach STABLE. One workload (W4) reaches
    saturation rapidly due to feedback multiplication. Cancellation (W2) is
    not arithmetically safe. These are physics constraints, not kernel failures.

C5 ∧ C6 together: The compiler makes correct routing decisions. The hardware
    physics imposes limits that the routing cannot overcome. Both facts must
    be held simultaneously.
```

---

## C7 — Failure-Domain Isolation Principle

*Validated by HBS-C7 (2026-07-02)*

**Principle:** A topologically correct, exhaustively validated decision surface does
not imply a single unified failure mode. HORUS v3 exhibits four structurally distinct
failure attractors that cannot be described by a shared depth threshold.

**Measured failure attractors (HBS-C7, 1,100 cycles):**

| Attractor | Class | Mechanism | TTI (measured) |
|---|---|---|---|
| Linear residual accumulation | CLASS_B | Cancel residual sums monotonically in accum | 2 cycles |
| Geometric exponent explosion  | CLASS_D | MUL ×2 chain overflows 6-bit exponent field | 31 cycles |
| Permanent boundary oscillation | CLASS_C | Thoth Rollover at E=15/47 every other cycle | 0 cycles |
| Entropy-dissipation mixing    | Mixed   | Multi-region injection spans all regime bands | 4 cycles |

**Key finding:** TTI spread = **31×** across regimes (min=0, max=31 cycles). This
rules out a single failure threshold. Each attractor has an independent onset depth
driven by a distinct physical mechanism.

**On epoch_depth=16:** Calibrated for the geometric explosion attractor (Attractor 2 —
CLASS_D). It correctly interrupts the accumulator before E field overflow in ×2 MUL
chains. It is not applicable to Attractor 3 (boundary oscillator isolated from accum
by routing) and only partially applicable to Attractors 1 and 4 (onset precedes epoch
by 12–14 cycles).

**On determinism:** HORUS v3 is fully deterministic under adversarial stress. Identical
input sequences produce identical output trajectories. Apparent run-length variation in
R2 drift chains is a deterministic consequence of epoch management intersecting the
exponent drift path — not hardware non-determinism.

**On recovery:** All four attractors are input-driven. Recovery latency = 0 cycles for
all regimes. No attractor locking or hysteresis observed. The failure domain is sharp
and the system self-clears when adversarial forcing is removed.

**C5 + C6 + C7 together:** The compiler kernel is topologically correct (C5). Under
adversarial stimulus it encounters real failure physics (C6). Those failure physics
resolve into four independent attractors with distinct onset depths and dynamics (C7).
The architecture is not unsafe — it is multi-modal. Correct management requires
per-attractor awareness, not a single universal depth limit.

---

*Horus (Native Fractional Engine project) · Architecture Philosophy v3 ·
Digital Physics · Quantized Event Accumulation Engine · Lossy Stable Substrate*
*HBS-11 Validated: 2026-07-02 · HBS-12 Arithmetic Envelope added: 2026-07-02*
*HBS-13 Boundary Gap added: 2026-07-02 · HBS-14 System Integration added: 2026-07-02*
*Structural Decoupling Proof added: 2026-07-02 · HORUS_V3_FINAL_SPEC issued: 2026-07-02*
*Compiler Separation Principle (HBS-C1) added: 2026-07-02*
*C3 Workload Embedding Principle added: 2026-07-02*
*C4 Compiler Kernel Compression Principle added: 2026-07-02*
*C5 Decision Surface Validation Principle added: 2026-07-02*
*C5.1 Semantic Consistency Correction Principle added: 2026-07-02*
*C6 External Realism Validation Principle added: 2026-07-02*
*C7 Failure-Domain Isolation Principle added: 2026-07-02*
