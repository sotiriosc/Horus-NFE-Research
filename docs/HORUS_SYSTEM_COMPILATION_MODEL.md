# HORUS v3 System Compilation Model

**Document type:** Conceptual Architecture Model  
**Authority:** HBS-11 through HBS-14 and HORUS-C1 Compiler Specification  
**Version:** 1.0 · 2026-07-02  

---

## Overview

This document defines the structural relationship between three independently operating system layers in HORUS v3: the hardware arithmetic core, the accumulation system, and the compiler routing layer. It provides visual diagrams, separation contracts, and flow specifications for each layer boundary.

---

## 1. Layer Separation Contract

```
╔═══════════════════════════════════════════════════════════════╗
║              HORUS v3 COMPILATION MODEL                       ║
╠═══════════════════════════════════════════════════════════════╣
║                                                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │  LAYER C — COMPILER ROUTING                             │  ║
║  │                                                         │  ║
║  │  Input:  high-level workload (MAC chains, cancel pairs, │  ║
║  │          scaling ops, composition chains)               │  ║
║  │                                                         │  ║
║  │  Output: (op_a, op_b, op_sel, mode_tag, accum_en,       │  ║
║  │           accum_clr, host_tile_depth) sequences         │  ║
║  │                                                         │  ║
║  │  Decisions: region classification, mode selection,      │  ║
║  │             depth budget, normalization injection,       │  ║
║  │             ABMP trigger                                │  ║
║  │                                                         │  ║
║  │  CANNOT: modify result, alter flags, change boundaries  │  ║
║  └───────────────────┬─────────────────────────────────────┘  ║
║                      │ emits instruction stream               ║
║                      ▼                                        ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │  LAYER L2 — ACCUMULATION SYSTEM  (horus_nfe accum path)│  ║
║  │                                                         │  ║
║  │  Input:  mode_tag, accum_en, accum_clr, host_tile_depth │  ║
║  │          + result from Layer L1                         │  ║
║  │                                                         │  ║
║  │  Behavior:                                              │  ║
║  │    000 STD:  accum_reg += result                        │  ║
║  │    001 BIAS: accum_reg += result + BIAS_LUT[e_a]        │  ║
║  │    010 PRSC: accum_reg += {sign, E−1, frac}             │  ║
║  │    011 SAFE: accum_reg = min(accum_reg+result, 2^32−1)  │  ║
║  │                                                         │  ║
║  │  Output:  accum_out (1-cycle latency), op_count,        │  ║
║  │           accum_full                                    │  ║
║  │                                                         │  ║
║  │  CANNOT: modify result, alter UF/OVF flags              │  ║
║  └───────────────────┬─────────────────────────────────────┘  ║
║                      │                                        ║
║     ─── ─── ─── DECOUPLING BOUNDARY ─── ─── ─── ───          ║
║     Policy path and arithmetic path are independent.          ║
║     (Proven: HBS-14, 384 tests, 0 cross-boundary events.)     ║
║                      │                                        ║
║                      ▼                                        ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │  LAYER L1 — ARITHMETIC CORE  (horus_nfe compute path)  │  ║
║  │                                                         │  ║
║  │  Input:  op_a, op_b, op_sel                             │  ║
║  │                                                         │  ║
║  │  Physics: MUL exponent sum E_a + E_b − 32               │  ║
║  │           ADD Thoth Rollover: f_a + Δ ≥ 64 → E+1        │  ║
║  │           SUB Guard-B: 2-cycle normalize pipeline        │  ║
║  │           UF: E_result < 0  → NFE_FLOOR (0x000)         │  ║
║  │           OVF: E_result > 63 → NFE_MAXPOS (0x1FFF)      │  ║
║  │                                                         │  ║
║  │  Output:  result [12:0], underflow_flag, exp_ovf_flag,  │  ║
║  │           rollover_flag                                 │  ║
║  │                                                         │  ║
║  │  CANNOT: be modified by compiler or policy              │  ║
║  └─────────────────────────────────────────────────────────┘  ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
```

**Separation invariant:** Layer C (compiler) may only write (op_sel, mode_tag, accum_en, accum_clr, host_tile_depth, op_a, op_b). It reads (result, accum_out, underflow_flag, exp_ovf_flag, rollover_flag, op_count, accum_full). It has no write access to Layer L1 physics.

---

## 2. Workload-to-Region Mapping Diagram

