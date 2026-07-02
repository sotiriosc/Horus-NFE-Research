# HORUS C1 Compiler Specification

**Document type:** Compiler-Level Mapping Specification  
**Authority:** HBS-11 through HBS-14 validated hardware behavior (frozen)  
**Version:** 1.0 · 2026-07-02  
**Status:** GOLD — hardware physics are closed; only compiler routing is defined here

---

## 1.1 Compiler Objective

The HORUS C1 compiler defines a **deterministic mapping** from high-level operations to HORUS v3 execution regions and `mode_tag` selections.

The compiler is a **phase-space router**, not a numerical optimizer. It does not correct, modify, or compensate for arithmetic physics. It routes operations into the appropriate execution phase and selects the accumulator policy that best preserves valid results within that phase.

**Core mapping:**
```
high-level operation
    → classify_magnitude(operand_E)
        → assign_region(E)
            → select_mode_tag(region, depth, workload_class)
                → emit HORUS instruction
```

**The compiler MUST:**
- NEVER assume arithmetic continuity across region boundaries
- NEVER treat the exponent field as a linear numeric axis
- ALWAYS route operations into predefined execution phases
- ALWAYS communicate boundary approach conditions to the scheduler
- NEVER attempt to "correct" UF/OVF events at the compiler level

**The compiler MUST NOT:**
- Modify RTL behavior
- Introduce new hardware signals
- Mask or suppress `underflow_flag` or `exp_ovf_flag`
- Assume that policies stabilize arithmetic near boundaries

---

## 1.2 Input Abstraction Model

The compiler recognizes four canonical workload classes. Each is characterized by a magnitude band, expected depth, and volatility classification.

### Class A — MAC Chains (Multiply-Accumulate)

```
Definition:  Sequences of MUL operations on evolving operands with
             accumulation via accum_en=1.

Magnitude:   E_seed = initial stored_E of the operand before chain starts.
Depth:       N = number of MUL operations in the chain.
Volatility:  Stable (E_seed ≥ 24, depth ≤ E_seed − 16)
             Transition (E_seed ∈ [20..23] or depth approaching E_seed − 16)
             Boundary-prone (E_seed ∈ [16..19], depth > 4)

Key constraint (HBS-12D):
  depth_max = E_seed − 16  [for HALF-scaling chains]
  Beyond this depth, chain enters collapse zone deterministically.

Floor attractor schedule (from HBS-12D, HALF-chain with NFE_HALF):
  E_seed=16 → depth_max=0  (immediate UF on first self-MUL with HALF)
  E_seed=20 → depth_max=4
  E_seed=24 → depth_max=8  (recommended minimum for inference chains)
  E_seed=28 → depth_max=12
  E_seed=32 → depth_max=16  (natural anchor; symmetric floor/ceiling distance)
  E_seed=40 → depth_max=24
  E_seed=47 → depth_max=31

Information cliff (HBS-12D): depth ≥ 32 for E_seed ∈ [28..35]
  → entropy < 2.59 bits (≈ 2.6 effective bits of 6)
```

### Class B — ADD/SUB Cancellation Pairs

```
Definition:  Operations of the form MUL(A, B) + MUL(A, −B) or equivalent,
             where cancellation produces a structured non-zero residual.

Magnitude:   Determined by dominant operand E.
Depth:       Typically 2 (one MUL + one cancelling MUL).
Volatility:  Stable if both operands in stable band.
             The cancellation residual is deterministic and
             exponent-band-dependent (HBS-9, W01 finding).

Structured residual: MUL(x, y) + MUL(x, −y) ≠ 0 in NFE domain.
  The residual is indexed by e_a (stored exponent of the result).
  BIAS_LUT[e_a] is the mechanism for correcting this residual (HBS-11).
  Correction is currently zero (LUT = 0); requires QAT calibration.

Compiler annotation: tag as CLASS_B_CANCEL for scheduler mode selection.
  → Default mode: 000 (STD)
  → If BIAS_LUT populated: mode = 001 (BIAS) for cancel-pair accumulation
```

### Class C — Scaling / Normalization Steps

