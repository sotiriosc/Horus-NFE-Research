`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_input_buffer
// Project  : Horus Engine
// File     : horus_input_buffer.v
//
// Purpose
//   Hardware skew buffer that sits between the host memory interface and the
//   left/top boundary pins of horus_systolic_array.  Accepts all four 13-bit
//   NFE words simultaneously on a flat 52-bit parallel bus and staggers them
//   by 0, 1, 2, and 3 clock cycles so that the diagonal wavefront of valid
//   data propagates correctly through the 4×4 PE grid.
//
// ─────────────────────────────────────────────────────────────────────────────
// Why Input Skewing Is Required
// ─────────────────────────────────────────────────────────────────────────────
//
//   Inside horus_systolic_array, act_reg[r][c] shifts row activations ONE
//   column to the RIGHT per clock edge, and wt_reg[r][c] shifts column
//   weights ONE row DOWN per clock edge.
//
//   For PE[r,c] to multiply its correct pair (A[r], W[c]):
//     A[r] must reach the left boundary AT cycle T  − c
//     W[c] must reach the top  boundary AT cycle T  − r
//   for some reference meeting time T.
//
//   If the host presents all four inputs SIMULTANEOUSLY (same clock cycle),
//   A[0]..A[3] and W[0]..W[3] arrive at the array boundary at the same
//   instant and each activation/weight token fans out along a row/column
//   lane independently.  A[r] reaches PE[r,c] at cycle c (it has to travel
//   c columns), and W[c] reaches PE[r,c] at cycle r (r rows).  They are
//   coincident only on the diagonal where r == c.
//
//   The skew buffer compensates by delaying channel k by k cycles so that:
//     Channel 0: enters cycle C+0  → reaches PE[r,0] at cycle C+r   ✓
//     Channel 1: enters cycle C+1  → reaches PE[r,1] at cycle C+1+r ✓
//     Channel 2: enters cycle C+2  → reaches PE[r,2] at cycle C+2+r ✓
//     Channel 3: enters cycle C+3  → reaches PE[r,3] at cycle C+3+r ✓
//   All four arrive at PE[r,c] at cycle C + r + c  — coincident for every PE.
//
// ─────────────────────────────────────────────────────────────────────────────
// Input Bus Bit-Slice Map  (52-bit flat, LSB = channel 0)
// ─────────────────────────────────────────────────────────────────────────────
//
//   Bits [12: 0]  →  channel 0  (13-bit NFE word, row/col index 0)
//   Bits [25:13]  →  channel 1  (13-bit NFE word, row/col index 1)
//   Bits [38:26]  →  channel 2  (13-bit NFE word, row/col index 2)
//   Bits [51:39]  →  channel 3  (13-bit NFE word, row/col index 3)
//
// ─────────────────────────────────────────────────────────────────────────────
// Pipeline Architecture
// ─────────────────────────────────────────────────────────────────────────────
//
//                 ┌────────────────────────────────────────────────────┐
//  data_in[12:0]  │  CH 0  (0-cycle delay)                             │─► out_ch0
//                 │         wire pass-through — no register stage      │
//                 ├────────────────────────────────────────────────────┤
//  data_in[25:13] │  CH 1  (1-cycle delay)                             │
//                 │         ┌──────┐                                   │─► out_ch1
//                 │  ───────►  Q0  ├───────────────────────────────────│
//                 │         └──────┘                                   │
//                 ├────────────────────────────────────────────────────┤
//  data_in[38:26] │  CH 2  (2-cycle delay)                             │
//                 │         ┌──────┐   ┌──────┐                        │─► out_ch2
//                 │  ───────►  Q0  ├───►  Q1  ├────────────────────────│
//                 │         └──────┘   └──────┘                        │
//                 ├────────────────────────────────────────────────────┤
//  data_in[51:39] │  CH 3  (3-cycle delay)                             │
//                 │         ┌──────┐   ┌──────┐   ┌──────┐            │─► out_ch3
//                 │  ───────►  Q0  ├───►  Q1  ├───►  Q2  ├────────────│
//                 │         └──────┘   └──────┘   └──────┘            │
//                 └────────────────────────────────────────────────────┘
//
//  All flip-flops (Q0..Q2) are enabled by input_valid.  When input_valid is
//  deasserted the pipeline holds its last captured values — channels 1-3
//  freeze in place while channel 0 tracks data_in combinationally.
//
// ─────────────────────────────────────────────────────────────────────────────
// Timing Waveform (steady-state streaming, one NFE word per cycle)
// ─────────────────────────────────────────────────────────────────────────────
//
//  Cycle        │  0  │  1  │  2  │  3  │  4  │  5  │  6  │
//  ─────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
//  data_in ch0  │  A0 │  A1 │  A2 │  A3 │  …  │     │     │
//  data_in ch1  │  B0 │  B1 │  B2 │  B3 │  …  │     │     │
//  data_in ch2  │  C0 │  C1 │  C2 │  C3 │  …  │     │     │
//  data_in ch3  │  D0 │  D1 │  D2 │  D3 │  …  │     │     │
//  ─────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
//  out_ch0      │  A0 │  A1 │  A2 │  A3 │  …  │     │     │  0-cycle
//  out_ch1      │  —  │  B0 │  B1 │  B2 │  B3 │  …  │     │  1-cycle
//  out_ch2      │  —  │  —  │  C0 │  C1 │  C2 │  C3 │  …  │  2-cycle
//  out_ch3      │  —  │  —  │  —  │  D0 │  D1 │  D2 │  D3 │  3-cycle
//
//  At cycle 3 the diagonal pair A3, B2, C1, D0 is simultaneously present
//  on the four output buses — this is the skewed wavefront that feeds the
//  systolic array column 0 for one vector-element step.
//
// ─────────────────────────────────────────────────────────────────────────────
// Connection to horus_top
// ─────────────────────────────────────────────────────────────────────────────
//
//   For row activation feed:
//     .out_ch0 → horus_top.row_act_0     (no skew — immediate)
//     .out_ch1 → horus_top.row_act_1     (1-cycle skew)
//     .out_ch2 → horus_top.row_act_2     (2-cycle skew)
//     .out_ch3 → horus_top.row_act_3     (3-cycle skew)
//
//   For column weight feed (use a second instance of this module):
//     .out_ch0 → horus_top.col_wt_0
//     .out_ch1 → horus_top.col_wt_1
//     .out_ch2 → horus_top.col_wt_2
//     .out_ch3 → horus_top.col_wt_3
// ============================================================================

module horus_input_buffer (
    input  wire        clk,
    input  wire        rst_n,        // Active-low synchronous reset

    // ── Control ───────────────────────────────────────────────────────────────
    input  wire        input_valid,  // Clock-enable strobe: shift registers advance
                                     // only when this is high; they hold otherwise

    // ── 52-bit flat input bus ─────────────────────────────────────────────────
    // Packs four independent 13-bit NFE words into one parallel transfer.
    // The host drives all four channels with the same vector element at the
    // same cycle; the buffer staggers them on the output side.
    input  wire [51:0] data_in,      // [12:0]=ch0  [25:13]=ch1  [38:26]=ch2  [51:39]=ch3

    // ── Skewed 13-bit output buses — connect to systolic array boundary ────────
    output wire [12:0] out_ch0,      // Channel 0 — 0-cycle delay (combinational)
    output reg  [12:0] out_ch1,      // Channel 1 — 1-cycle delay
    output reg  [12:0] out_ch2,      // Channel 2 — 2-cycle delay
    output reg  [12:0] out_ch3       // Channel 3 — 3-cycle delay
);

    // =========================================================================
    // Channel 0 — combinational pass-through  (0 clock cycles of delay)
    // ─────────────────────────────────────────────────────────────────────────
    // data_in[12:0] appears on out_ch0 within the same clock cycle it is
    // presented.  No flip-flop is instantiated for this channel; synthesis
    // routes the input bus directly to the output wire.
    // =========================================================================
    assign out_ch0 = data_in[12:0];

    // =========================================================================
    // Internal pipeline intermediate registers
    // ─────────────────────────────────────────────────────────────────────────
    //  ch2_s0  : Channel 2, stage 1 of 2 — sits between data_in and out_ch2
    //  ch3_s0  : Channel 3, stage 1 of 3 — first hop from data_in
    //  ch3_s1  : Channel 3, stage 2 of 3 — second hop toward out_ch3
    // =========================================================================
    reg [12:0] ch2_s0;           // Channel 2: intermediate stage 1
    reg [12:0] ch3_s0;           // Channel 3: intermediate stage 1
    reg [12:0] ch3_s1;           // Channel 3: intermediate stage 2

    // =========================================================================
    // Shift register fabric — single always block, all non-blocking
    // ─────────────────────────────────────────────────────────────────────────
    // RESET  : All pipeline registers and output registers clear to zero.
    //
    // ENABLED (input_valid = 1):
    //   Channel 1 (1 stage):  out_ch1 ← data_in[25:13]
    //   Channel 2 (2 stages): ch2_s0  ← data_in[38:26]
    //                         out_ch2 ← ch2_s0
    //   Channel 3 (3 stages): ch3_s0  ← data_in[51:39]
    //                         ch3_s1  ← ch3_s0
    //                         out_ch3 ← ch3_s1
    //
    // DISABLED (input_valid = 0):
    //   All shift registers hold their current values.  No new data enters
    //   any pipeline stage.  This prevents stale tokens from propagating
    //   into the systolic array during gap cycles or inter-burst dead time.
    //
    // NBA GUARANTEE
    //   Because all assignments use non-blocking <=, every right-hand side
    //   reads the OLD (pre-clock) register state.  The shift chain is
    //   therefore evaluated simultaneously, not cascaded — producing a
    //   correct single-cycle-per-hop progression regardless of the order
    //   the statements appear in source.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            // ── Synchronous reset — clear all pipeline and output registers ───
            out_ch1 <= 13'd0;
            ch2_s0  <= 13'd0;
            out_ch2 <= 13'd0;
            ch3_s0  <= 13'd0;
            ch3_s1  <= 13'd0;
            out_ch3 <= 13'd0;

        end else if (input_valid) begin

            // ── Channel 1 — 1-stage shift register ───────────────────────────
            // data_in[25:13] captured directly; appears on out_ch1 one cycle
            // after input_valid fires.
            out_ch1 <= data_in[25:13];

            // ── Channel 2 — 2-stage shift register ───────────────────────────
            // Stage 1: capture from data_in
            ch2_s0  <= data_in[38:26];
            // Stage 2: forward from stage 1 (reads OLD ch2_s0 — NBA guarantee)
            out_ch2 <= ch2_s0;

            // ── Channel 3 — 3-stage shift register ───────────────────────────
            // Stage 1: capture from data_in
            ch3_s0  <= data_in[51:39];
            // Stage 2: forward from stage 1 (reads OLD ch3_s0 — NBA guarantee)
            ch3_s1  <= ch3_s0;
            // Stage 3: forward from stage 2 (reads OLD ch3_s1 — NBA guarantee)
            out_ch3 <= ch3_s1;

        end
        // else: input_valid == 0 — all registers hold implicitly (no assignment)

    end

endmodule
