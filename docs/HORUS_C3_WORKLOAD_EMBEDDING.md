# HORUS C3 Workload Embedding Specification

**Document type:** Compiler Mapping + Scheduling Layer Definition  
**Authority:** HBS-11 through HBS-C2 validated hardware behavior (frozen) · C1 Compiler Spec (frozen)  
**Version:** 1.0 · 2026-07-02  
**Status:** GOLD — No RTL changes. No new simulation. Mapping and scheduling only.

---

## 1.1 Objective

Define a deterministic mapping:

```
Workload graph → HORUS region distribution → mode_tag scheduling policy
```

C3 extends C1 (instruction-level routing) to the **workload graph level**. Where C1 asks "which mode does this single operation need?", C3 asks "what is the expected region distribution profile of this workload, and how should the scheduler be configured before execution begins?"

The output of the C3 layer is a **phase embedding plan**: a deterministic assignment of each workload segment to a region band, with a corresponding mode_tag policy and risk classification. The plan is computed from static analysis of the workload graph using the validated physics from HBS-11..HBS-C2.

**C3 must:**
- Produce deterministic mappings — no probabilistic or adaptive selection
- Use only the four established regions (Stable, Transition, Collapse, Saturation)
- Respect the validated depth limits from HBS-12D and HBS-14
- Treat all arithmetic boundaries as fixed physics, not optimization targets

**C3 must not:**
- Modify RTL, LUTs, or any hardware behavior
- Redefine any arithmetic region boundaries
- Override hardware UF/OVF flags
- Introduce new hardware control signals
- Run new simulation tests to derive mappings

---

## 1.2 Supported Workload Classes

C3 recognizes exactly the four workload classes established in C1. All class definitions are unchanged.

### CLASS_A — MAC-Dominant Workloads

```
Operations:  MUL (primary), ADD (secondary)
Examples:    Matrix multiply, convolution, attention score computation
             Dense layer forward pass, dot-product attention

Characteristics:
  E_seed:    Operand magnitudes typically set at design time.
             Stable-band routing is the default expectation.
  Depth:     Accumulation depth may be large (many MACs per output).
             Requires pgate budget management.
  Volatility: LOW — operand magnitudes are designer-controlled.

Key constraint: depth ≤ E_seed − 16 per epoch (HBS-12D).
  At E_seed=32: max epoch depth = 16.
  Beyond: floor attractor activates deterministically.

Risk default: LOW (if E_seed ≥ 24 and epoch depth ≤ 16)
              MEDIUM (if E_seed ∈ [20..23] or epoch depth ∈ [17..24])
              HIGH (if E_seed < 20 or epoch depth > 24)
```

### CLASS_B — Cancellation-Heavy Workloads

```
Operations:  MUL + ADD/SUB pairs (paired)
Examples:    Residual connections, subtraction chains, normalization corrections
             Skip connections, weight difference computations

Characteristics:
  E_seed:    Pairs operate at the same magnitude band.
  Depth:     Typically shallow (2–4 paired operations).
  Volatility: MEDIUM — cancellation residual (W01) is exponent-dependent,
              structured but non-zero (HBS-9, HBS-11).
  W01 residual: MUL(x, y) + MUL(x, −y) ≠ 0 in NFE domain.
    Residual is indexed by stored_E of result.
    BIAS_LUT[e_a] corrects this when populated (HBS-11A).
    Until calibrated: mode 001 provides zero correction (≡ mode 000).

Key constraint: cancellation pairs MUST operate in Stable band.
  Transition-band cancellation produces larger W01 residuals.
  Collapse-band cancellation is undefined behavior (floor attractor absorbs).

Risk default: LOW (E ∈ [24..43], BIAS_LUT populated)
              MEDIUM (E ∈ [20..23] or BIAS_LUT empty)
              HIGH (E ∈ [16..19] or Transition-band operation)
```

### CLASS_C — Scaling / Normalization Workloads

