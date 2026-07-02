`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_pgate_ctrl  (Power-Proportional Memory Gating Controller)
// Project  : Horus Engine — Native Fractional Engine
// File     : horus_pgate_ctrl.v
//
// ── Naming note ──────────────────────────────────────────────────────────────
// Named 'horus_pgate_ctrl' rather than 'horus_controller' because the repo
// already contains 'horus_controller.v' — the One-Hot Moore FSM that sequences
// the systolic array compute window (IDLE→SETUP→STREAM→READY).  This module
// is an independent, architectural-layer-zero comparator that has no knowledge
// of that FSM's state and can be dropped into any NFE-based system.
//
// ── Purpose ──────────────────────────────────────────────────────────────────
// Compares the running MAC count (current_op_count) against the host-specified
// tile budget (host_tile_depth) and outputs a combinational enable gate.
//
//   accum_en_gated = 1   →  accumulation is permitted
//   accum_en_gated = 0   →  accumulation is silently gated (dropped)
//
// The gate is COMBINATIONAL so the decision is visible to horus_nfe on the
// same clock cycle — no pipeline latency is added to the compute path.
//
// ── Design rationale: why combinational output ───────────────────────────────
// A registered output would appear 1 cycle after the counter crosses the
// tile_depth threshold, causing one extra MAC to slip through before gating.
// For a power gating intent ("use only the memory depth you need"), a silent
// 1-MAC overrun is unacceptable.  Combinational output is correct and precise.
//
// For physical synthesis: insert a target-library ICG (Integrated Clock Gate)
// cell at the point where accum_en_gated drives the flip-flop clock enable in
// the accumulator register bank.  The combinational path is short (one 16-bit
// comparator, ~2 LUT levels) and will close timing easily.
//
// ── Clock and reset ───────────────────────────────────────────────────────────
// clk and rst_n are included per the system interface contract and for future
// extensions (e.g. pipelined pre-fetch, hysteresis guard, drain-before-gate).
// They are not used by the current combinational logic.
//
// ── Gate rule ─────────────────────────────────────────────────────────────────
//   host_tile_depth == 0   →  unlimited (gate permanently open; backward compat)
//   host_tile_depth == N>0 →  gate closes when current_op_count reaches N
//
// ── Interface ─────────────────────────────────────────────────────────────────
//   Inputs
//     clk               1     System clock (reserved for future registered path)
//     rst_n             1     Active-low synchronous reset (reserved)
//     host_tile_depth   6     Budget set by host at dispatch time. 0 = unlimited.
//                             Range 1–63 MACs per tile.
//     current_op_count  16    Running MAC count driven by horus_system counter.
//
//   Outputs
//     accum_en_gated    1     Combinational. High when accumulation is allowed.
//                             Wire directly to horus_nfe accum_en (in series with
//                             the host's own accum_en request).
// ============================================================================

module horus_pgate_ctrl (
    input  wire        clk,               // reserved — future registered extension
    input  wire        rst_n,             // reserved — future registered extension

    input  wire [5:0]  host_tile_depth,   // tile MAC budget (0 = unlimited)
    input  wire [15:0] current_op_count,  // running count from horus_system

    output wire        accum_en_gated     // combinational gate enable
);

    // =========================================================================
    // Gate logic
    // =========================================================================
    // Pure unsigned 16-bit comparison.  No special-case sentinels.
    //
    //   tile_depth = 0  →  current_op_count < 0  →  always FALSE  →  gate CLOSED
    //   tile_depth = N  →  open for exactly N MACs, then closed
    //   tile_depth = 63 (max) → open for 63 MACs (6-bit maximum)
    //
    // This exploits unsigned arithmetic directly: no value of current_op_count
    // can ever be less than zero, so tile_depth=0 is a safe "power-off" state.
    // There is no "unlimited" sentinel; the host sets exactly the MAC budget
    // required for its tile.
    //
    // The 6-bit host_tile_depth is zero-extended to 16 bits before comparison
    // to match the width of current_op_count and prevent synthesis truncation.

    assign accum_en_gated = (current_op_count < {10'd0, host_tile_depth});

endmodule