```
Definition:  Explicit exponent adjustment operations.
             Implemented as MUL(x, NFE_HALF) or MUL(x, NFE_TWO).
             Used to move operands between exponent bands.

Magnitude:   Input E transitions by ±1 per step (HALF or TWO multiply).
Depth:       k = number of scale steps required.
Volatility:  Inherently volatile — purpose is to cross exponent space.

Key properties:
  MUL(x, NFE_ONE): identity, E unchanged, f unchanged. Zero cost.
  MUL(x, NFE_HALF): E ← E − 1, f preserved (P[13]=0 for all f).
    HBS-12B: MUL(x, ONE) exact for all 64 fraction values at E=32.
  MUL(x, NFE_TWO): E ← E + 1, f preserved.

Compiler constraint: scaling operations MUST NOT be accumulated
  (accum_en=0) unless the intermediate values are meaningful.
  Scaling is a TRANSPORT operation, not an inference operation.
  Use accum_clr before resuming inference accumulation after scaling.
```

### Class D — Depth-Based Composition Chains

```
Definition:  Multi-layer inference chains where each layer takes
             the previous layer's output as input.
             Equivalent to iterated function application.

Magnitude:   E_start = exponent at chain entry.
Depth:       L = total number of composition steps.
Volatility:  Deterministic collapse beyond depth = E_start − 16.

Critical property (HBS-12D, HBS-14D):
  Collapse is NOT stochastic. It occurs at exactly depth = E_start − 16
  for HALF-scaling chains. This is an algebraic property, not a
  probabilistic one.

Information cliff: depth ≥ 32 for E_seed ∈ [28..35] produces
  entropy < 2.59 bits. Beyond depth 64: entropy → 0 (complete floor).

Compiler MUST partition composition chains into epochs:
  epoch_length ≤ min(16, E_start − 16)
  Between epochs: normalization step (Scale-Up or Reset)
```

---

## 1.3 Region Classification Engine (CORE RULESET)

The classification engine maps a predicted operand exponent `E_pred` to one of four execution regions. Classification is deterministic given `E_pred`.

### Rule Precedence

Rules are evaluated in strict order. The first matching rule applies.

```
RULE R0 (HARD GATE — Collapse):
  IF E_pred ≤ 15:
    region = COLLAPSE
    GOTO §1.3.3

RULE R1 (HARD GATE — Saturation):
  IF E_pred ≥ 48:
    region = SATURATION
    GOTO §1.3.4

RULE R2 (TRANSITION — Collapse Approach):
  IF E_pred ∈ [16..19]:     (within 4-step margin of collapse cliff)
    region = TRANSITION_LOW
    GOTO §1.3.2a

RULE R3 (TRANSITION — Saturation Approach):
  IF E_pred ∈ [44..47]:     (within 4-step margin of saturation cliff)
    region = TRANSITION_HIGH
    GOTO §1.3.2b

RULE R4 (STABLE):
  IF E_pred ∈ [20..43]:
    region = STABLE
    GOTO §1.3.1

RULE R5 (UNREACHABLE — should not occur given hard gates above):
  ASSERT FALSE
```

### §1.3.1 Stable Region (E = 16–47; SAFE zone E = 20–43)

```
Computational role:   Primary inference execution. All operations valid.
Default mode:         000 (STD)
Optional mode:        001 (BIAS) only when BIAS_LUT is populated and
                      CLASS_B_CANCEL has been detected by the annotation pass.
Optional mode:        010 (PRSC) for CLASS_D deep chains with depth > 8.

Accumulation:         accum_en = 1 (permitted)
Depth limit:          E_pred − 16 (HARD; enforced by depth counter)

Compiler assertions:
  ASSERT 16 ≤ E_a ≤ 47 AND 16 ≤ E_b ≤ 47  (before MUL emission)
  WARN   E_pred ∈ [16..19]  (collapse approach — escalate to TRANSITION)
  WARN   E_pred ∈ [44..47]  (saturation approach — escalate to TRANSITION)
  ASSERT f_a + delta < 64   (for reversible ADD→SUB compute graphs)
```

### §1.3.2a Transition Region — Collapse Approach (E = 16–19)

```
Computational role:   Scaling awareness zone. Operations permitted but
                      compiler MUST insert normalization boundary handling.
                      Classification is triggered when E_pred ∈ [16..19].

Allowed modes:
  010 (PRSC)          — Scale down accumulator contributions while
                        normalization steps bring E back into safe zone.

Required action:
  1. Emit Boundary Approach Warning to scheduler.
  2. Classify accumulated work as "approach epoch" — close with snapshot.
  3. Execute Active Boundary Management Protocol (ABMP, see §1.8).
  4. Resume stable-region processing after E ≥ 20.

ADD rescue awareness:
  IF E_pred == 15 AND f_operand ≥ 32:
    ADD(x, x) will rescue into E=16 (HBS-13A confirmed).
    This rescue is NOT sufficient to reach the safe zone (E≥20).
    Compiler MUST follow rescue with additional scale-up steps.
  IF E_pred == 15 AND f_operand < 32:
    ADD(x, x) stays in collapse zone. No rescue. Use MUL(x, NFE_TWO) instead.
```