```
Operations:  MUL by powers of 2 (NFE_HALF, NFE_TWO, NFE_ONE)
Examples:    Layer norm scaling, softmax temperature scaling,
             explicit exponent adjustment, normalization corrections

Characteristics:
  E_seed:    Input may be anywhere. Output E is determined by scale factor.
  Depth:     Typically 1–4 scale steps.
  Volatility: INHERENTLY VOLATILE — purpose is to cross exponent space.
  accum_en:  MUST be 0 during scaling operations (scaling is transport,
              not inference accumulation).

Key constraint: scaling operations must not accumulate.
  The transport result is input to the next computation stage.
  Any accumulation of intermediate transport values contaminates accum.
  If CLASS_C follows CLASS_A in a pipeline: accum_clr before CLASS_C,
  accum_clr again before the next CLASS_A stage.

Risk default: MEDIUM (always — scaling crosses region boundaries by design)
```

### CLASS_D — Deep Composition Chains

```
Operations:  Multi-stage MUL → ADD → SUB graphs
Examples:    Multi-layer inference pipelines, recursive accumulation,
             iterated function application, depth-N transformer stacks

Characteristics:
  E_seed:    Determined by the entry operand of the chain.
  Depth:     L = number of composition layers (may be >> 16).
  Volatility: HIGH if depth > E_seed − 16 without epoch management.
  Information cliff: depth ≥ 32 for E_seed ∈ [28..35] → entropy < 2.59 bits.

Key constraint: MUST partition into epochs.
  Epoch length ≤ min(16, E_seed − 16) (HARD limit from HBS-12D).
  Between epochs: normalization boundary or accum_clr reset.
  If depth > epoch length: insert ABMP (Phase Transport or scale-up).

Risk default: HIGH (unconstrained depth)
              MEDIUM (depth constrained, normalization applied)
              LOW (depth ≤ 8, E_seed ≥ 28)
```

---

## 1.3 Phase Embedding Model (CORE RULE)

Every workload MUST produce a **phase embedding profile** before scheduling begins.

The profile defines the expected distribution of operations across the four regions, the dominant region, and the risk classification. Scheduling decisions (mode_tag, pgate budget, ABMP triggers) are derived from this profile.

### Region Definitions (from HBS-12, HBS-13, HBS-C2 measurements)

| Region | E range | Compiler designation | HBS-C2 global occupancy |
|---|---|---|---|
| Stable | E = 16–47 | Primary compute | 59.3% (measured) |
| Transition | E = 16–19, 44–47 | Scaling boundary zone | 25.1% (measured) |
| Collapse | E = 0–15 | Routing zone / pre-floor | 9.2% (measured) |
| Saturation | E = 48–63 | Ceiling / clamp zone | 6.4% (measured) |

**Critical note from HBS-C2:** The Collapse routing zone (E≤15) is NOT equivalent to hardware `underflow_flag`. Hardware UF requires E_a + E_b < 32 (product exponent < 0). E=12 is a valid codeword — representable, non-negative, but at risk for chain operations. The routing zone designation is a compiler-level caution, not a hardware failure indicator.

### Profile Template

```
PHASE EMBEDDING PROFILE
  Workload:         <name>
  Class:            <A / B / C / D>
  E_seed:           <dominant operand exponent>
  Expected depth:   <N>

  Region distribution:
    Stable      <X>%    (dominant / secondary)
    Transition  <X>%
    Collapse    <X>%
    Saturation  <X>%

  Dominant region:  <Stable / Transition / Collapse / Saturation>
  Risk level:       <LOW / MEDIUM / HIGH>
  mode_tag policy:  <see §1.5>
  Epoch depth:      <computed from E_seed>
  ABMP required:    <YES / NO — and trigger condition>
```

### Standard Profiles by Class

**CLASS_A (E_seed=32, depth≤16):**
```
  Stable 95%  Transition 5%  Collapse 0%  Saturation 0%
  Dominant: STABLE   Risk: LOW   mode: 000   Epoch: 16
```

**CLASS_B (E_seed=32, cancel pairs):**
```
  Stable 90%  Transition 8%  Collapse 2%  Saturation 0%
  Dominant: STABLE   Risk: MEDIUM (W01 active)   mode: 000 or 001
```

**CLASS_C (normalization):**
```
  Stable varies  Transition dominant  Collapse possible  Saturation possible
  Dominant: TRANSITION   Risk: MEDIUM (always crossing)   mode: 010
  accum_en: 0 during all scale steps
```

**CLASS_D (depth=24, E_seed=32):**
```
  Stable 75%  Transition 25%  Collapse 0%  Saturation 0%
  Dominant: STABLE   Risk: MEDIUM   mode: 000→010 at depth>8
  Epoch: 16   ABMP: required if depth > 16
```