```
INPUT WORKLOAD
     │
     ▼
┌────────────────────────────────────────────────────────────────┐
│  WORKLOAD CLASSIFIER                                           │
│                                                                │
│  Extract:  E_pred = predicted result exponent                  │
│  Classify: workload_class ∈ {CLASS_A, B, C, D}                 │
│  Measure:  chain_depth, f_pred, op_sel                         │
└──────┬─────────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────────────────┐
│  REGION CLASSIFICATION ENGINE  (deterministic; no fallback)      │
│                                                                  │
│  E_pred ≤ 15 ─────────────────────────────────► COLLAPSE        │
│                                                                  │
│  E_pred ∈ [16..19] ───────────────────────────► TRANSITION_LOW  │
│  (or chain_depth ≥ headroom − 2)                                 │
│                                                                  │
│  E_pred ∈ [20..43] ───────────────────────────► STABLE          │
│                                                                  │
│  E_pred ∈ [44..47] ───────────────────────────► TRANSITION_HIGH │
│  (or ADD + f ≥ 32)                                               │
│                                                                  │
│  E_pred ≥ 48 ─────────────────────────────────► SATURATION      │
│                                                                  │
└────────────────────────────────────┬─────────────────────────────┘
                                     │
                                     ▼
                       ┌─────────────────────────┐
                       │  BOUNDARY HAZARD CHECK  │
                       │  (§1.8 ABMP detector)   │
                       └──────┬──────────────────┘
                              │
               ┌──────────────┴──────────────┐
               │ NO_HAZARD                   │ HAZARD
               ▼                             ▼
    ┌──────────────────┐         ┌───────────────────────┐
    │  MODE SELECTION  │         │  ABMP PROTOCOL        │
    │  (§1.4 table)    │         │  1. Snapshot accum    │
    └──────────────────┘         │  2. Normalize (TWO^k) │
               │                 │     mode_tag = 010     │
               │                 │  3. Resume safe zone  │
               ▼                 └──────────┬────────────┘
    ┌──────────────────┐                    │
    │  INSTRUCTION     │◄───────────────────┘
    │  EMISSION        │
    └──────────────────┘
```

---

## 3. Mode Tag Selection Logic

```
             E_pred ∈ [20..43]
             workload_class?
                  │
     ┌────────────┼────────────┬────────────────┐
     ▼            ▼            ▼                ▼
  CLASS_A      CLASS_B       CLASS_C          CLASS_D
  (MAC chain)  (Cancel pair) (Scale step)    (Composition)
     │            │            │                │
  depth ≤ 8?   LUT filled?  accum_en = 0     depth > 8?
  │       │    │       │         │           │       │
  YES     NO   YES     NO        │           NO      YES
  │       │    │       │         │           │       │
  000    010  001     000        │           000    010
  (STD) (PRSC)(BIAS) (STD)      │          (STD) (PRSC)
              [warn]             │
                                 ▼
                           No mode needed
                           (transport op)


  E_pred ∈ [16..19] ──────────────────► 010 (PRSC) + ABMP
  E_pred ∈ [44..47] ──────────────────► 011 (SAFE) or 010 (PRSC)
  E_pred ≤ 15 ─────────────────────────► skip accum / 011 (SAFE)
  E_pred ≥ 48 ─────────────────────────► skip accum / 011 (SAFE)
```

---

## 4. Boundary Handling Flow

### Collapse Boundary (E = 15 ↔ 16)

```
 Current E:  21  20  19  18  17  16  15  14   (decreasing via HALF chain)
              │   │   │   │   │   │   │   │
 Region:    STABLE──────────TRANS──CLIFF──COLLAPSE
              │   │   │   │   │   │
 Compiler:  000 000 010 010 010 010 ← mode escalates in TRANS zone
                          │   │
                   ABMP fires here (headroom = 2 steps before cliff)
                          │
                     ┌────┴──────────────────────────────┐
                     │  Phase 1: SNAPSHOT                │
                     │    read accum_out → external buf  │
                     │    accum_clr pulse                │
                     │                                   │
                     │  Phase 2: NORMALIZE (scale up)    │
                     │    MUL(x, NFE_TWO) × k            │
                     │    mode_tag = 010 (PRSC)          │
                     │    accum_en = 0 (transport only)  │
                     │    E → E+k → ≥ 20                 │
                     │                                   │
                     │  Phase 3: RESUME                  │
                     │    mode_tag = 000 or 010           │
                     │    accum_clr (open fresh window)  │
                     │    host_tile_depth = new budget   │
                     └───────────────────────────────────┘

 If ABMP NOT triggered (depth limit reached at cliff):
   UF fires → underflow_flag = 1 → result = NFE_FLOOR
   Correct response: accum_clr, log event, discard epoch, do NOT retry same operand
```

### Saturation Boundary (E = 47 ↔ 48)