### §1.3.2b Transition Region — Saturation Approach (E = 44–47)

```
Computational role:   Scale-down zone. Operations permitted but
                      compiler MUST prevent Thoth Rollover into saturation.

Allowed modes:
  011 (SAFE)          — Bound accumulator if saturation is unavoidable.
  010 (PRSC)          — Pre-scale contributions to prevent accum overflow.

Required action:
  1. Emit Boundary Approach Warning for saturation side.
  2. PROHIBIT ADD_FRAC operations when E_pred = 47 AND f_operand ≥ 32.
     Thoth Rollover at E=47 with f≥32 → E=48 (saturation cliff, HBS-13B).
  3. Execute scale-down: emit MUL(x, NFE_HALF) to bring E into safe zone.
  4. Or close epoch with SNAPSHOT and continue as ceiling-bound computation.
```

### §1.3.3 Collapse Region (E = 0–15)

```
Computational role:   Sentinel domain. MUST NOT be treated as numeric space.
                      MUL operations unconditionally produce NFE_FLOOR.

Compiler behavior options:
  Option A — Discard:
    Do not accumulate operations in collapse zone.
    Set accum_en = 0 for all operations with E_pred < 16.
    The result is NFE_FLOOR; accumulating it contributes 0.
    This is the default behavior: BYPASS ACCUMULATION.

  Option B — Sentinel Boundary:
    If the application intentionally uses collapse as a depth gate:
    Set mode_tag = 011 (SAFE) to prevent accum wrap from floor contributions.
    The accumulated total reflects only the pre-collapse valid operations.
    Useful when the application terminates on underflow_flag observation.

Allowed modes:
  011 (SAFE)          — Accumulation boundary protection
  or bypass (accum_en = 0) — Default

FORBIDDEN:
  Accumulating NFE_FLOOR contributions with the expectation of
  numerical recovery. Once a chain reaches floor, information is lost.
  The only recovery is accum_clr (explicit reset).

Compiler annotation: emit REGION_COLLAPSED flag to host.
```

### §1.3.4 Saturation Region (E = 48–63)

```
Computational role:   Ceiling-bound representation space. Values here are
                      bounded but not faithfully representable.

Compiler MUST treat as capped representation, not arithmetic space.
MUL operations produce NFE_MAXPOS unconditionally (HBS-12A).

Compiler behavior options:
  Option A — Ceiling Gate:
    Use exp_ovf_flag as a one-bit "above ceiling" signal.
    Do not read the numeric value; read only the flag.
    This is the PRIMARY intended use for the saturation band.

  Option B — Saturating Accumulation:
    Set mode_tag = 011 (SAFE) and accumulate.
    accum_reg is bounded at 0xFFFFFFFF; no modular wrap.
    The accumulated total counts "saturated MACs" × NFE_MAXPOS.
    Useful for outlier detection and spike counting.

  Option C — Discard and Reset:
    On exp_ovf_flag observation: issue accum_clr, discard window result.
    Resume computation with pre-scaled operands.

Allowed modes:
  011 (SAFE)          — Bounded accumulation or outlier counting
  or bypass (accum_en = 0) — Ceiling-gate use case
```

---

## 1.4 Mode Selection Rules (DETERMINISTIC)

Mode selection is strictly determined by region classification. No probabilistic selection is permitted.

```
MODE SELECTION TABLE:

  Region          | E_pred        | Default mode | Override mode
  ─────────────────────────────────────────────────────────────────
  STABLE (safe)   | 20..43        | 000 (STD)    | 001 if CLASS_B_CANCEL+LUT
  STABLE (low)    | 16..19        | 010 (PRSC)   | (no override; ABMP required)
  STABLE (high)   | 44..47        | 010 (PRSC)   | 011 if ceiling-bound op
  TRANSITION_LOW  | 16..19        | 010 (PRSC)   | ABMP must run
  TRANSITION_HIGH | 44..47        | 011 (SAFE)   | 010 if scale-down primary
  COLLAPSE        | 0..15         | accum skip   | 011 if sentinel boundary use
  SATURATION      | 48..63        | accum skip   | 011 if outlier counting

INVARIANT (from HBS-14, 384 tests, 0 exceptions):
  Mode selection NEVER changes the `result` output.
  Mode selection NEVER changes underflow_flag or exp_ovf_flag.
  Mode selection ONLY affects accum_reg trajectory.
```