---

## 1.4 Deterministic Scheduler Policy

### RULE S1 — Stable-First Mapping (CLASS_A)

```
ALL CLASS_A workloads MUST default to Stable band routing.

  Default mode:       000 (STD)
  Default E_seed:     32 (natural anchor; maximum floor-attractor headroom)
  Epoch depth:        min(16, E_seed − 16) — HARD limit
  Accumulation:       accum_en = 1 throughout epoch
  Mode escalation:    None for depth ≤ 8.
                      010 (PRSC) if CLASS_D deep chain attached.

  Pre-scheduling check:
    ASSERT E_seed ≥ 24  (minimum for depth-8 chains)
    ASSERT E_seed ≤ 47  (not already in Transition-high)
    WARN   E_seed ∈ [24..27]  (depth_max = E_seed − 16 ∈ [8..11])
    ALERT  E_seed ∈ [20..23]  (depth_max ≤ 7; escalate to MEDIUM risk)

  Non-compliance: If incoming operand E < 20, the workload is misclassified
    as CLASS_A. Reclassify or apply Phase Transport (§1.7) before routing.
```

### RULE S2 — Cancellation Routing (CLASS_B)

```
CLASS_B workloads MUST be routed through Transition normalization,
then into the Stable band for the cancellation operation itself.

  Phase 1 — Normalization:
    Scale-up the operand to E ≥ 24 (minimum safe zone for cancellation).
    mode_tag = 010 (PRSC) during normalization steps.
    accum_en = 0 (transport only).

  Phase 2 — Cancellation execution:
    Execute MUL(A, B) and MUL(A, −B) in the Stable band.
    mode_tag = 000 (STD) or 001 (BIAS if BIAS_LUT populated).
    accum_en = 1.

  Phase 3 — Post-cancellation:
    Read accum_out. Close epoch (accum_clr).
    The residual is the W01 structure — log it, do not correct at runtime.

  Pre-scheduling check:
    ASSERT both operands in Stable band before cancellation.
    ASSERT BIAS_LUT populated OR flag W01 residual as uncorrected.
    PROHIBIT cancellation execution in Transition band (E ∈ [16..19]).
    PROHIBIT cancellation execution in Collapse band (E ≤ 15).
```

### RULE S3 — Scaling Constraints (CLASS_C)

```
CLASS_C workloads MUST be pre-scaled before Stable band entry.
CLASS_C workloads MUST NEVER accumulate in the Collapse band.

  Pre-scale path (input E < 16):
    Apply MUL(x, NFE_TWO) × k until E ≥ 20.
    mode_tag = 010 during all scale steps.
    accum_en = 0 during all scale steps.
    Verify E ≥ 20 before enabling accum_en.

  In-scale path (E already in [20..43]):
    Scale down with MUL(x, NFE_HALF) or up with MUL(x, NFE_TWO).
    mode_tag = 010 (transit policy).
    accum_en = 0 (always 0 for CLASS_C).

  Post-scale hand-off:
    accum_clr before handing to next stage.
    Tag result with destination_E for receiving stage.

  STRICT PROHIBITION:
    accum_en = 1 in Collapse band: FORBIDDEN for CLASS_C.
    NFE_FLOOR accumulation produces an unreliable accumulator baseline
    for subsequent CLASS_A or CLASS_B work.
```

### RULE S4 — Deep Chain Depth Management (CLASS_D)

```
CLASS_D workloads MUST enforce:

  (a) Epoch partitioning:
    epoch_length = min(16, E_seed − 16)
    No epoch may exceed this length.
    Between epochs: CLASS_C normalization step OR accum_clr reset.

  (b) Mode escalation:
    depth ≤ 8:   mode_tag = 000 (STD)
    depth > 8:   mode_tag = 010 (PRSC)
    depth > 16:  ABMP trigger required (§1.7)

  (c) Periodic normalization every N steps:
    N = epoch_length − 2  (2-step early warning)
    At depth = N: emit scale-up instruction sequence.
    This prevents the epoch from reaching the floor attractor.

  (d) ABMP trigger condition:
    depth ≥ epoch_length − 2  AND  E_est ≤ 19
    Trigger Protocol: Phase Transport (if viable) or Scale-Up (always valid).

  Pre-scheduling check:
    COMPUTE epoch_length = min(16, E_seed − 16).
    COMPUTE n_epochs = ceil(total_depth / epoch_length).
    COMPUTE normalization_cost = n_epochs × scale_steps.
    ALERT if normalization_cost > 20% of total operation count.
```

