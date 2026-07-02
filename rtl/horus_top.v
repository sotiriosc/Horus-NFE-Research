`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_top
// Project  : Horus Engine
// File     : horus_top.v
//
// Purpose
//   Top-level structural integration wrapper for the Horus Engine.  Ties the
//   FSM controller and the 4×4 systolic array together into a single compile
//   unit that can be synthesised, place-and-routed, or dropped into a larger
//   SoC memory map.
//
//   This file is PURELY structural — it contains no logic, only wire
//   declarations, one polarity-adapt assign, and two module instantiations.
//   All arithmetic and state-machine logic lives in the sub-modules.
//
// ─────────────────────────────────────────────────────────────────────────────
// Sub-Module Hierarchy
// ─────────────────────────────────────────────────────────────────────────────
//
//   horus_top
//   ├── u_ctrl   : horus_controller   (One-Hot Moore FSM)
//   └── u_array  : horus_systolic_array #(ROWS=4, COLS=4)  (4×4 PE grid)
//
// ─────────────────────────────────────────────────────────────────────────────
// Full Interconnect Block Diagram
// ─────────────────────────────────────────────────────────────────────────────
//
//                        ╔══════════════════════════════════════════════╗
//  clk ─────────────────►║                  horus_top                   ║
//  rst ──[~]─► rst_n ───►║                                              ║
//                        ║  ┌──────────────────────────────────────┐   ║
//  start_compute ────────╬─►│         horus_controller  (u_ctrl)   │   ║
//  result_ack    ────────╬─►│                                      │   ║
//                        ║  │   IDLE→SETUP→STREAM(7cy)→READY→IDLE  │   ║
//                        ║  │                                      │   ║
//                        ║  │   accum_clr ────────────────────┐   │   ║
//                        ║  │   accum_en  ─────────────────┐  │   │   ║
//                        ║  │   data_valid ─────────────────╬──╬───╬──►║─► data_valid
//                        ║  └───────────────────────────────┼──┼───┘   ║
//                        ║                                   │  │       ║
//                        ║  ┌────────────────────────────────┼──┼───┐  ║
//  row_act_0 ────────────╬─►│   horus_systolic_array (u_array)│  │   │  ║
//  row_act_1 ────────────╬─►│   #(ROWS=4, COLS=4)           │  │   │  ║
//  row_act_2 ────────────╬─►│                           accum_en◄──┘  │  ║
//  row_act_3 ────────────╬─►│                           accum_clr◄───┘  │  ║
//  col_wt_0  ────────────╬─►│                                      │  ║
//  col_wt_1  ────────────╬─►│   ┌──────────────────────────────┐  │  ║
//  col_wt_2  ────────────╬─►│   │   4×4 PE Grid (16 horus_nfe) │  │  ║
//  col_wt_3  ────────────╬─►│   │   Output-Stationary Topology │  │  ║
//                        ║  │   └──────────────────────────────┘  │  ║
//                        ║  │                                      │  ║
//                        ║  │   row_out_0 ──────────────────────────╬──►║─► row_out_0
//                        ║  │   row_out_1 ──────────────────────────╬──►║─► row_out_1
//                        ║  │   row_out_2 ──────────────────────────╬──►║─► row_out_2
//                        ║  │   row_out_3 ──────────────────────────╬──►║─► row_out_3
//                        ║  └──────────────────────────────────────┘  ║
//                        ╚══════════════════════════════════════════════╝
//
// ─────────────────────────────────────────────────────────────────────────────
// Internal Signal Inventory
// ─────────────────────────────────────────────────────────────────────────────
//
//   rst_n      Active-low reset derived by inverting the active-high top port.
//              A single assign drives both sub-module rst_n ports so they
//              always reset in lockstep.
//
//   w_accum_clr  1-bit control fabric wire.
//              Driven by u_ctrl.accum_clr; consumed by u_array.accum_clr.
//              Asserted for exactly 1 clock cycle in the SETUP FSM state.
//
//   w_accum_en   1-bit control fabric wire.
//              Driven by u_ctrl.accum_en; consumed by u_array.accum_en.
//              Asserted for exactly 7 clock cycles in the STREAM FSM state.
//
// ─────────────────────────────────────────────────────────────────────────────
// Reset Polarity Convention
// ─────────────────────────────────────────────────────────────────────────────
//   Top-level port : rst   — active-HIGH  (board / testbench convention)
//   Sub-module ports: rst_n — active-LOW   (horus_controller, horus_systolic_array)
//
//   Conversion: assign rst_n = ~rst;
//   This is a combinational inversion, not a synchroniser.  If rst is driven
//   from an asynchronous external pin on an FPGA, insert a reset synchroniser
//   (two-flop chain) before this module in the board-level wrapper.
//
// ─────────────────────────────────────────────────────────────────────────────
// Parameter Interlocking Notes
// ─────────────────────────────────────────────────────────────────────────────
//   horus_systolic_array : ROWS=4, COLS=4
//     → Pipeline fill depth = max(ROWS-1, COLS-1) = 3 STREAM cycles
//     → All 16 PEs see valid coincident data by STREAM cycle 4 (cycle_cnt=3)
//
//   horus_controller : FILL_CYCLES=6  (7 STREAM cycles, cycle_cnt 0..6)
//     → 3 cycles for pipeline fill  + 4 cycles of steady-state accumulation
//     → Changing ROWS or COLS requires updating FILL_CYCLES accordingly:
//         FILL_CYCLES = max(new_ROWS-1, new_COLS-1) + desired_accumulation_cycles
//
// ─────────────────────────────────────────────────────────────────────────────
// Computation Window Protocol (host-side summary)
// ─────────────────────────────────────────────────────────────────────────────
//   1. Present row_act_0..3 and col_wt_0..3 (may be held or streamed).
//   2. Pulse start_compute high for ≥1 cycle.
//   3. Wait for data_valid to assert (9 cycles after start_compute is sampled).
//   4. Latch row_out_0..3 — valid dot-product results are stable here.
//   5. Pulse result_ack high for ≥1 cycle to return the FSM to IDLE.
//   6. Repeat from step 1 for the next computation window.
// ============================================================================

module horus_top (
    // ── Global timing and reset ───────────────────────────────────────────────
    input  wire        clk,
    input  wire        rst,           // Active-HIGH top-level reset
                                      // (inverted to rst_n for both sub-modules)

    // ── Host computation handshake ────────────────────────────────────────────
    input  wire        start_compute, // Pulse: begin a new computation window
    input  wire        result_ack,    // Pulse: host has latched row_out_*; return to IDLE
    output wire        data_valid,    // Level: row_out_0..3 are stable and valid

    // ── Left-boundary Row Activation inputs  (13-bit NFE encoded) ────────────
    input  wire [12:0] row_act_0,     // Activation entering row 0 from the left
    input  wire [12:0] row_act_1,     // Activation entering row 1 from the left
    input  wire [12:0] row_act_2,     // Activation entering row 2 from the left
    input  wire [12:0] row_act_3,     // Activation entering row 3 from the left

    // ── Top-boundary Column Weight inputs  (13-bit NFE encoded) ──────────────
    input  wire [12:0] col_wt_0,      // Weight entering column 0 from the top
    input  wire [12:0] col_wt_1,      // Weight entering column 1 from the top
    input  wire [12:0] col_wt_2,      // Weight entering column 2 from the top
    input  wire [12:0] col_wt_3,      // Weight entering column 3 from the top

    // ── Row dot-product outputs  (32-bit accumulated sums) ───────────────────
    output wire [31:0] row_out_0,     // Accumulated dot product for row 0
    output wire [31:0] row_out_1,     // Accumulated dot product for row 1
    output wire [31:0] row_out_2,     // Accumulated dot product for row 2
    output wire [31:0] row_out_3      // Accumulated dot product for row 3
);

    // =========================================================================
    // Reset polarity adapter
    // ─────────────────────────────────────────────────────────────────────────
    // Both sub-modules use active-low rst_n.  The single inversion here keeps
    // both modules in perfect lockstep reset regardless of when rst is asserted.
    // =========================================================================
    wire rst_n;
    assign rst_n = ~rst;

    // =========================================================================
    // Control fabric wires
    // ─────────────────────────────────────────────────────────────────────────
    // These two wires are the only signals that connect the controller to the
    // array.  They carry the FSM-sequenced accumulator protocol:
    //   w_accum_clr  high for 1 cycle in SETUP  → clears all 16 PE accumulators
    //   w_accum_en   high for 7 cycles in STREAM → accumulates PE dot products
    // =========================================================================
    wire w_accum_clr;
    wire w_accum_en;

    // =========================================================================
    // u_ctrl : horus_controller
    // ─────────────────────────────────────────────────────────────────────────
    // One-hot Moore FSM.  Produces the two 1-bit control wires and the
    // data_valid status flag.  Does not touch any data path — purely control.
    // =========================================================================
    horus_controller u_ctrl (
        // ── Global ─────────────────────────────────────────────────────────
        .clk            (clk),
        .rst_n          (rst_n),

        // ── Host handshake ──────────────────────────────────────────────────
        .start_compute  (start_compute),
        .result_ack     (result_ack),

        // ── Control fabric outputs → u_array control inputs ─────────────────
        .accum_clr      (w_accum_clr),
        .accum_en       (w_accum_en),

        // ── Status flag → top-level port ────────────────────────────────────
        .data_valid     (data_valid)
    );

    // =========================================================================
    // u_array : horus_systolic_array  #(ROWS=4, COLS=4)
    // ─────────────────────────────────────────────────────────────────────────
    // 4×4 output-stationary systolic PE grid.  All 16 horus_nfe processing
    // elements are instantiated inside here via generate loops.  The two
    // control wires from u_ctrl gate the accumulation window.
    //
    // Data path routing inside u_array:
    //   act_reg[r][c] shift-register fabric carries row activations RIGHT
    //   wt_reg[r][c]  shift-register fabric carries column weights DOWNWARD
    //   pe_accum[r][c] 32-bit accumulated sum per PE
    //   row_out_r = sum of pe_accum[r][0..3]  (combinational adder tree)
    // =========================================================================
    horus_systolic_array #(
        .ROWS (4),
        .COLS (4)
    ) u_array (
        // ── Global ─────────────────────────────────────────────────────────
        .clk            (clk),
        .rst_n          (rst_n),

        // ── Control fabric inputs ← u_ctrl control outputs ──────────────────
        .accum_clr      (w_accum_clr),
        .accum_en       (w_accum_en),

        // ── Left-boundary row activation inputs ─────────────────────────────
        .row_act_0      (row_act_0),
        .row_act_1      (row_act_1),
        .row_act_2      (row_act_2),
        .row_act_3      (row_act_3),

        // ── Top-boundary column weight inputs ────────────────────────────────
        .col_wt_0       (col_wt_0),
        .col_wt_1       (col_wt_1),
        .col_wt_2       (col_wt_2),
        .col_wt_3       (col_wt_3),

        // ── Row dot-product outputs ───────────────────────────────────────────
        .row_out_0      (row_out_0),
        .row_out_1      (row_out_1),
        .row_out_2      (row_out_2),
        .row_out_3      (row_out_3)
    );

endmodule
