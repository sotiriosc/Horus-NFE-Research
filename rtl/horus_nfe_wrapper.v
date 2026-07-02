`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_nfe_wrapper
// Project  : Horus Engine — Native Fractional Engine
// File     : horus_nfe_wrapper.v
//
// Tile-depth-aware accumulator wrapper for horus_nfe.
//
// Adds a tile_depth port that gates the inner horus_nfe accum_en once the
// number of active accumulations (op_count) reaches the caller-specified
// limit.  This solves two problems simultaneously:
//
//   1. Overflow protection — the 32-bit accum_reg supports 524,288 safe MACs
//      at 13-bit.  tile_depth lets the caller bound the MAC count at dispatch
//      time, preventing silent overflow in large tiled loops.
//
//   2. Power-proportionality — only the memory (flip-flop switching) actually
//      needed for a given tile is driven.  Idle stages beyond tile_depth are
//      clock-gated without changing the compute path.
//
// ── Gating rule ──────────────────────────────────────────────────────────────
//   tile_depth == 0   → unlimited (gate disabled, backward-compatible default)
//   tile_depth == N>0 → accum_en is gated after N active accumulation cycles.
//                       op_count tracks the running total.
//                       accum_full asserts the cycle after the Nth op lands.
//
// ── What counts as an "active accumulation" ──────────────────────────────────
//   Any clock cycle where ALL of the following are true:
//     (a) accum_en is high
//     (b) op_sel != NOP (2'b11)
//     (c) accum_gate is high (not yet at limit)
//     (d) accum_clr is not asserted
//
// ── Interface summary ────────────────────────────────────────────────────────
//   All horus_nfe ports are pass-through (zero added latency to compute path).
//   New ports:
//     tile_depth  [TILE_DEPTH_W-1:0]  — max MACs before gating
//     op_count    [TILE_DEPTH_W-1:0]  — current accumulation count (out)
//     accum_full                      — level signal; high when at limit
//
// ── Timing notes ─────────────────────────────────────────────────────────────
//   accum_gate is combinational from op_count and tile_depth.
//   The gate decision therefore reaches horus_nfe's accum_en in the same
//   clock cycle with no extra pipeline stages on the compute path.
//   accum_full is registered (1-cycle latency after the Nth accumulation).
//   tile_depth must be stable for the duration of a tile; set before assert-
//   ing accum_en and do not change until accum_clr is issued.
// ============================================================================

module horus_nfe_wrapper #(
    parameter TILE_DEPTH_W = 20  // Counter width: max 2^20 = 1,048,576 MACs
) (
    input  wire        clk,
    input  wire        rst_n,

    // ── Operands ─────────────────────────────────────────────────────────────
    input  wire [12:0] op_a,
    input  wire [12:0] op_b,
    input  wire [1:0]  op_sel,

    // ── Accumulator control ───────────────────────────────────────────────────
    input  wire        accum_en,
    input  wire        accum_clr,
    input  wire [TILE_DEPTH_W-1:0] tile_depth,  // 0 = unlimited

    // ── Compute outputs (pass-through from horus_nfe) ─────────────────────────
    output wire [12:0] result,
    output wire [31:0] accum_out,
    output wire        rollover_flag,
    output wire        underflow_flag,
    output wire        exp_ovf_flag,

    // ── Tile-depth gate status ────────────────────────────────────────────────
    output reg  [TILE_DEPTH_W-1:0] op_count,   // Accumulations performed so far
    output reg                     accum_full   // Held high once tile_depth is reached
);

    // =========================================================================
    // Gate logic (combinational — zero latency added to compute path)
    // =========================================================================
    //
    // depth_limited: true whenever tile_depth is non-zero.
    // accum_gate   : true when accumulation is still permitted.
    //   - Always true in unlimited mode (tile_depth == 0).
    //   - True while op_count < tile_depth in limited mode.
    // gated_accum_en: what horus_nfe actually sees on its accum_en pin.

    wire depth_limited  = (tile_depth != {TILE_DEPTH_W{1'b0}});
    wire accum_gate     = !depth_limited || (op_count < tile_depth);
    wire gated_accum_en = accum_en && accum_gate;

    // =========================================================================
    // Operation counter + accum_full flag
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_count   <= {TILE_DEPTH_W{1'b0}};
            accum_full <= 1'b0;

        end else if (accum_clr) begin
            // Synchronous clear: resets both counter and full flag together.
            // After this edge, the gate re-opens for the next tile.
            op_count   <= {TILE_DEPTH_W{1'b0}};
            accum_full <= 1'b0;

        end else begin

            // ── Increment op_count ────────────────────────────────────────────
            // Only count when depth-limiting is active; counting in unlimited
            // mode is meaningless (tile_depth = 0 is the "no limit" sentinel).
            if (depth_limited && gated_accum_en && (op_sel != 2'b11))
                op_count <= op_count + {{(TILE_DEPTH_W-1){1'b0}}, 1'b1};

            // ── Assert accum_full ─────────────────────────────────────────────
            // Fire on the same posedge as the LAST valid accumulation
            // (the Nth op: op_count was tile_depth-1 entering this edge).
            // Using >= tile_depth-1 here means: if this is the last allowed
            // op, set the flag so it is visible on the very next cycle —
            // the first cycle where gated_accum_en will be 0.
            //
            // Safe because depth_limited guards against tile_depth == 0, which
            // would cause tile_depth-1 to wrap to all-ones on unsigned hardware.
            if (depth_limited && (op_count >= tile_depth - {{(TILE_DEPTH_W-1){1'b0}}, 1'b1})
                               && gated_accum_en && (op_sel != 2'b11))
                accum_full <= 1'b1;

        end
    end

    // =========================================================================
    // horus_nfe instance — all ports pass-through; only accum_en is gated
    // =========================================================================
    horus_nfe u_nfe (
        .clk            (clk),
        .rst_n          (rst_n),
        .op_a           (op_a),
        .op_b           (op_b),
        .op_sel         (op_sel),
        .accum_en       (gated_accum_en),   // ← gated by tile_depth
        .accum_clr      (accum_clr),
        .result         (result),
        .accum_out      (accum_out),
        .rollover_flag  (rollover_flag),
        .underflow_flag (underflow_flag),
        .exp_ovf_flag   (exp_ovf_flag)
    );

endmodule