---

## 1.5 Mode Tag Assignment Rules (Strict)

The following table is complete. No other mode logic is permitted.

| Condition | mode_tag | Rationale |
|---|---|---|
| Stable region dominant (E=20–43) | `000` (STD) | Full precision; no accumulator manipulation needed |
| Transition-heavy workload (E=16–19 or 44–47) | `010` (PRSC) | Pre-scales accum contributions during boundary zone transit |
| Saturation risk (E≥44, approaching ceiling) | `011` (SAFE) | Bounds accum; prevents wrap-around from large values |
| Collapse-prone chain (E≤15 w/ accum enabled) | `011` (SAFE) | Prevents accum distortion from NFE_FLOOR contributions |
| Collapse-prone chain (E≤15, no accum needed) | skip / accum_en=0 | Bypass; don't corrupt accumulator with floor contributions |
| CLASS_B cancellation (BIAS_LUT populated) | `001` (BIAS) | Active W01 cancellation drift correction |
| Phase Transport step (§1.7) | `010` (PRSC) | Transit policy during ADD rescue operation |

**Invariant:** Mode_tag never changes `result`, `underflow_flag`, or `exp_ovf_flag` (proven HBS-14, 384 tests, 0 exceptions). Mode selection is accumulator policy only.

---

## 1.6 Execution Mapping Function

This is the core dispatch algorithm executed per operation.

```
function map_workload_op(op, workload_class):

    // Step 1: Estimate result exponent
    E_est = predict_exponent(op.a, op.b, op.sel)

    // Step 2: Classify region (deterministic, from §1.3)
    region = classify_region(E_est)

    // Step 3: Route by region
    match region:

        STABLE:
            mode = 000
            // CLASS_B override: use BIAS if LUT populated
            if workload_class == CLASS_B and BIAS_LUT_populated:
                mode = 001

        TRANSITION:
            mode = 010
            // Pre-check: if workload_class == CLASS_B, apply Rule S2:
            //   scale up to E ≥ 24 before executing cancellation pair
            if workload_class == CLASS_B:
                apply_pre_scale(op)   // MUL by TWO^k; accum_en=0
                // then re-classify and continue

        SATURATION:
            mode = 011
            // CLASS_A/C: scale down to E ∈ [20..43] before accumulating
            if workload_class in [CLASS_A, CLASS_C]:
                apply_pre_scale_down(op)   // MUL by HALF^k; accum_en=0

        COLLAPSE:
            // Route decision: Phase Transport (§1.7) or skip/sentinel
            if workload_class in [CLASS_B, CLASS_D]:
                transport_result = attempt_phase_transport(op)   // §1.7
                if transport_result.success:
                    // Operand now at E=16 (TRANSITION), continue routing
                    emit(transport_result.op, mode=010, accum_en=1)
                    return   // transport instruction already emitted
                else:
                    // f < 32: ADD rescue not viable. Must scale-up.
                    apply_pre_scale(op, target_E=20)   // MUL by TWO^k
                    mode = 010
            else:
                // CLASS_A, CLASS_C in collapse: bypass accumulation
                skip_or_sentinel(op)
                return

    // Step 4: Determine depth-based mode escalation (CLASS_D)
    if workload_class == CLASS_D:
        if current_depth > 8:
            mode = max(mode, 010)   // escalate to at least PRSC
        if current_depth > 16:
            trigger_abmp()           // §1.7 full protocol

    // Step 5: Compute tile depth
    tile_depth = compute_tile_depth(E_est, current_depth)

    // Step 6: Emit instruction
    emit_horus_instruction(op, mode, accum_en=1, host_tile_depth=tile_depth)
```

---

## 1.7 Phase Transport Protocol

### Overview

Phase Transport is a deterministic, hardware-native mechanism that uses the Thoth Rollover property of the ADD operation to rescue a codeword from the Collapse routing zone (E=15) to the Transition zone (E=16) in a single cycle.

