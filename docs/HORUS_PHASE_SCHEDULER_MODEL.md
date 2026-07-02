# HORUS v3 Phase Scheduler Model

**Document type:** Conceptual Architecture Model — Workload Embedding + Phase Scheduling  
**Authority:** C3 Workload Embedding Specification · HBS-11 through HBS-C2  
**Version:** 1.0 · 2026-07-02  

---

## 1. Workload → Region Distribution

This diagram shows how a workload graph passes through the C3 embedding layer before any hardware instructions are emitted.

```
╔═══════════════════════════════════════════════════════════════════════╗
║  C3 WORKLOAD EMBEDDING PIPELINE                                       ║
╠═══════════════════════════════════════════════════════════════════════╣
║                                                                       ║
║  HIGH-LEVEL WORKLOAD GRAPH                                            ║
║  (matrix multiply, residual, layer norm, multi-layer pipeline)        ║
║                     │                                                 ║
║                     ▼                                                 ║
║  ┌─────────────────────────────────────────────────────────────────┐  ║
║  │  WORKLOAD CLASSIFIER                                            │  ║
║  │  Determine workload class:                                      │  ║
║  │    CLASS_A — MAC dominant     CLASS_C — Scaling/norm           │  ║
║  │    CLASS_B — Cancel-heavy     CLASS_D — Deep composition       │  ║
║  └──────────────────────────────────┬──────────────────────────────┘  ║
║                                     │                                 ║
║                                     ▼                                 ║
║  ┌─────────────────────────────────────────────────────────────────┐  ║
║  │  PHASE EMBEDDING ANALYZER                                       │  ║
║  │  Given: E_seed, workload depth, class                          │  ║
║  │  Output:                                                        │  ║
║  │    region_distribution  = {%Stable, %Transition, %Collapse,    │  ║
║  │                             %Saturation}                        │  ║
║  │    dominant_region                                              │  ║
║  │    risk_classification  = LOW / MEDIUM / HIGH                  │  ║
║  │    epoch_structure      = [(start, end, E_seed, depth_max)]    │  ║
║  │    abmp_pre_placements  = [(cycle, type, condition)]           │  ║
║  └──────────────────────────────────┬──────────────────────────────┘  ║
║                                     │                                 ║
║                                     ▼                                 ║
║  ┌─────────────────────────────────────────────────────────────────┐  ║
║  │  SCHEDULING POLICY GENERATOR                                    │  ║
║  │  Apply Rules S1–S4 + Mode Assignment Table (§1.4, §1.5 C3)    │  ║
║  │  Output:                                                        │  ║
║  │    mode_tag_plan[]      — per-epoch mode assignment            │  ║
║  │    tile_depth_plan[]    — per-epoch host_tile_depth            │  ║
║  │    normalization_points[]                                       │  ║
║  │    transport_points[]   — Phase Transport pre-placements       │  ║
║  └──────────────────────────────────┬──────────────────────────────┘  ║
║                                     │                                 ║
║                                     ▼                                 ║
║  ┌─────────────────────────────────────────────────────────────────┐  ║
║  │  C1 INSTRUCTION EMITTER  (from HORUS_C1_COMPILER_SPEC.md)      │  ║
║  │  Per-operation dispatch using:                                  │  ║
║  │    classify_region(E_pred)                                      │  ║
║  │    select_mode(region, class, depth)                           │  ║
║  │    ABMP if hazard detected                                      │  ║
║  └──────────────────────────────────┬──────────────────────────────┘  ║
║                                     │                                 ║
║                                     ▼                                 ║
║  horus_system hardware instruction stream                             ║
║  (op_a, op_b, op_sel, mode_tag, accum_en, accum_clr, tile_depth)     ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
```

---

## 2. CLASS_A Flow Diagram (MAC-Dominant)