**Override rule — CLASS_B_CANCEL (cancellation pairs):**
```
IF workload_class == CLASS_B_CANCEL:
  IF BIAS_LUT populated:
    mode = 001 (BIAS)   — active cancellation correction
  ELSE:
    mode = 000 (STD)    — zero correction until calibration
    EMIT warning: "BIAS_LUT uncalibrated; W01 mitigation inactive"
```

**Override rule — deep CLASS_D chains:**
```
IF workload_class == CLASS_D AND depth > 8:
  mode = 010 (PRSC)   — contain accumulator growth across epochs
  ASSERT epoch_length ≤ min(16, E_seed − 16)
```

---

## 1.5 Depth Control Integration (pgate-aware)

The compiler MUST generate `host_tile_depth` settings and epoch boundaries in coordination with the pgate_ctrl execution horizon.

### Hard Depth Constraints

```
CONSTRAINT D-1 (pgate absolute maximum):
  host_tile_depth ≤ 63   [hardware limit; pgate_ctrl is 6-bit]
  NEVER set host_tile_depth = 0   [this CLOSES the gate permanently]
  Valid range: 1..63

CONSTRAINT D-2 (floor attractor — seed-dependent):
  epoch_depth ≤ E_seed − 16   [for HALF-scaling MAC chains]
  This is the floor attractor algebraic limit; NOT a guideline.
  Exceeding this guarantees UF and floor attractor activation.

CONSTRAINT D-3 (information cliff):
  epoch_depth ≤ 16   [for E_seed ∈ [28..35], HBS-12D hard cliff]
  epoch_depth ≤ 32   [for all seeds; entropy cliff at depth 32]
  Beyond depth 32: entropy < 2.59 bits for anchor-zone seeds.

CONSTRAINT D-4 (transition zone chains):
  epoch_depth ≤ 8    [when E_pred ∈ [16..23]; 4-step margin]
```

### Depth-Triggered Actions

```
IF depth > 16:
  OPTION A (normalization boundary):
    At depth = E_seed − 16 − 2 (2-step early warning):
      INSERT MUL(x, NFE_TWO) × k   [k steps to reach E ≥ E_seed again]
      SET mode_tag = 010 during normalization steps
      RESET accum_clr after normalization
    Resume from E_seed with fresh accumulation window.

  OPTION B (epoch window reset):
    At depth = epoch_length:
      SNAPSHOT: read accum_out, store externally
      ASSERT accum_clr
      RESET host_tile_depth = N (reopen gate)
      CONTINUE with same operand, new accum window.

  OPTION C (floor gate):
    At depth = E_seed − 16:
      ALLOW UF to fire naturally
      OBSERVE underflow_flag
      ISSUE accum_clr on underflow_flag detection
      This uses the floor attractor as a natural depth sentinel.
      (Valid only when depth-limited results are not needed.)
```

### host_tile_depth Sizing

```
SIZING RULE:
  host_tile_depth = min(epoch_length, E_pred − 16, 63)

EXAMPLES:
  E_seed=32, epoch=16:  host_tile_depth = min(16, 16, 63) = 16
  E_seed=24, epoch=8:   host_tile_depth = min(8, 8, 63)   = 8
  E_seed=47, epoch=16:  host_tile_depth = min(16, 31, 63) = 16
  E_seed=16, epoch=1:   host_tile_depth = min(1, 0, 63)   = 1
    [NOTE: E=16 has depth_max=0 for HALF chains; this is a boundary op]
```

---

## 1.6 Compiler Invariants

These are binding constraints that the compiler must enforce and must never violate.

**CI-1: Arithmetic physics is not modified by the compiler.**
The compiler emits instructions to existing hardware. UF/OVF boundaries at E=15↔16 and E=47↔48 are algebraic properties of the hardware arithmetic. The compiler cannot move, widen, or eliminate these boundaries. Any compiler strategy that appears to "avoid" a boundary does so by routing around it through operand-level normalization — the boundary itself remains unchanged.