**This is a formal architectural feature, not a side-effect.** The hardware's Thoth Rollover behavior was confirmed in HBS-12A, characterized in HBS-13A, and the rescue mechanism was formally documented. Phase Transport formalizes the compiler's intentional use of this property.

### Hardware Physics (HBS-13A Confirmed)

```
Thoth Rollover condition:
  ADD(x, x) where f_x ≥ 32:
    result_E  = x.E + 1    (exponent incremented)
    result_f  = 2*(f_x − 32)   (fraction folded: 0..62 for f=32..63)

ADD rescue (Collapse → Transition):
  ADD(x, x) at E=15 with f ≥ 32:
    E=15, f=32 → E=16, f=0    ← rescued to TRANSITION entry
    E=15, f=63 → E=16, f=31   ← rescued to TRANSITION entry
    (50% of E=15 codewords are rescuable — exactly those with f ≥ 32)

ADD non-rescue (stays in Collapse):
  ADD(x, x) at E=15 with f < 32:
    E=15, f=0  → E=15, f=0    (stays at floor — no rollover)
    E=15, f=31 → E=15, f=62   (stays in collapse zone)
    (50% of E=15 codewords — those with f < 32 — cannot be rescued by ADD)
```

**One-way gate:** Once in TRANSITION (E=16), no ADD operation can push back to E=15 without explicit scale-down (MUL by HALF). The Phase Transport is a unidirectional rescue.

### Saturation Mirror — Hazard, Not Rescue

```
⚠ HAZARD (NOT a rescue):
  ADD(x, x) at E=47 with f ≥ 32:
    E=47, f=32 → E=48 → OVF    ← PUSHED INTO SATURATION
    E=47, f=63 → E=48 → OVF    ← PUSHED INTO SATURATION

  This is the MIRROR of the collapse rescue, but it is a HAZARD.
  At the saturation boundary, ADD rollover is DANGEROUS.
  The compiler MUST PREVENT ADD operations on E=47 operands with f ≥ 32.
  Use only MUL(x, NFE_HALF) to scale down from E=47.
```

The two sides of the ADD rollover boundary are asymmetric in intent:
- **Collapse side (E=15 → E=16):** Phase Transport = intentional rescue, architect-approved.
- **Saturation side (E=47 → E=48):** Thoth Push = hazard, must be avoided.

### ABMP_TRANSPORT_TRIGGER Viability Check

```
function transport_viable(op):
    // Phase Transport is viable iff:
    //   (a) op is in the Collapse routing zone: E_est == 15
    //   (b) fraction satisfies rollover condition: f_op >= 32
    //   (c) workload class allows rescue: CLASS_B or CLASS_D

    E_pred = predict_exponent(op.a, op.b, op.sel)
    f_curr = extract_fraction(op.a)   // fraction of the current operand

    return (E_pred == 15) AND (f_curr >= 32)
```

### Phase Transport Execution

```
function attempt_phase_transport(op):

    if not transport_viable(op):
        return TransportResult(success=False, op=op)

    // ── Phase 1: Snapshot ─────────────────────────────────────────────
    // Close current accumulation epoch before transport.
    // Prevents partial-epoch results from contaminating post-transport accum.
    snapshot = read_accum_out()
    emit_accum_clr()   // accum_clr pulse; op_count reset

    // ── Phase 2: Transport (ADD rescue) ──────────────────────────────
    // Emit ADD(op, op) — this triggers Thoth Rollover.
    // Hardware: f_result = 2*(f − 32), E_result = E + 1 = 16.
    // mode_tag = 010 (PRSC): accumulator contribution is pre-scaled.
    //   Rationale: the transport result at E=16 is in TRANSITION, not
    //   the stable safe zone. PRSC limits its accumulator contribution
    //   while normalization steps bring E to ≥ 20.
    // accum_en = 0 during transport step (transport = movement, not inference).
    emit(op.a, op.a, op_sel=ADD, mode_tag=010, accum_en=0, accum_clr=0)
    transported_operand = result   // capture result (E=16, new f)

    // ── Phase 3: Record TRANSPORT_EVENT ──────────────────────────────
    metadata.record_event(
        type     = "TRANSPORT_EVENT",
        from_E   = 15,
        to_E     = 16,
        from_f   = extract_fraction(op.a),
        to_f     = 2 * (extract_fraction(op.a) - 32),
        snapshot = snapshot,
        cycle    = current_cycle
    )

    // ── Phase 4: Continue normalization to safe zone ──────────────────
    // E=16 is TRANSITION (not yet safe for CLASS_B/D operations).
    // Apply MUL by TWO^k until E ≥ 20 (safe minimum).
    // mode_tag = 010 during these normalization steps.
    k = 20 - 16   // = 4 additional scale-up steps needed
    for i in 0..k:
        emit(transported_operand, NFE_TWO, op_sel=MUL,
             mode_tag=010, accum_en=0)
        transported_operand = result

    // ── Phase 5: Resume ───────────────────────────────────────────────
    // Reopen accumulator with fresh budget.
    emit_set_tile_depth(min(transported_operand.E - 16, 63))

    return TransportResult(success=True, op=transported_operand)
```

