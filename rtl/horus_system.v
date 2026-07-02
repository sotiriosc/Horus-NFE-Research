`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_system
// Project  : Horus Engine — Native Fractional Engine
// File     : horus_system.v
//
// ── Purpose ──────────────────────────────────────────────────────────────────
// Top-level system wrapper that composes horus_nfe (the validated 13-bit MAC
// arithmetic core) with horus_pgate_ctrl (the power-proportional memory gating
// controller) into a single, host-facing module.
//
// The key architectural invariant from horus_nfe.v is fully preserved:
//   - No arithmetic logic is modified — horus_nfe is instantiated unchanged.
//   - Single-cycle MAC throughput is maintained — the gate is combinational.
//   - All horus_nfe flags (rollover, underflow, exp_ovf) pass through.
//
// ── Signal flow ──────────────────────────────────────────────────────────────
//
//   Host
//    │  accum_en ──────────────────────── AND gate ──→ horus_nfe.accum_en
//    │  host_tile_depth ──→ horus_pgate_ctrl         ↑
//    │                           │ accum_en_gated ───┘
//    │                           │
//    │                      (combinational)
//    │                           ▲
//    │                     current_op_count (16-bit)
//    │                           ║
//    │            ┌──── op_count_reg (counter, registered) ◄──── accum_clr
//    │            │         increments when:
//    │            │           accum_en && accum_en_gated
//    │            │           && op_sel != NOP && !accum_clr
//    │            └──────────────────────────────────────────→ op_count (out)
//    │
//    └─ accum_clr ──→ horus_nfe.accum_clr   (also resets op_count_reg)
//
// ── Bridge signals summary ────────────────────────────────────────────────────
//
//   accum_en_gated  (wire, combinational)
//     Controller output.  High while op_count < tile_depth (or unlimited).
//     AND-gated with host's accum_en before reaching horus_nfe.accum_en.
//     Ensures zero extra MACs slip through when the tile budget is exhausted.
//
//   gated_accum_en  (wire, combinational)
//     = accum_en (from host) && accum_en_gated (from controller).
//     Connects to horus_nfe.accum_en — the only signal that bridges the
//     two modules on the accumulator path.  All other horus_nfe ports are
//     wired directly from the horus_system port list.
//
//   op_count_reg  (reg, 16-bit)
//     Internal counter.  Feeds horus_pgate_ctrl.current_op_count.
//     Incremented only when gated_accum_en is high — i.e. only for
//     accumulations that were actually performed.
//     Exposed as the output port op_count for host monitoring.
//
// ── Port list ─────────────────────────────────────────────────────────────────
//   All horus_nfe ports are preserved identically.
//   Added ports:
//     host_tile_depth [5:0]    Host-set MAC budget per tile (0 = unlimited)
//     op_count        [15:0]   Current accumulation count (read-only for host)
//     accum_full               Level signal; high when budget is exhausted
// ============================================================================

module horus_system (
    input  wire        clk,
    input  wire        rst_n,

    // ── Operands (pass-through to horus_nfe) ─────────────────────────────────
    input  wire [12:0] op_a,
    input  wire [12:0] op_b,
    input  wire [1:0]  op_sel,      // 00=ADD  01=SUB  10=MUL  11=NOP

    // ── Accumulator control ───────────────────────────────────────────────────
    input  wire        accum_en,    // host's accumulation request
    input  wire        accum_clr,   // synchronous clear; also resets op_count

    // ── Tile-depth budget ─────────────────────────────────────────────────────
    input  wire [5:0]  host_tile_depth,   // 0 = unlimited; 1–63 = MAC budget

    // ── Compute outputs (pass-through from horus_nfe) ────────────────────────
    output wire [12:0] result,
    output wire [31:0] accum_out,
    output wire        rollover_flag,
    output wire        underflow_flag,
    output wire        exp_ovf_flag,

    // ── Tile-depth status ─────────────────────────────────────────────────────
    output wire [15:0] op_count,    // current accumulation count (read-only)
    output wire        accum_full   // held high once tile_depth is reached
);

    // =========================================================================
    // Internal op_count register
    // =========================================================================
    // 16-bit counter: tracks accumulations actually performed this tile.
    // Increments only on cycles where the gate is open AND accum_en is asserted
    // AND the operation is not NOP — i.e. only for real MACs.
    // Reset by accum_clr (same signal that clears the NFE accumulator), so
    // both accum_reg (inside horus_nfe) and op_count_reg are always in sync.

    reg [15:0] op_count_reg;
    reg        accum_full_reg;

    assign op_count   = op_count_reg;
    assign accum_full = accum_full_reg;

    // =========================================================================
    // Controller instantiation
    // =========================================================================
    // horus_pgate_ctrl takes the current op_count and the host-supplied budget
    // and returns a combinational gate signal.  No pipeline registers are
    // inserted on this path — the decision is immediate.

    wire accum_en_gated;    // combinational: high while budget not exhausted

    horus_pgate_ctrl u_pgc (
        .clk              (clk),
        .rst_n            (rst_n),
        .host_tile_depth  (host_tile_depth),
        .current_op_count (op_count_reg),
        .accum_en_gated   (accum_en_gated)
    );

    // AND-gate: host's request AND controller's gate both must be high.
    wire gated_accum_en = accum_en && accum_en_gated;

    // =========================================================================
    // Counter + accum_full update
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_count_reg   <= 16'd0;
            accum_full_reg <= 1'b0;

        end else if (accum_clr) begin
            // Synchronous clear: both the NFE accumulator (via its own accum_clr
            // port below) and this counter reset atomically on the same edge.
            op_count_reg   <= 16'd0;
            accum_full_reg <= 1'b0;

        end else begin
            // Increment for every cycle where a MAC actually ran.
            // When tile_depth=0 the gate is closed (gated_accum_en=0),
            // so this branch is unreachable — no guard needed.
            if (gated_accum_en && (op_sel != 2'b11))
                op_count_reg <= op_count_reg + 16'd1;

            // accum_full: asserts the same posedge as the LAST valid MAC.
            // tile_depth=0 is excluded: gate is closed so this also never fires.
            if ((host_tile_depth != 6'd0) &&
                (op_count_reg >= ({10'd0, host_tile_depth} - 16'd1)) &&
                gated_accum_en && (op_sel != 2'b11))
                accum_full_reg <= 1'b1;
        end
    end

    // =========================================================================
    // horus_nfe core instantiation
    // =========================================================================
    // Constraint: no port or internal logic of horus_nfe is modified.
    // The only change from a bare horus_nfe connection is that accum_en is
    // routed through gated_accum_en rather than directly from the host.
    // All other ports wire straight through.
    //
    // ── Logic suggestion: Saturating Right-Shift (Normalization) ─────────────
    // Long inference chains (deep GEMM windows, multi-layer accumulation) can
    // exhibit **accumulation drift** when raw 13-bit codewords sum in accum_reg
    // without periodic re-quantization.  A v4 **Saturating Right-Shift**
    // normalization stage can be inserted here to mitigate drift while preserving
    // single-cycle MAC throughput inside horus_nfe:
    //
    //   Insertion point A (recommended): between u_nfe.accum_out and the
    //   horus_system.accum_out port — tap accum_out before export to host/mesh,
    //   apply configurable right-shift + saturate to 32 bits, register, then
    //   drive the external accum_out.  MAC path inside u_nfe stays untouched.
    //
    //   Insertion point B (in-tile, every-N events): inside horus_nfe between
    //   the accum_reg update and accum_out register — re-quantize accum_reg
    //   every host_tile_depth MACs (or on accum_clr) before the next event sum.
    //   Requires a horus_nfe revision; keep horus_system as the integration
    //   wrapper that supplies norm_shift[3:0] and norm_en from the host.
    //
    //   Insertion point C (systolic export): in horus_systolic_array on each
    //   pe_accum[r][c] before row_out aggregation — normalizes per-PE counters
    //   before cross-tile mesh routing.
    //
    // All variants use **saturating** right-shift (clamp to 32-bit max) so
    // normalization never introduces NaN/Inf domains.  See docs/DESIGN_LIMITATIONS.md
    // §2.2 (Normalization — v4 target) for full semantics.
    // =========================================================================

    horus_nfe u_nfe (
        .clk            (clk),
        .rst_n          (rst_n),
        .op_a           (op_a),
        .op_b           (op_b),
        .op_sel         (op_sel),
        .accum_en       (gated_accum_en),   // ← ONLY bridge: gated by controller
        .accum_clr      (accum_clr),
        .result         (result),
        .accum_out      (accum_out),
        .rollover_flag  (rollover_flag),
        .underflow_flag (underflow_flag),
        .exp_ovf_flag   (exp_ovf_flag)
    );

endmodule