```
 Current E:  41  43  45  46  47  48   (increasing via ADD or scale-up)
              │   │   │   │   │   │
 Region:    STABLE──────TRANS──CLIFF──SAT
              │   │   │   │   │
 Compiler:  000 000 010 011 011 ← mode escalates at approach
                      │   │
                ABMP: if ADD + f≥32 at E=47: ROLLOVER HAZARD
                      prevent ADD or pre-scale operand
                          │
                     ┌────┴──────────────────────────────┐
                     │  Option A: Scale-Down              │
                     │    MUL(x, NFE_HALF) to lower E    │
                     │    mode_tag = 010 during scaling   │
                     │                                   │
                     │  Option B: Ceiling Gate           │
                     │    Allow OVF to fire              │
                     │    Observe exp_ovf_flag           │
                     │    Use as binary "above ceiling"  │
                     │    signal — do NOT read result    │
                     │                                   │
                     │  Option C: Snapshot + Reset       │
                     │    Read accum_out before cliff    │
                     │    accum_clr; discard OVF epoch   │
                     └───────────────────────────────────┘
```

---

## 5. Explicit Layer Separation Diagram

```
╔═══════════════════════════════════════════════════════════════════╗
║  SEPARATION OF CONCERNS                                           ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  ┌─────────────────────┐   ┌─────────────────────┐               ║
║  │  COMPILER           │   │  HARDWARE            │               ║
║  │  (LAYER C)          │   │  (LAYERS L1, L2)     │               ║
║  │                     │   │                      │               ║
║  │  DEFINES:           │   │  DEFINES:            │               ║
║  │  • region routing   │   │  • arithmetic physics│               ║
║  │  • mode_tag choice  │   │  • UF/OVF conditions │               ║
║  │  • epoch boundaries │   │  • Thoth Rollover    │               ║
║  │  • tile depth       │   │  • accum policies    │               ║
║  │  • ABMP triggers    │   │  • flag propagation  │               ║
║  │                     │   │                      │               ║
║  │  CANNOT:            │   │  CANNOT:             │               ║
║  │  • alter physics    │   │  • be reconfigured   │               ║
║  │  • modify result    │   │  • suppress flags    │               ║
║  │  • suppress flags   │   │  • change boundaries │               ║
║  │  • shift boundaries │   │  • vary by mode_tag  │               ║
║  └─────────────────────┘   └─────────────────────┘               ║
║           │                           ▲                           ║
║           │  instruction stream       │  observations             ║
║           │  (op_a,op_b,op_sel,       │  (result, accum_out,      ║
║           │   mode_tag,accum_en,      │   uf_flag, ovf_flag,      ║
║           │   accum_clr,tile_depth)   │   rollover_flag,          ║
║           └───────────────────────────┘   op_count, accum_full)  ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║  INTERFACE CONTRACT                                               ║
║                                                                   ║
║  Compiler WRITES:  op_a, op_b, op_sel, mode_tag, accum_en,       ║
║                    accum_clr, host_tile_depth                     ║
║                                                                   ║
║  Compiler READS:   result, accum_out, underflow_flag,            ║
║                    exp_ovf_flag, rollover_flag, op_count,        ║
║                    accum_full                                     ║
║                                                                   ║
║  Compiler NEVER:   modifies RTL, tunes LUTs at runtime,          ║
║                    suppresses flags, assumes cross-region        ║
║                    arithmetic continuity                          ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

## 6. Execution Phase Transition Map

This map shows all valid phase transitions and the compiler actions required at each transition boundary.

```
                         ┌────────────┐
                         │  COLLAPSE  │
                         │  E = 0–15  │
                         │            │
                         │ result =   │
                         │ NFE_FLOOR  │
                         │ (no info)  │
                         └─────┬──────┘
                               │ ADD rescue (E=15, f≥32)
                               │ → E+1 = 16 (partial recovery)
                               ▼
 ┌────────────────┐   ┌────────────────────┐   ┌───────────────────┐
 │ TRANSITION_LOW │──►│                    │◄──│ TRANSITION_HIGH   │
 │  E = 16–19     │   │     STABLE BAND    │   │  E = 44–47        │
 │                │   │     E = 20–43      │   │                   │
 │ mode = 010     │   │                    │   │ mode = 010/011    │
 │ ABMP required  │   │   mode = 000       │   │ ABMP required     │
 └────────┬───────┘   │   (or 001/010/011  │   └─────────┬─────────┘
          │           │    per workload)   │             │
  scale-up│           │                   │   scale-down│
  required│           │  All operations   │   required  │
          │           │  valid; full info  │             │
          │           │  preserved        │             │
          │           └────────────────────┘             │
          │                                               │
          │                                               │ ADD at E=47
          │                                               │ + f≥32 → E=48
          │                                               ▼
          │                                       ┌───────────────┐
          │                                       │  SATURATION   │
          │                                       │  E = 48–63    │
          │                                       │               │
          │                                       │ result =      │
          │                                       │ NFE_MAXPOS    │
          │                                       │ (bounded cap) │
          │                                       └───────────────┘
          │
          │ [ABMP: snapshot + scale-up returns here]
          └─────────────────────────────────────────► STABLE