### Summary Table: Phase Transport vs. Direct Normalization

| Mechanism | Trigger condition | Steps | Cost | Result E |
|---|---|---|---|---|
| Phase Transport (ADD rescue) | E=15, f≥32 | 1 ADD + 4 MUL×TWO | 5 cycles | E=20 |
| Direct Scale-Up | E ≤ 15, any f | k × MUL×TWO | k cycles | E=target |
| Combined | E=15, f≥32 (optional shortcut) | Phase Transport is a 1-step first move | 1+4 = 5 vs. 5 | Identical outcome |

For E=15: Phase Transport requires 1 ADD + 4 scale-ups = 5 cycles to reach E=20. Direct scale-up from E=15 to E=20 also requires 5 MUL×TWO cycles. Phase Transport is not faster than direct scale-up in this case — it is useful when the fraction information needs to be preserved through the rollover (since ADD(x,x) is different from MUL(x, TWO): ADD doubles the mantissa while MUL preserves it shifted). The compiler may choose either mechanism; Phase Transport provides fraction-space coverage unavailable from pure scaling.

---

## 1.8 Compiler Invariants

These invariants hold across all C3 workload embeddings. They must never be violated by a scheduler implementation.

**CI-1 (Determinism):** Region classification is fully deterministic. Given the same E_pred and workload class, the scheduler produces the same region assignment, mode_tag, and emit sequence. No random, heuristic, or probabilistic component is permitted.

**CI-2 (Physics immutability):** No workload embedding, mode selection, or Phase Transport step alters the hardware's arithmetic physics. UF/OVF boundaries at E=15↔16 and E=47↔48 are fixed. The floor attractor at NFE_FLOOR is fixed. The Thoth Rollover threshold (f≥32) is fixed.

**CI-3 (Mode invariance):** Mode selection does NOT affect UF/OVF flag generation or the `result` output (proven HBS-14, 384 tests). The scheduler builds on this invariant unconditionally.

**CI-4 (Collapse is a routing condition):** E≤15 (Collapse routing zone) is NOT an error condition. The hardware does not fail at E=15. Hardware UF (underflow_flag) fires only when the computed product exponent is negative (E_a + E_b < 32). The Collapse routing zone is a compiler-level danger classification for chain operations. Scheduler decisions at E≤15 are routing decisions, not error recovery.

**CI-5 (Phase Transport is deterministic):** The ADD rescue (E=15, f≥32 → E=16) is a deterministic algebraic property of the hardware, confirmed HBS-13A. The viability check (f≥32) is computed from the current operand state. When viable, Phase Transport always succeeds. When not viable (f<32), it never succeeds. There is no intermediate state.

**CI-6 (Saturation ADD hazard):** ADD(x,x) at E=47 with f≥32 pushes to E=48 (saturation). This is the saturation mirror of Phase Transport and is a HAZARD, not a rescue. The scheduler MUST prevent this. Operands at E=47 must be scaled down (MUL by HALF) before any ADD operation.

**CI-7 (System continuity):** The C3 embedding layer does not add new hardware signals. It operates exclusively through the existing interface: (op_a, op_b, op_sel, mode_tag, accum_en, accum_clr, host_tile_depth). All output from C3 is a sequence of legal HORUS v3 instructions.

**CI-8 (HBS-C2 consistency):** C3 routing decisions must remain consistent with HBS-C2 measured behavior: 59.3% stable-band occupancy as the majority under mixed workload. A C3 embedding that routes more than 40% of stable-zone operations to Transition or Collapse is misclassifying workload class.