**CI-2: The compiler only selects execution region and mode_tag.**
The compiler's complete output is a sequence of: (op_a, op_b, op_sel, mode_tag, accum_en, accum_clr, host_tile_depth). No other hardware control is available. The compiler does not have write access to BIAS_LUT at runtime (that is a QAT calibration concern, not a per-inference compiler decision).

**CI-3: No attempt is made to correct UF or OVF.**
When UF fires, the result is NFE_FLOOR. The compiler does not attempt to substitute a different result or retroactively repair the accumulator. The correct response is to close the accumulation epoch (accum_clr), log the event, and route the workload to a fresh window.

**CI-4: All boundary effects are preserved, not hidden.**
The compiler passes `underflow_flag` and `exp_ovf_flag` through to the calling system without modification. These flags are observable by the host. The compiler MUST NOT set `accum_en = 0` as a strategy to suppress floor contributions while hiding the underlying UF event from the host.

**CI-5: Mode invariance is assumed and required.**
The compiler selects mode_tag knowing that `result` is mode-invariant (proven HBS-14, 384 tests). Any mode selection that produces a different `result` than MODE_STD on the same input is an architectural violation and must be treated as a hardware defect. The compiler builds on this invariant; it does not verify it at runtime.

**CI-6: Policy cannot rescue boundary crossings.**
No `mode_tag` value prevents arithmetic UF or OVF. The policy decoder operates after `result` is computed. Any scheme that relies on policy to "protect" an operation from UF/OVF is architecturally incorrect. The only boundary protection is operand-level normalization before the operation.

---

## 1.7 Execution Flow (Pseudocode)

### Primary Dispatch Pipeline

```
function emit_horus_instruction(op_class, op_a, op_b, op_sel, chain_depth):

    // Step 1: Classify magnitude
    E_pred = predict_exponent(op_class, op_a, op_b, op_sel, chain_depth)
    f_pred = predict_fraction(op_class, op_a, op_b, op_sel)

    // Step 2: Assign region (Rule R0–R5 from §1.3)
    region = classify_region(E_pred)

    // Step 3: Boundary hazard check (Active Boundary Management)
    if hazard := detect_boundary_hazard(E_pred, f_pred, op_sel, chain_depth):
        return execute_abmp(op_a, op_b, op_sel, hazard)  // see §1.8

    // Step 4: Select mode_tag
    mode = select_mode(region, op_class, chain_depth)

    // Step 5: Set accumulator control
    (accum_en, accum_clr) = accum_policy(region, op_class, chain_depth)

    // Step 6: Set tile depth
    tile_depth = compute_tile_depth(E_pred, chain_depth, region)

    // Step 7: Emit instruction
    emit(op_a=op_a, op_b=op_b, op_sel=op_sel,
         mode_tag=mode, accum_en=accum_en, accum_clr=accum_clr,
         host_tile_depth=tile_depth)
```

### MAC Chain Dispatch

```
function emit_mac_chain(operands[], chain_depth, E_seed):

    accum_budget = min(chain_depth, E_seed − 16, 63)

    for depth in 0..chain_depth:

        E_current = E_seed − depth   // approximate for HALF-chain
        region    = classify_region(E_current)

        // Pre-operation depth guard
        if depth == accum_budget − 2:   // 2-step early warning
            // Approaching depth limit — insert normalization if not terminating
            if CONTINUE_AFTER_EPOCH:
                emit_normalization(operands[depth], steps=depth − (E_seed − 20))
                accum_budget = accum_budget + (depth − (E_seed − 20))

        mode      = select_mode(region, CLASS_A, depth)
        tile_depth = accum_budget

        emit(operands[depth], operands[depth],
             op_sel=MUL, mode_tag=mode,
             accum_en=1, accum_clr=(depth==0),
             host_tile_depth=tile_depth)

    // Close epoch
    snapshot_accum()    // read accum_out
    emit_accum_clr()
```

### Cancellation Pair Dispatch

```
function emit_cancel_pair(a, b, neg_b, E_pair):

    region = classify_region(E_pair)
    assert region == STABLE  // cancellation pairs only valid in stable zone

    if BIAS_LUT_POPULATED:
        mode = 001  // BIAS — active residual correction
    else:
        mode = 000  // STD — passive; residual uncorrected
        log_warning("W01 cancellation drift unmitigated")

    // Positive MUL
    emit(a, b, op_sel=MUL, mode_tag=mode, accum_en=1, ...)

    // Cancelling MUL
    emit(a, neg_b, op_sel=MUL, mode_tag=mode, accum_en=1, ...)
```

