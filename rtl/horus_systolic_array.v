`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_systolic_array
// Project  : Horus Engine
// File     : horus_systolic_array.v
//
// Purpose
//   Structural 4×4 output-stationary systolic array.  Wraps 16 horus_nfe
//   processing elements in a regular grid.  Each PE multiplies its locally
//   latched activation by its locally latched weight and accumulates the
//   product into a 32-bit internal register.  Four row outputs are formed by
//   combinationally summing the four PE accumulators along each row.
//
// ─────────────────────────────────────────────────────────────────────────────
// Data-Routing Lanes
// ─────────────────────────────────────────────────────────────────────────────
//
//  HORIZONTAL — Row Activation lanes   (ROWS lanes, flow LEFT → RIGHT)
//
//    row_act_r ─► act_reg[r,0] ─► act_reg[r,1] ─► act_reg[r,2] ─► act_reg[r,3]
//                      │               │               │               │
//                   PE[r,0]         PE[r,1]         PE[r,2]         PE[r,3]
//
//    act_reg[r,0] is loaded from the left-boundary input row_act_r.
//    act_reg[r,c] (c > 0) is loaded from act_reg[r,c-1] one cycle earlier.
//    The token advances exactly one column rightward per clock edge.
//
//  VERTICAL — Column Weight lanes   (COLS lanes, flow TOP → BOTTOM)
//
//    col_wt_c ─► wt_reg[0,c] ─► wt_reg[1,c] ─► wt_reg[2,c] ─► wt_reg[3,c]
//                     │              │              │              │
//                  PE[0,c]        PE[1,c]        PE[2,c]        PE[3,c]
//
//    wt_reg[0,c] is loaded from the top-boundary input col_wt_c.
//    wt_reg[r,c] (r > 0) is loaded from wt_reg[r-1,c] one cycle earlier.
//    The token advances exactly one row downward per clock edge.
//
//  ACCUMULATION — Row output lanes   (ROWS lanes, combinational 32-bit sum)
//
//    row_out_r = PE[r,0].accum_out + PE[r,1].accum_out
//              + PE[r,2].accum_out + PE[r,3].accum_out
//
// ─────────────────────────────────────────────────────────────────────────────
// Spatial Grid Map  (→ = activation lane,  ↓ = weight lane)
// ─────────────────────────────────────────────────────────────────────────────
//
//              col_wt_0    col_wt_1    col_wt_2    col_wt_3
//                  ↓           ↓           ↓           ↓
//  row_act_0 → PE[0,0] →  PE[0,1] →  PE[0,2] →  PE[0,3] ──► row_out_0
//                  ↓           ↓           ↓           ↓
//  row_act_1 → PE[1,0] →  PE[1,1] →  PE[1,2] →  PE[1,3] ──► row_out_1
//                  ↓           ↓           ↓           ↓
//  row_act_2 → PE[2,0] →  PE[2,1] →  PE[2,2] →  PE[2,3] ──► row_out_2
//                  ↓           ↓           ↓           ↓
//  row_act_3 → PE[3,0] →  PE[3,1] →  PE[3,2] →  PE[3,3] ──► row_out_3
//
// ─────────────────────────────────────────────────────────────────────────────
// Pipeline Fill Latency
// ─────────────────────────────────────────────────────────────────────────────
//   PE[r,c] sees its first coincident valid inputs after (r + c) pipeline-
//   register hops, plus 1 cycle for the horus_nfe result register.
//
//   First valid cycle per PE:
//     PE[0,0]=1  PE[0,1]=2  PE[0,2]=3  PE[0,3]=4
//     PE[1,0]=2  PE[1,1]=3  PE[1,2]=4  PE[1,3]=5
//     PE[2,0]=3  PE[2,1]=4  PE[2,2]=5  PE[2,3]=6
//     PE[3,0]=4  PE[3,1]=5  PE[3,2]=6  PE[3,3]=7   ← worst-case corner
//
// ─────────────────────────────────────────────────────────────────────────────
// Accumulator Protocol
// ─────────────────────────────────────────────────────────────────────────────
//   1. Assert accum_clr ≥1 cycle — zeros all 16 PE internal accumulators.
//   2. Drive row_act_* and col_wt_*; assert accum_en.
//   3. Hold accum_en for the computation window (≥ pipeline fill cycles).
//   4. Deassert accum_en; allow one NOP cycle to flush accum_reg → accum_out.
//   5. Sample row_out_0..3 — valid accumulated dot-product results.
// ============================================================================

module horus_systolic_array #(
    // ── Array dimension parameters ────────────────────────────────────────────
    // NOTE: ROWS and COLS drive the generate loop bounds and register arrays.
    // The module's flat port declarations are fixed at 4; update them in step
    // with these parameters if the array size is changed.
    parameter ROWS = 4,   // Number of PE rows
    parameter COLS = 4    // Number of PE columns
) (
    input  wire        clk,
    input  wire        rst_n,       // Active-low synchronous reset
    input  wire        accum_en,    // Fold each PE's current MUL result into its accumulator
    input  wire        accum_clr,   // Synchronous clear of all 16 PE accumulators

    // ── Row Activation inputs — left boundary, one 13-bit NFE bus per row ─────
    input  wire [12:0] row_act_0,   // Row 0 activation
    input  wire [12:0] row_act_1,   // Row 1 activation
    input  wire [12:0] row_act_2,   // Row 2 activation
    input  wire [12:0] row_act_3,   // Row 3 activation

    // ── Column Weight inputs — top boundary, one 13-bit NFE bus per column ────
    input  wire [12:0] col_wt_0,    // Column 0 weight
    input  wire [12:0] col_wt_1,    // Column 1 weight
    input  wire [12:0] col_wt_2,    // Column 2 weight
    input  wire [12:0] col_wt_3,    // Column 3 weight

    // ── Row dot-product outputs — combinational sum of 4 PE accumulators ──────
    output wire [31:0] row_out_0,   // Row 0 accumulated dot product
    output wire [31:0] row_out_1,   // Row 1 accumulated dot product
    output wire [31:0] row_out_2,   // Row 2 accumulated dot product
    output wire [31:0] row_out_3    // Row 3 accumulated dot product
);

    // =========================================================================
    // Data-width constants  (fixed by the horus_nfe interface — do not change)
    // =========================================================================
    localparam NFE_W = 13;  // horus_nfe word width
    localparam ACMW  = 32;  // horus_nfe accumulator output width

    // =========================================================================
    // Boundary input bus aliases
    // ─────────────────────────────────────────────────────────────────────────
    // Groups the four flat ports into 1-D indexed arrays so that the for-loop
    // inside the always block can reference them with an integer index.
    // These are zero-cost structural wires — no flip-flops are inferred.
    // =========================================================================
    wire [NFE_W-1:0] row_act_bus [0:ROWS-1];
    assign row_act_bus[0] = row_act_0;
    assign row_act_bus[1] = row_act_1;
    assign row_act_bus[2] = row_act_2;
    assign row_act_bus[3] = row_act_3;

    wire [NFE_W-1:0] col_wt_bus [0:COLS-1];
    assign col_wt_bus[0] = col_wt_0;
    assign col_wt_bus[1] = col_wt_1;
    assign col_wt_bus[2] = col_wt_2;
    assign col_wt_bus[3] = col_wt_3;

    // =========================================================================
    // Inter-PE pipeline register arrays
    // ─────────────────────────────────────────────────────────────────────────
    //  act_reg[r][c]  13-bit activation at the input of PE[r,c].
    //                 c == 0 : loaded from row_act_bus[r]   (left boundary)
    //                 c  > 0 : loaded from act_reg[r][c-1]  (shift right)
    //
    //  wt_reg[r][c]   13-bit weight at the input of PE[r,c].
    //                 r == 0 : loaded from col_wt_bus[c]    (top boundary)
    //                 r  > 0 : loaded from wt_reg[r-1][c]   (shift down)
    // =========================================================================
    reg [NFE_W-1:0] act_reg [0:ROWS-1][0:COLS-1];
    reg [NFE_W-1:0] wt_reg  [0:ROWS-1][0:COLS-1];

    // =========================================================================
    // PE output wire arrays  (driven by the horus_nfe instances below)
    // =========================================================================
    wire [ACMW-1:0]  pe_accum  [0:ROWS-1][0:COLS-1]; // 32-bit accumulated sums
    wire [NFE_W-1:0] pe_result [0:ROWS-1][0:COLS-1]; // 13-bit current-cycle products

    // Integer loop variables for the reset and propagation for-loops.
    // Synthesisers unroll all for-loops at constant bounds — no flip-flops
    // are inferred for ri or ci.
    integer ri, ci;

    // =========================================================================
    // Pipeline register update — single atomic non-blocking always block
    // ─────────────────────────────────────────────────────────────────────────
    // All 32 register updates (16 activation + 16 weight) are issued as
    // non-blocking assignments in one always block.  Because every RHS is
    // evaluated against the pre-clock state before any LHS is written, the
    // entire register fabric updates atomically — the shift semantics are
    // correct regardless of the order the assignments appear in source.
    //
    // RESET branch
    //   Nested for-loops clear all registers simultaneously.  Synthesis
    //   unrolls to 32 parallel reset muxes feeding 32 flip-flops.
    //
    // PROPAGATION branch  (four independent for-loop groups)
    //   Group A — act boundary capture : col-0 registers ← boundary inputs
    //   Group B — act propagation      : col-c ← col-(c-1) for c in 1..COLS-1
    //   Group C — wt  boundary capture : row-0 registers ← boundary inputs
    //   Group D — wt  propagation      : row-r ← row-(r-1) for r in 1..ROWS-1
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            // ── RESET: zero every pipeline register ───────────────────────────
            for (ri = 0; ri < ROWS; ri = ri + 1)
                for (ci = 0; ci < COLS; ci = ci + 1) begin
                    act_reg[ri][ci] <= {NFE_W{1'b0}};
                    wt_reg[ri][ci]  <= {NFE_W{1'b0}};
                end

        end else begin

            // ── Group A: Activation boundary capture — LEFT edge → column 0 ──
            // Load each row's left-boundary input into the first pipeline
            // register of that row.  act_reg[r][0] is the column-0 entry
            // point for the row-r activation lane.
            for (ri = 0; ri < ROWS; ri = ri + 1)
                act_reg[ri][0] <= row_act_bus[ri];

            // ── Group B: Activation propagation — shift RIGHT (col 1 → COLS-1)
            // Each register takes the old value of the register to its left.
            // NBA guarantees act_reg[ri][ci-1] on the RHS is the PRE-clock
            // value, so this correctly shifts the token one column per cycle.
            for (ri = 0; ri < ROWS; ri = ri + 1)
                for (ci = 1; ci < COLS; ci = ci + 1)
                    act_reg[ri][ci] <= act_reg[ri][ci-1];

            // ── Group C: Weight boundary capture — TOP edge → row 0 ──────────
            // Load each column's top-boundary input into the first pipeline
            // register of that column.  wt_reg[0][c] is the row-0 entry
            // point for the column-c weight lane.
            for (ci = 0; ci < COLS; ci = ci + 1)
                wt_reg[0][ci] <= col_wt_bus[ci];

            // ── Group D: Weight propagation — shift DOWN (row 1 → ROWS-1) ────
            // Each register takes the old value of the register above it.
            // NBA guarantees wt_reg[ri-1][ci] on the RHS is the PRE-clock
            // value, so this correctly shifts the token one row per cycle.
            for (ci = 0; ci < COLS; ci = ci + 1)
                for (ri = 1; ri < ROWS; ri = ri + 1)
                    wt_reg[ri][ci] <= wt_reg[ri-1][ci];

        end
    end

    // =========================================================================
    // Processing Element instantiation — nested GEN_ROW / GEN_COL generate
    // ─────────────────────────────────────────────────────────────────────────
    // Hierarchy path for each PE:
    //   GEN_ROW[r].GEN_COL[c].pe_inst
    //   e.g. GEN_ROW[2].GEN_COL[1].pe_inst  →  PE at row 2, column 1
    //
    // Port binding for PE[r,c]:
    //   op_a      ← act_reg[r][c]   locally latched activation
    //   op_b      ← wt_reg[r][c]    locally latched weight
    //   op_sel    = 2'b10            MUL — hardwired; no runtime switch
    //   accum_en  ← global           fold result into PE's 32-bit accumulator
    //   accum_clr ← global           clear PE accumulator before new window
    //   result    → pe_result[r][c]  13-bit NFE-encoded product (this cycle)
    //   accum_out → pe_accum[r][c]   32-bit running accumulated sum
    //
    // The three one-cycle event flags (rollover_flag, underflow_flag,
    // exp_ovf_flag) are intentionally left unconnected at the array level.
    // Route them to a monitoring bus by editing the generate block if needed.
    // =========================================================================
    genvar r, c;

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : GEN_ROW
            for (c = 0; c < COLS; c = c + 1) begin : GEN_COL

                horus_nfe pe_inst (
                    // ── Global timing and control ───────────────────────────
                    .clk            (clk),
                    .rst_n          (rst_n),

                    // ── Local pipeline register operands ─────────────────────
                    // op_a receives the activation that has propagated c columns
                    // right from the left boundary over the last c clock cycles.
                    // op_b receives the weight that has propagated r rows down
                    // from the top boundary over the last r clock cycles.
                    .op_a           (act_reg[r][c]),
                    .op_b           (wt_reg[r][c]),

                    // ── Operation select: MUL hardwired ──────────────────────
                    // op_sel = 2'b10 selects the fractional multiplication path
                    // through the horus_nfe 20-bit scale-register pipeline.
                    // This value is a compile-time constant — synthesis removes
                    // the mux and routes directly to the MUL datapath.
                    .op_sel         (2'b10),

                    // ── Accumulator control: global fan-out ───────────────────
                    .accum_en       (accum_en),
                    .accum_clr      (accum_clr),

                    // ── Outputs ───────────────────────────────────────────────
                    .result         (pe_result[r][c]),   // 13-bit current product
                    .accum_out      (pe_accum[r][c]),    // 32-bit running sum

                    // ── Status flags (open at array level) ────────────────────
                    .rollover_flag  (),
                    .underflow_flag (),
                    .exp_ovf_flag   ()
                );

            end // : GEN_COL
        end // : GEN_ROW
    endgenerate

    // =========================================================================
    // Row output summation — combinational 32-bit adder trees
    // ─────────────────────────────────────────────────────────────────────────
    // Adds the four PE accumulator outputs along each row.  pe_accum[r][c] is
    // the registered accum_out port of horus_nfe — it already holds the stable
    // running sum from previous cycles, so no additional register stage is
    // needed here.  Synthesis maps each row to three cascaded 32-bit adders
    // (twelve adders in total across the four rows).
    //
    // row_out_r = pe_accum[r,0] + pe_accum[r,1] + pe_accum[r,2] + pe_accum[r,3]
    //
    // Maximum value per term  : bounded by accumulated NFE word values × N cycles
    // Maximum 32-bit overflow  : benign modular wrap — widen to 34 bits if needed
    // =========================================================================

    assign row_out_0 = pe_accum[0][0] + pe_accum[0][1]
                     + pe_accum[0][2] + pe_accum[0][3];  // Row 0

    assign row_out_1 = pe_accum[1][0] + pe_accum[1][1]
                     + pe_accum[1][2] + pe_accum[1][3];  // Row 1

    assign row_out_2 = pe_accum[2][0] + pe_accum[2][1]
                     + pe_accum[2][2] + pe_accum[2][3];  // Row 2

    assign row_out_3 = pe_accum[3][0] + pe_accum[3][1]
                     + pe_accum[3][2] + pe_accum[3][3];  // Row 3

endmodule