```
CLASS_A WORKLOAD (matrix multiply, conv, attention)
─────────────────────────────────────────────────────

  Entry
    │
    ├── Check E_seed
    │     E_seed ≥ 24? ────── YES ──► STABLE routing
    │     E_seed ∈ [20..23]? ─ YES ──► MEDIUM risk; depth_max ≤ 7
    │     E_seed < 20? ──────── YES ──► ALERT; misclassified or
    │                                   apply CLASS_C pre-scale first
    │
    ▼
  Compute epoch_depth = min(16, E_seed − 16)
    │
    ▼
  Emit MAC epoch
  ┌──────────────────────────────────────────────┐
  │  for depth in 0..epoch_depth:                │
  │    emit(op_a, op_b, MUL, mode=000,           │
  │          accum_en=1, tile_depth=epoch_depth) │
  │                                              │
  │  if depth == epoch_depth − 2:               │
  │    [optional: ABMP early warning]            │
  └───────────────────────┬──────────────────────┘
                          │ epoch complete
                          ▼
  SNAPSHOT (read accum_out)
  accum_clr pulse
                          │
    ┌─────────────────────┴──────────────────────┐
    │ More epochs?                               │
    │   YES ──► reset E_seed if drifted          │
    │           → emit CLASS_C normalization     │
    │           → repeat epoch                  │
    │   NO  ──► done                            │
    └────────────────────────────────────────────┘

  Region profile:  STABLE ~95%  TRANSITION ~5%  COLLAPSE 0%  SATURATION 0%
  Risk:            LOW (if constraints respected)
  mode_tag:        000 throughout
```

---

## 3. CLASS_B Flow Diagram (Cancellation-Heavy)

```
CLASS_B WORKLOAD (residuals, skip connections, normalization corrections)
─────────────────────────────────────────────────────────────────────────

  Entry (two operands: A and neg_B)
    │
    ├── Phase 1: NORMALIZATION
    │   Check both operands' E values:
    │     E_A ≥ 24 and E_B ≥ 24? ──► OK, proceed
    │     E < 24? ──────────────────► scale-up (CLASS_C, mode=010)
    │             (accum_en=0 during scale steps)
    │
    ▼
  Verify: both operands in Stable band (E ≥ 20)
    │
    ├── Phase 2: CANCELLATION EXECUTION
    │   ┌──────────────────────────────────────────────────┐
    │   │  emit(A, B, MUL, mode=000_or_001, accum_en=1)  │
    │   │  emit(A, neg_B, MUL, mode=000_or_001, accum_en=1)│
    │   └─────────────────────────────────────────────────┘
    │   Note: result = MUL(A,B) + MUL(A,−B) ≠ 0 (W01 residual)
    │   W01 residual is indexed by e_a (stored_E of result)
    │
    ▼
  Phase 3: POST-CANCELLATION
    SNAPSHOT (read accum_out — this is the W01-contaminated sum)
    accum_clr
    [log W01 residual for QAT calibration of BIAS_LUT if needed]
    │
    ▼
  DONE

  W01 mitigation path (when BIAS_LUT populated):
    mode = 001 in Phase 2
    → BIAS_LUT[e_a] added to each accum step
    → W01 residual corrected at hardware level

  Region profile:  STABLE ~90%  TRANSITION ~8%  COLLAPSE ~2%  SAT 0%
  Risk:            MEDIUM (W01 residual; BIAS_LUT calibration required)
  mode_tag:        010 (Phase 1) → 000 or 001 (Phase 2)

  PROHIBIT: Cancellation execution in Transition band (E ∈ [16..19])
  PROHIBIT: Cancellation execution in Collapse band (E ≤ 15)
```

---

## 4. CLASS_C Flow Diagram (Scaling / Normalization)