---

## 1.9 Phase Embedding: Reference Profiles

Complete reference profiles for the four canonical workload classes. These are the expected outputs of a correctly operating C3 embedding layer.

### CLASS_A Reference Profile (Matrix Multiply, E_seed=32)

```
Workload:         Matrix multiply (N×N, N=16)
Class:            CLASS_A
E_seed:           32 (natural anchor)
Expected depth:   16 per epoch (N=16 output accumulation)

Region distribution:
  Stable       95%   ← dominant
  Transition    5%   ← boundary operations, edge channels
  Collapse      0%   ← RULE S1 enforced
  Saturation    0%   ← weight magnitudes designer-controlled

Dominant region:  STABLE
Risk level:       LOW
mode_tag policy:  000 throughout
Epoch depth:      16
ABMP required:    NO
tile_depth:       16
```

### CLASS_B Reference Profile (Residual Connection, E_seed=32)

```
Workload:         Residual skip connection (Add + subtract path)
Class:            CLASS_B
E_seed:           32 (same magnitude for both paths)
Expected depth:   2 (one MUL + one cancelling MUL)

Region distribution:
  Stable       90%   ← both ops in stable zone
  Transition    8%   ← normalization before pairing
  Collapse      2%   ← misrouted or sub-threshold channels
  Saturation    0%

Dominant region:  STABLE
Risk level:       MEDIUM (W01 residual; BIAS_LUT calibration needed)
mode_tag policy:  000 (or 001 when BIAS_LUT populated)
Epoch depth:      2
ABMP required:    IF E_pred < 20 on either operand
tile_depth:       2
```

### CLASS_C Reference Profile (Layer Norm Scaling)

```
Workload:         Layer normalization (scale step only)
Class:            CLASS_C
E_seed:           varies (input-dependent)
Expected depth:   1–4 scale steps

Region distribution:
  Stable       varies  ← post-scale landing zone
  Transition   dominant during scaling
  Collapse     possible ← if input E < 16
  Saturation   possible ← if input E > 47

Dominant region:  TRANSITION (during operation)
Risk level:       MEDIUM (always crosses boundaries)
mode_tag policy:  010 throughout (transport policy)
accum_en:         0 throughout CLASS_C
Epoch depth:      N/A (no accumulation)
ABMP required:    YES if input E < 16 (scale-up before handoff)
```

### CLASS_D Reference Profile (Multi-Layer Pipeline, E_seed=32, depth=48)

```
Workload:         3-epoch transformer layer stack (depth 48 = 3 × 16)
Class:            CLASS_D
E_seed:           32
Expected depth:   48 (partitioned into 3 epochs of 16)

Region distribution:
  Stable       75%   ← primary execution
  Transition   25%   ← epoch boundaries + normalization
  Collapse      0%   ← ABMP prevents
  Saturation    0%

Dominant region:  STABLE
Risk level:       MEDIUM (depth managed; normalization applied)
mode_tag policy:  000 (depth ≤ 8), 010 (depth > 8)
Epoch depth:      16
Normalization:    Every 14 steps (2-step early warning)
ABMP required:    YES — at epoch boundary (normalize or Phase Transport)
n_epochs:         3
tile_depth:       16
```

---

## Related Documents

| Document | Relationship |
|---|---|
| `docs/HORUS_C1_COMPILER_SPEC.md` | Instruction-level routing (C3 extends to workload-graph level) |
| `docs/HORUS_PHASE_SCHEDULER_MODEL.md` | Visual model of C3 scheduling (diagrams of this spec) |
| `docs/HORUS_SYSTEM_COMPILATION_MODEL.md` | Layer separation; interface contract |
| `docs/HORUS_ARITHMETIC_ENVELOPE.md` | Depth limits; floor attractor schedule (HBS-12D) |
| `docs/HORUS_BOUNDARY_GAP_ANALYSIS.md` | Phase Transport physics source (HBS-13A ADD rescue) |
| `docs/HORUS_C2_LIVE_SYSTEM_REPORT.md` | Measured occupancy data (CI-8 reference) |
| `docs/EXECUTION_POLICY.md` | Policy modes (HBS-11); W01 cancellation residual |