```

**Phase transition rules:**
- COLLAPSE → STABLE: ADD rescue (E=15, f≥32) — partial exponent recovery, fraction partial
- COLLAPSE → COLLAPSE: MUL (floor attractor) — absorbing state
- STABLE → TRANSITION_LOW: progressive scale-down toward E=16
- STABLE → TRANSITION_HIGH: progressive scale-up toward E=47
- TRANSITION → COLLAPSE: MUL at E=15 → UF (deterministic)
- TRANSITION → SATURATION: ADD at E=47 + f≥32 → Thoth Rollover to E=48
- STABLE → STABLE: all normal operations
- SATURATION → SATURATION: MUL in saturation → NFE_MAXPOS (absorbing)

---

## 7. Full Compilation Pipeline

```
HIGH-LEVEL OPERATION (workload description)
     │
     │  1. Static Analysis Pass
     ▼
┌─────────────────────────────────────────────┐
│  MAGNITUDE ESTIMATION                        │
│  E_pred = f(op_a, op_b, op_sel, depth)       │
│  f_pred = g(op_a, op_b, op_sel)              │
│  workload_class = classify(operation_type)   │
└──────────────────┬──────────────────────────┘
                   │
                   │  2. Region Classification
                   ▼
┌─────────────────────────────────────────────┐
│  REGION CLASSIFIER  (Rules R0–R5)            │
│  Output: region ∈ {COLLAPSE, TRANS_L,        │
│                    STABLE, TRANS_H, SAT}     │
└──────────────────┬──────────────────────────┘
                   │
                   │  3. Hazard Detection
                   ▼
┌─────────────────────────────────────────────┐
│  BOUNDARY HAZARD DETECTOR                   │
│  Input: E_pred, f_pred, op_sel, depth       │
│  Output: hazard_type or NO_HAZARD            │
└──────────────────┬──────────────────────────┘
                   │
         ┌─────────┴──────────┐
         │ NO_HAZARD           │ HAZARD
         ▼                     ▼
┌────────────────┐   ┌─────────────────────────┐
│ MODE SELECTOR  │   │ ABMP GENERATOR          │
│ (§1.4 table)   │   │ Snapshot instruction    │
│                │   │ Normalize sequence       │
│ Output: mode   │   │ (mode_tag=010 during)   │
└────────┬───────┘   │ Resume instruction      │
         │           └──────────┬──────────────┘
         │                      │
         └──────────┬───────────┘
                    │  4. Instruction Assembly
                    ▼
┌──────────────────────────────────────────────────┐
│  INSTRUCTION EMITTER                             │
│                                                  │
│  Output tuple per cycle:                         │
│  (op_a, op_b, op_sel, mode_tag,                  │
│   accum_en, accum_clr, host_tile_depth)          │
└──────────────────────────────────────────────────┘
                    │
                    │  Runtime
                    ▼
┌──────────────────────────────────────────────────┐
│  horus_system                                    │
│                                                  │
│   op_a, op_b, op_sel ──► horus_nfe (Layer L1)    │
│             mode_tag ──► policy decoder (L2)     │
│            accum_en  ──► pgate_ctrl ──► L2       │
│            accum_clr ──► L2, L3 counter          │
│      host_tile_depth ──► pgate_ctrl (L3)         │
│                                                  │
│   result         ◄── L1 arithmetic core         │
│   accum_out      ◄── L2 accumulator             │
│   underflow_flag ◄── L1 (policy-invariant)      │
│   exp_ovf_flag   ◄── L1 (policy-invariant)      │
│   rollover_flag  ◄── L1 Thoth Rollover          │
│   op_count       ◄── L3 MAC counter             │
│   accum_full     ◄── L3 budget gate             │
└──────────────────────────────────────────────────┘
                    │
                    ▼
            OBSERVATION LAYER
            (host reads flags,
             snapshot management,
             external accumulation)
```

---

## 8. Related Documents

| Document | Relationship |
|---|---|
| `docs/HORUS_C1_COMPILER_SPEC.md` | Full compiler specification (this diagram's source) |
| `docs/EXECUTION_MAPPING.md` | Formal execution contract; region semantics |
| `docs/HORUS_V3_FINAL_SPEC.md` | Hardware specification; physics compiler maps onto |
| `docs/HORUS_SYSTEM_UTILIZATION_BLUEPRINT.md` | Deployment configurations |
| `rtl/horus_nfe.v` | Layer L1/L2 implementation |
| `rtl/horus_pgate_ctrl.v` | Layer L3 implementation |