```
CLASS_C WORKLOAD (layer norm, softmax scaling, exponent adjustment)
─────────────────────────────────────────────────────────────────────

  Entry (operand at unknown E)
    │
    ├── Classify input E
    │     E < 0:    IMPOSSIBLE in NFE (unsigned)
    │     E ≤ 15:  COLLAPSE zone → must scale up before handoff
    │     E 16–19: TRANSITION low → scale up to E ≥ 20
    │     E 20–43: STABLE → scale as needed
    │     E 44–47: TRANSITION high → scale down to E ≤ 43
    │     E ≥ 48:  SATURATION → scale down
    │
    ▼
  SCALE STEP LOOP
  ┌──────────────────────────────────────────────────────────────┐
  │  accum_en = 0  (ALL CLASS_C operations: no accumulation)    │
  │                                                             │
  │  Scale UP:   emit(x, NFE_TWO,  MUL, mode=010, accum_en=0) │
  │  Scale DOWN: emit(x, NFE_HALF, MUL, mode=010, accum_en=0) │
  │                                                             │
  │  Repeat until: E reaches destination_E                     │
  │  ASSERT destination_E ∈ [20..43]  (stable hand-off target) │
  └───────────────────────────────┬──────────────────────────────┘
                                  │
                                  ▼
  accum_clr (close any open epoch from previous stage)
  Tag result with destination_E
  Hand off to next CLASS_A/B/D stage
                                  │
                                  ▼
  DONE

  Special case — PRE-SCALE into Collapse (intentional, very rare):
    When target_E < 16 is required (e.g., research / probe):
    Mark as TRANSPORT ONLY; accum_en = 0; no accumulation permitted.
    This does NOT trigger UF (MUL by HALF: E−1, only UF at E=0).

  Region profile:  TRANSITION dominant  STABLE varies  COLLAPSE possible
  Risk:            MEDIUM (by definition: purpose is boundary crossing)
  mode_tag:        010 throughout
  accum_en:        0 throughout (mandatory)
```

---

## 5. CLASS_D Flow Diagram (Deep Composition Chains)

```
CLASS_D WORKLOAD (multi-layer pipelines, recursive accumulation)
─────────────────────────────────────────────────────────────────

  Entry (E_seed=32, total_depth=L)
    │
  Compute:
    epoch_length = min(16, E_seed − 16)    [= 16 for E_seed=32]
    n_epochs     = ceil(L / epoch_length)
    │
    ▼
  FOR each epoch i = 0..n_epochs−1:
    │
    ├── EPOCH START
    │   mode = 000 (depth ≤ 8)
    │   host_tile_depth = epoch_length
    │   │
    │   ▼
    │  FOR depth d = 0..epoch_length:
    │  ┌────────────────────────────────────────────────────────┐
    │  │  d ≤ 8:  emit(op, MUL/ADD/SUB, mode=000, accum_en=1) │
    │  │  d > 8:  emit(op, op_b,        mode=010, accum_en=1) │
    │  │                                                       │
    │  │  E_est drifting (via HALF-chain or composition):      │
    │  │    E_est = E_seed − d  (for HALF-dominant chain)     │
    │  │                                                       │
    │  │  At d = epoch_length − 2  (early warning):           │
    │  │    IF E_est ≤ 19: TRIGGER ABMP                       │
    │  │      → Phase Transport (if E=15, f≥32)               │
    │  │      → Or Scale-Up (MUL by TWO^k)                    │
    │  │      → mode=010 during transport                     │
    │  └────────────────────────────────────────────────────────┘
    │   │
    │   ▼
    │  EPOCH END (depth = epoch_length)
    │    SNAPSHOT (read accum_out)
    │    accum_clr
    │
    ├── INTER-EPOCH NORMALIZATION (CLASS_C)
    │     emit scale-up to return E to E_seed
    │     accum_en = 0 during normalization
    │     accum_clr after normalization
    │
    └── NEXT EPOCH (i + 1)

  DONE when all epochs complete.

  Depth vs. Region Drift (HALF-chain, E_seed=32):
  ┌──────────────────────────────────────────────────────────┐
  │  depth  E_est  Region      mode_tag  Action              │
  │  ─────  ─────  ──────────  ────────  ────────────────── │
  │  0      32     STABLE      000       normal              │
  │  4      28     STABLE      000       normal              │
  │  8      24     STABLE      000       normal              │
  │  9      23     STABLE      010       mode escalate       │
  │  12     20     STABLE      010       normal              │
  │  14     18     TRANSITION  010       early warning       │
  │  14     18     TRANSITION  010       ABMP trigger        │
  │  16     16     TRANSITION  010       ABMP / epoch end    │
  └──────────────────────────────────────────────────────────┘

  Region profile:  STABLE ~75%  TRANSITION ~25%  COLLAPSE 0%  SAT 0%
  Risk:            MEDIUM (with epoch management)
  mode_tag:        000 → 010 progression
```

---