### Scaling / Normalization Step Dispatch

```
function emit_scale_up(operand, steps):
    // MUL by NFE_TWO, steps times
    // accum_en = 0 (scaling is transport, not inference)
    for i in 0..steps:
        emit(operand, NFE_TWO, op_sel=MUL, mode_tag=000,
             accum_en=0, accum_clr=0)
        operand = result   // feed forward (1-cycle latency)
    return operand

function emit_scale_down(operand, steps):
    for i in 0..steps:
        emit(operand, NFE_HALF, op_sel=MUL, mode_tag=000,
             accum_en=0, accum_clr=0)
        operand = result
    return operand
```

### Boundary-Crossing Dispatch

```
function emit_cross_region(operand, destination_E):
    // Route operand from current E to destination_E
    // without crossing a collapse or saturation cliff

    current_E = operand.E
    delta_E   = destination_E − current_E

    // Scale direction
    if delta_E > 0:
        operand = emit_scale_up(operand, delta_E)
    else:
        operand = emit_scale_down(operand, -delta_E)

    assert operand.E == destination_E
    assert 16 ≤ operand.E ≤ 47    // must land in stable zone
    return operand
```

---

## 1.8 Boundary-Crossing Hazard Detection and Active Boundary Management

### Hazard Detection

A **boundary-crossing hazard** is a predicted condition in which an operation will transport the operand exponent across a cliff boundary during the current or next operation.

```
function detect_boundary_hazard(E_pred, f_pred, op_sel, chain_depth):

    // Collapse hazard: E approaching or at cliff
    if E_pred ≤ 17:
        return HAZARD_COLLAPSE_IMMINENT

    // Collapse hazard: depth will exhaust E headroom
    headroom = E_pred − 16
    if chain_depth ≥ headroom − 2:    // 2-step early warning
        return HAZARD_COLLAPSE_DEPTH

    // Saturation hazard: ADD Thoth Rollover at E=47
    if E_pred == 47 AND op_sel == ADD AND f_pred ≥ 32:
        return HAZARD_SAT_ROLLOVER       // ADD will push to E=48

    // Saturation hazard: approaching cliff
    if E_pred ≥ 45:
        return HAZARD_SAT_IMMINENT

    return NO_HAZARD
```

### Architect's Suggestion Evaluation

> *Suggested: inject mode_tag=010 (Pre-Scaled) or a Snapshot/Reset before boundary crossing.*

**Assessment (grounded in HBS-14):**

Mode_010 (PRE_SCALED) affects the ACCUMULATOR ONLY. It does NOT change the `result` codeword, the UF condition, or the exponent of the next operation's input. This was verified in HBS-14: 0 result mismatches across 384 tests.

Therefore:
- Mode_010 injection **alone** cannot prevent a boundary crossing.
- The primary prevention mechanism is **operand normalization** (MUL by TWO^k).
- Mode_010 is the correct **secondary** accumulator guard during normalization.

The suggestion is **partially correct** and is formalized below as a two-phase protocol.

### Active Boundary Management Protocol (ABMP)

ABMP is triggered on any non-NO_HAZARD return from `detect_boundary_hazard`. It is a three-phase sequence: **Snapshot → Normalize → Resume**.