## 6. Mode Tag Decision Tree

```
INPUT: (workload_class, E_pred, depth, BIAS_LUT_status)
     │
     ▼
E_pred ≤ 15? ─ YES ──► COLLAPSE branch
     │ NO
     ▼
E_pred ≥ 48? ─ YES ──► SATURATION branch
     │ NO
     ▼
E_pred ∈ [16..19]? ─ YES ──► TRANSITION_LOW branch
     │ NO
E_pred ∈ [44..47]? ─ YES ──► TRANSITION_HIGH branch
     │ NO
     ▼ [STABLE: E_pred ∈ [20..43]]

STABLE branch:
     │
     ├── class == CLASS_B AND BIAS_LUT_populated?
     │     YES ──► mode = 001 (BIAS)
     │     NO  ──► mode = 000 (STD)
     │
     └── depth > 8 (CLASS_D)?
           YES ──► mode = max(mode, 010)
           NO  ──► keep mode

TRANSITION_LOW / TRANSITION_HIGH branch:
     │
     └── mode = 010 (PRSC)

COLLAPSE branch:
     │
     ├── class in [CLASS_B, CLASS_D]?
     │     YES ──► check ABMP viable (E=15, f≥32)?
     │               YES ──► Phase Transport (§1.7 C3)
     │                         mode = 010 during transport
     │               NO  ──► Scale-Up normalization
     │                         mode = 010 during scale
     │
     └── class in [CLASS_A, CLASS_C]?
           YES ──► skip / accum_en = 0 (do not accumulate floor contributions)

SATURATION branch:
     │
     ├── class in [CLASS_A, CLASS_C]?
     │     YES ──► scale down to E ∈ [20..43] first (CLASS_C rules)
     │               mode = 010 during scale-down
     │               Then re-enter STABLE branch
     │
     └── ceiling use case (count saturated events)?
           YES ──► mode = 011 (SAFE) for accum

FINAL mode_tag OUTPUT:
  000 → primary stable compute
  001 → cancellation correction (only with populated BIAS_LUT)
  010 → transit policy (boundary, normalization, transport)
  011 → safe accumulation (saturation or collapse sentinel)
```

---

## 7. Boundary Handling Flow

```
BOUNDARY APPROACH DETECTION
(fired when E_pred ≤ 19 or E_pred ≥ 44)
────────────────────────────────────────

  E_pred ∈ [16..19]? ──► COLLAPSE APPROACH
  ─────────────────────────────────────────
       │
       ├── Depth approaching limit? (depth ≥ epoch_len − 2)
       │     YES ──► ABMP TRIGGER
       │               │
       │               ├── Phase Transport viable? (E=15, f≥32)
       │               │     YES ──► ADD rescue (E→16) + 4× MUL×TWO (E→20)
       │               │             mode=010 throughout; accum_en=0
       │               │             Record TRANSPORT_EVENT
       │               │             Resume at E=20, fresh accum window
       │               │
       │               └── NOT viable (f<32) ──► Direct Scale-Up
       │                     MUL(x, NFE_TWO) × k until E ≥ 20
       │                     mode=010; accum_en=0
       │                     Resume at target_E, fresh accum window
       │
       └── Depth OK but E drifting ──► mode escalate to 010; continue epoch

  E_pred ∈ [44..47]? ──► SATURATION APPROACH
  ────────────────────────────────────────────
       │
       ├── ADD operation planned with f_operand ≥ 32?
       │     YES ──► HAZARD: PROHIBIT this ADD
       │             REPLACE with: MUL(x, NFE_HALF) to scale-down, then ADD
       │             or: restructure the computation to avoid ADD at E=47
       │
       └── MUL operation approaching ceiling?
             YES ──► emit with mode=011 (SAFE)
                     or scale-down to E ≤ 43 first
```

---

## 8. Depth vs. Region Drift

The relationship between chain depth and exponent drift is algebraic, not stochastic. For a HALF-scaling MAC chain starting at E_seed:

```
E(depth) = E_seed − depth   [for pure HALF chain: MUL by NFE_HALF each step]

Drift schedule (E_seed = 32):

Depth  E_est  Region      Risk level   Recommended mode
─────  ─────  ──────────  ───────────  ────────────────
  0    32     STABLE      LOW          000
  4    28     STABLE      LOW          000
  8    24     STABLE      LOW          000
  9    23     STABLE      MEDIUM       010 (escalate)
 12    20     STABLE      MEDIUM       010
 13    19     TRANSITION  MEDIUM       010 + warn
 14    18     TRANSITION  HIGH         010 + ABMP warning
 15    17     TRANSITION  HIGH         010 + ABMP warning
 16    16     TRANSITION  HIGH         ABMP trigger
 17    15     COLLAPSE    CRITICAL     TRANSPORT or RESET
 18    14     COLLAPSE    CRITICAL     TRANSPORT or RESET
 ∞      0     FLOOR       ABSORBING    NFE_FLOOR (info lost)

FORMULA: depth_safe = E_seed − 16   [hard floor attractor boundary]
FORMULA: depth_warn = E_seed − 20   [2-step early warning before cliff]

At E_seed=32: depth_safe = 16,  depth_warn = 12
At E_seed=40: depth_safe = 24,  depth_warn = 20
At E_seed=24: depth_safe =  8,  depth_warn =  4
```

**Drift for mixed chains (ADD+MUL pattern, as in HBS-C2 STREAM_C):**

The HBS-C2 deep chain used an 8-step epoch with 6 HALF + 1 TWO + 1 ADD. The net E drift per 8 steps was approximately −6 (E=32 to E≈14 at depth=24 before reset). This confirms that ADD and TWO operations slow the descent but cannot prevent it without explicit epoch management.

---

## 9. Boundary Physics vs. Compiler Intent

This section explains how the compiler harnesses boundary physics for intentional phase transport, rather than treating boundaries purely as obstacles.

### The Two Boundary Physics

HORUS v3 has two phase boundaries, both arising from the same mechanism (Thoth Rollover: f + f ≥ 64 → E + 1) but with opposite compiler implications:

```
COLLAPSE BOUNDARY (E = 15 ↔ 16)
────────────────────────────────
Physical behavior: ADD(x, x) where f ≥ 32
  E = 15, f = 32 → E = 16, f =  0   (rollover: result crosses into TRANSITION)
  E = 15, f = 63 → E = 16, f = 31   (rollover: result crosses into TRANSITION)
  E = 15, f < 32 → E = 15 (stays)   (no rollover)

Compiler interpretation: RESCUE MECHANISM
  50% of E=15 codewords (those with f ≥ 32) can be transported
  to E=16 by a single ADD(x, x) instruction.
  This is Phase Transport — intentional boundary crossing
  in the direction of the stable zone.
  
  The compiler EXPLOITS this boundary physics.
  A codeword at E=15, f=32 is not "broken" — it is one ADD
  instruction away from the stable zone.

SATURATION BOUNDARY (E = 47 ↔ 48)
────────────────────────────────────
Physical behavior: ADD(x, x) where f ≥ 32
  E = 47, f = 32 → E = 48 → OVF    (rollover: pushes into saturation)
  E = 47, f = 63 → E = 48 → OVF    (rollover: pushes into saturation)
  E = 47, f < 32 → E = 47 (stays)  (no rollover)

Compiler interpretation: HAZARD
  The mirror physics of the ADD rescue are a hazard at the saturation
  boundary. ADD(x, x) at E=47 with f ≥ 32 pushes into saturation.
  
  The compiler PREVENTS this boundary crossing.
  A workload near E=47 must avoid ADD operations with f ≥ 32 operands,
  and must use MUL(x, NFE_HALF) to scale down instead.
```

### Why the Asymmetry Matters

The two boundaries are physically identical — both are Thoth Rollover events. But their **compiler semantics are opposite**:

| | Collapse boundary (E=15) | Saturation boundary (E=47) |
|---|---|---|
| ADD with f≥32 | Rescue (→ stable direction) | Hazard (→ away from stable) |
| ADD with f<32 | No crossing (stays in collapse) | No crossing (stays near saturation) |
| Compiler role | EXPLOIT for Phase Transport | PREVENT at all costs |
| Cost if ignored | Missed rescue opportunity | Saturation entry (accum distortion) |

This asymmetry is exploitable precisely because it is **deterministic**. The viability check (f≥32) is computable from the current operand state. The compiler does not need to run the operation to know whether Phase Transport will succeed.

### Formal Definition: Phase Transport as Architectural Feature

```
Phase Transport is defined as the intentional compiler-directed use of
the hardware's Thoth Rollover property to move a codeword from the
Collapse routing zone to the Transition zone in a single operation,
followed by normalization to the Stable zone.

Properties:
  1. DETERMINISTIC: viability = (E == 15) AND (f >= 32). Always true or false.
  2. LOSSLESS (partial): fraction information is modified (f' = 2*(f−32))
     but not destroyed. The resulting f' ∈ [0..62] is a valid fraction.
  3. HARDWARE-NATIVE: uses only ADD operation; no new control signals.
  4. ONE-WAY: transport direction is toward stable zone only.
  5. NOT FASTER than direct scale-up (both take 5 instructions to reach E=20),
     but produces a DIFFERENT fraction trajectory — useful when fraction
     diversity matters (e.g., avoiding f=0 degenerate states).

Phase Transport is NOT:
  - A workaround for hardware bugs (ADD rescue is correct Thoth Rollover)
  - A probabilistic operation (viability is deterministic)
  - A replacement for ABMP normalization (it is one path within ABMP)
  - Available at E ≤ 14 (only works at exactly E=15)
```

### Harnessing Boundary Physics: The Compiler Philosophy

The HORUS architecture philosophy (§2) states: "Hardware defines physics. Compiler defines routing." Phase Transport is the clearest expression of this principle:

- The **hardware** provides a deterministic rollover property (Thoth Rollover at f≥32).
- The **compiler** classifies this property as a rescue mechanism at E=15 and a hazard at E=47.
- The **routing layer** exploits the rescue and prevents the hazard — without changing any hardware behavior.

This is the architecture principle in action: the compiler derives power not from modifying hardware physics, but from knowing the physics precisely and routing operations to use them intentionally.

```
"What the hardware does is fixed. What the compiler does with it is the design."
```

---

## 10. Complete Scheduling Decision Matrix

| Class | E range | Depth | mode_tag | accum_en | ABMP | Notes |
|---|---|---|---|---|---|---|
| A | 20–43 | ≤ 16 | 000 | 1 | No | Reference case |
| A | 16–19 | ≤ 4 | 010 | 1 | Warn | Low headroom |
| A | < 20 | any | — | — | Required | Reclassify or pre-scale |
| B | 20–43 | 2 | 000/001 | 1 | No | Cancellation pair |
| B | 16–19 | any | — | — | Required | Scale-up first (Rule S2) |
| B | ≤ 15 | any | PT or 010 | 0→1 | Yes | Phase Transport if viable |
| C | any | 1–4 | 010 | **0** | If E<16 | No accumulation ever |
| D | 20–43 | ≤ 8 | 000 | 1 | No | Normal |
| D | 20–43 | 9–16 | 010 | 1 | At d=14 | Mode escalated |
| D | 16–19 | any | 010 | 1 | Yes | Epoch end triggered |
| D | ≤ 15 | any | PT or scale | 0→1 | Yes | Epoch reset |
| All | ≥ 48 | any | 011 | 0 | Yes (scale-down) | Ceiling region |

---

## Related Documents

| Document | Relationship |
|---|---|
| `docs/HORUS_C3_WORKLOAD_EMBEDDING.md` | Full C3 spec; pseudocode source for this visual model |
| `docs/HORUS_C1_COMPILER_SPEC.md` | Instruction-level routing; ABMP protocol (§1.8) |
| `docs/HORUS_SYSTEM_COMPILATION_MODEL.md` | Layer separation; interface contract; full pipeline |
| `docs/HORUS_BOUNDARY_GAP_ANALYSIS.md` | Phase Transport physics origin (HBS-13A) |
| `docs/HORUS_C2_LIVE_SYSTEM_REPORT.md` | Measured occupancy; depth vs. drift validation |
| `docs/ARCHITECTURE_PHILOSOPHY.md` | C3 Workload Embedding Principle (conceptual framing) |