```
function execute_abmp(operand, hazard_type):

    // ── Phase 1: SNAPSHOT ─────────────────────────────────────────────
    // Save accumulated state before boundary zone operations.
    // Prevents partial boundary-crossing results from corrupting accum.

    snapshot_value = read_accum_out()   // sample accum_out
    emit_accum_clr()                    // accum_clr = 1 for one cycle
    // accum_reg = 0, op_count_reg = 0
    log_event("ABMP: snapshot taken, accum cleared, hazard=" + hazard_type)


    // ── Phase 2: NORMALIZE ────────────────────────────────────────────
    // Rescale the operand to bring E into the safe zone.
    // mode_tag = 010 (PRSC) during normalization steps:
    //   - Reduces each scale-step's accumulator contribution
    //   - Limits accum growth while the operand is in transition
    //   - Does NOT affect the normalization result itself (HBS-14 CI-5)

    if hazard_type in [HAZARD_COLLAPSE_IMMINENT, HAZARD_COLLAPSE_DEPTH]:
        target_E = max(E_safe_minimum + 4, 20)   // 4-step margin
        steps    = target_E − operand.E
        for i in 0..steps:
            emit(operand, NFE_TWO, op_sel=MUL, mode_tag=010,
                 accum_en=0, accum_clr=0)
            operand = result
        assert operand.E ≥ 20

    if hazard_type == HAZARD_SAT_ROLLOVER:
        // Prevent ADD rollover at E=47 by pre-scaling operand down
        emit(operand, NFE_HALF, op_sel=MUL, mode_tag=010,
             accum_en=0, accum_clr=0)
        operand = result
        assert operand.E ≤ 46   // now ADD with f≥32 lands at E=47 (safe)

    if hazard_type == HAZARD_SAT_IMMINENT:
        steps = operand.E − 43   // bring to 4-step margin from ceiling
        operand = emit_scale_down(operand, steps)


    // ── Phase 3: RESUME ───────────────────────────────────────────────
    // Reopen accumulator with fresh budget.
    // Return normalized operand for continued processing.

    emit_set_tile_depth(min(operand.E − 16, 63))
    log_event("ABMP: operand normalized to E=" + operand.E +
              ", fresh accum window opened")

    return (operand, snapshot_value)


// Caller integrates snapshot_value into external accumulation:
//   external_accum += snapshot_value
//   continue_chain(operand)
```

### ABMP Summary

| Phase | Action | mode_tag | Hardware Effect |
|---|---|---|---|
| 1. Snapshot | Read accum_out; assert accum_clr | any | Saves state; resets accum_reg and op_count_reg |
| 2. Normalize | MUL by TWO^k (up) or HALF^k (down) | 010 | Moves operand E; mode_010 limits accum growth during transit |
| 3. Resume | Set tile_depth; continue chain | 000 or 010 | Fresh accumulation window at safe E |

**Why mode_010 during normalization (Phase 2):**
During normalization, each scale step produces an intermediate result that may have fractional information but lower precision. mode_010 pre-scales these intermediate contributions (E−1 before accumulation), preventing the normalization steps from inflating the accumulator with large intermediate values. This is the correct role for PRE_SCALED: a transit policy, not a boundary prevention policy.

**What ABMP does NOT do:**
- It does not retroactively prevent UF if the hazard fires before ABMP is triggered.
- It does not alter the hardware's arithmetic physics.
- It does not guarantee information recovery through the floor (HBS-13D: through-floor recovery loses fraction; E recovers with +2 offset).

---

## 1.9 Prediction Functions

The compiler requires estimated exponent values at each operation site. These are static analysis estimates; the actual hardware result may differ due to Thoth Rollover or normalization paths.

```
function predict_exponent(op_class, op_a, op_b, op_sel, depth):

    E_a = extract_exponent(op_a)
    E_b = extract_exponent(op_b)

    if op_sel == MUL:
        E_result = E_a + E_b − 32
        if E_result < 0:   return PREDICT_UF    // → COLLAPSE
        if E_result > 63:  return PREDICT_OVF   // → SATURATION
        return E_result

    if op_sel == ADD:
        f_a  = extract_fraction(op_a)
        f_b  = extract_fraction(op_b)
        if f_a + f_b ≥ 64:
            return E_a + 1    // Thoth Rollover
        return E_a

    if op_sel == SUB:
        // Guard-A: f_a ≥ delta → E unchanged
        // Guard-B: f_a < delta, E > 0 → E − 1
        if E_a > 0 AND extract_fraction(op_a) < extract_fraction(op_b):
            return E_a − 1    // Guard-B path
        return E_a

    if op_sel == NOP:
        return E_a    // operand unchanged
```

---

## Related Documents

| Document | Relationship |
|---|---|
| `docs/EXECUTION_MAPPING.md` | Formal execution contract; region semantics (compiler derives from this) |
| `docs/HORUS_V3_FINAL_SPEC.md` | Hardware specification; physics compiler relies on |
| `docs/HORUS_SYSTEM_COMPILATION_MODEL.md` | Visual compilation model; layer separation diagram |
| `docs/EXECUTION_POLICY.md` | Policy mode specification (HBS-11) |
| `docs/HORUS_SYSTEM_UTILIZATION_BLUEPRINT.md` | Runtime strategy; deployment configurations |
| `docs/HORUS_ARITHMETIC_ENVELOPE.md` | Arithmetic constraints; depth limits; floor attractor schedule |
