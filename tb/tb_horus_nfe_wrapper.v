`timescale 1ns / 1ps
// ============================================================================
// Testbench : tb_horus_nfe_wrapper
// DUT       : horus_nfe_wrapper (wraps horus_nfe)
//
// Purpose
// -------
// Verify the tile-depth accumulator gate added by horus_nfe_wrapper:
//
//   TEST 1 — Unlimited mode (tile_depth=0)
//     4 MUL ops with accum_en=1 → all 4 accumulate, op_count stays 0,
//     accum_full stays 0.
//
//   TEST 2 — Limited mode (tile_depth=4), 6 ops issued
//     First 4 accumulate, ops 5-6 are silently gated.
//     op_count=4, accum_out=4×result_per_op, accum_full=1 after NOPs.
//
//   TEST 3 — accum_clr re-arms the gate
//     After TEST 2: assert accum_clr → op_count=0, accum_full=0, accum=0.
//     Run 2 fresh MULs → they accumulate normally (gate is open again).
//
//   TEST 4 — Extreme low: tile_depth=1
//     3 MUL ops issued → only the first accumulates.
//     op_count=1, accum_out=result_per_op, accum_full=1.
//
// Encoding
// --------
//   Operand: 1.5  =  stored_E=32, f=32  →  {0, 6'd32, 6'd32}  =  13'h820
//   MUL result per op:
//     P = (64+32)×(64+32) = 96×96 = 9216 = 0b10_0100_0000_0000
//     P[13]=1  →  stored_E = 32+32-32+1 = 33,  f = P[12:7] = 8
//     result = {0, 6'd33, 6'd8}  =  2120 decimal
//   Accumulated:  N ops  →  accum_out = N × 2120
//     4 ops → 8480   2 ops → 4240   1 op → 2120
//
// Timing
// ------
//   horus_nfe latency: result is registered on posedge clk (1 cycle).
//   accum_reg updates on the SAME posedge as op presented.
//   accum_out mirrors accum_reg with 1-cycle latency.
//   After the last op, 2 NOP cycles are sufficient to let accum_out settle.
//   accum_full: registered, appears 1 cycle after the Nth accumulation.
// ============================================================================

module tb_horus_nfe_wrapper;

    // ─── DUT signal declarations ─────────────────────────────────────────────
    reg         clk;
    reg         rst_n;
    reg  [12:0] op_a, op_b;
    reg  [1:0]  op_sel;
    reg         accum_en, accum_clr;
    reg  [19:0] tile_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag, underflow_flag, exp_ovf_flag;
    wire [19:0] op_count;
    wire        accum_full;

    // ─── DUT instantiation ───────────────────────────────────────────────────
    horus_nfe_wrapper #(.TILE_DEPTH_W(20)) uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .op_a           (op_a),
        .op_b           (op_b),
        .op_sel         (op_sel),
        .accum_en       (accum_en),
        .accum_clr      (accum_clr),
        .tile_depth     (tile_depth),
        .result         (result),
        .accum_out      (accum_out),
        .rollover_flag  (rollover_flag),
        .underflow_flag (underflow_flag),
        .exp_ovf_flag   (exp_ovf_flag),
        .op_count       (op_count),
        .accum_full     (accum_full)
    );

    // ─── 100 MHz clock ───────────────────────────────────────────────────────
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ─── VCD dump ────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("wrapper_dump.vcd");
        $dumpvars(0, tb_horus_nfe_wrapper);
    end

    // =========================================================================
    // Helper tasks
    // =========================================================================

    // Issue N MUL ops with accum_en=1 using the current op_a/op_b.
    task mul_ops;
        input integer n;
        integer i;
        begin
            op_sel    = 2'b10;  // MUL
            accum_en  = 1'b1;
            accum_clr = 1'b0;
            for (i = 0; i < n; i = i + 1)
                @(posedge clk); #1;
        end
    endtask

    // Drain the pipeline: 2 NOP cycles so accum_out reflects the final accum_reg.
    task drain;
        begin
            op_sel   = 2'b11;  // NOP
            accum_en = 1'b0;
            @(posedge clk); #1;
            @(posedge clk); #1;
        end
    endtask

    // Assert accum_clr for 1 cycle, then drain 1 cycle for accum_out to clear.
    task do_clear;
        begin
            accum_clr = 1'b1;
            op_sel    = 2'b11;
            accum_en  = 1'b0;
            @(posedge clk); #1;
            accum_clr = 1'b0;
            @(posedge clk); #1;  // accum_out reflects cleared accum_reg
        end
    endtask

    // =========================================================================
    // Stimulus + self-checking
    // =========================================================================
    integer fail_count;
    integer exp_accum;

    initial begin
        fail_count = 0;

        // ── Reset ────────────────────────────────────────────────────────────
        rst_n      = 1'b0;
        op_a       = 13'd0;
        op_b       = 13'd0;
        op_sel     = 2'b11;
        accum_en   = 1'b0;
        accum_clr  = 1'b0;
        tile_depth = 20'd0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        // Load operands: 1.5 × 1.5 = 2.25 (result word = 2120 decimal each MUL)
        op_a = {1'b0, 6'd32, 6'd32};   // stored_E=32, f=32 → 1.5
        op_b = {1'b0, 6'd32, 6'd32};

        // =====================================================================
        // TEST 1 — Unlimited mode (tile_depth=0): all 4 MACs accumulate
        // =====================================================================
        $display("\n══ TEST 1: tile_depth=0 (unlimited), 4 MUL ops ══");
        tile_depth = 20'd0;
        mul_ops(4);
        // Sample result HERE — before drain() issues NOPs which would overwrite it
        // (NOP passes op_a through, so result would show 2080 after drain)
        $display("  result   = %0d (expect 2120)", result);
        if (result !== 13'd2120) begin
            $display("  FAIL result"); fail_count = fail_count + 1;
        end else $display("  PASS result");
        drain();

        exp_accum = 4 * 2120;   // 8480
        $display("  accum_out= %0d (expect %0d)", accum_out, exp_accum);
        $display("  op_count = %0d (expect 0 — counter off in unlimited mode)", op_count);
        $display("  accum_full=%0b (expect 0)", accum_full);

        if (accum_out !== exp_accum) begin
            $display("  FAIL accum_out (got %0d)", accum_out); fail_count = fail_count + 1;
        end else $display("  PASS accum_out");

        if (op_count !== 20'd0) begin
            $display("  FAIL op_count (got %0d)", op_count); fail_count = fail_count + 1;
        end else $display("  PASS op_count");

        if (accum_full !== 1'b0) begin
            $display("  FAIL accum_full"); fail_count = fail_count + 1;
        end else $display("  PASS accum_full");

        do_clear();

        // =====================================================================
        // TEST 2 — Limited mode (tile_depth=4): 6 ops issued, only 4 accumulate
        // =====================================================================
        $display("\n══ TEST 2: tile_depth=4, 6 MUL ops (4 should accumulate, 2 gated) ══");
        tile_depth = 20'd4;
        mul_ops(6);   // ops 5 and 6 should be silently gated
        drain();

        exp_accum = 4 * 2120;   // 8480 — NOT 6×2120

        $display("  accum_out= %0d (expect %0d — ops 5-6 gated)", accum_out, exp_accum);
        $display("  op_count = %0d (expect 4)", op_count);
        $display("  accum_full=%0b (expect 1)", accum_full);

        if (accum_out !== exp_accum) begin
            $display("  FAIL accum_out (got %0d, would be %0d if not gated)",
                     accum_out, 6*2120);
            fail_count = fail_count + 1;
        end else $display("  PASS accum_out");

        if (op_count !== 20'd4) begin
            $display("  FAIL op_count (got %0d)", op_count); fail_count = fail_count + 1;
        end else $display("  PASS op_count");

        if (accum_full !== 1'b1) begin
            $display("  FAIL accum_full"); fail_count = fail_count + 1;
        end else $display("  PASS accum_full");

        // =====================================================================
        // TEST 3 — accum_clr re-opens the gate; 2 fresh MACs accumulate
        // =====================================================================
        $display("\n══ TEST 3: accum_clr re-arms gate → 2 fresh MUL ops ══");
        do_clear();

        $display("  After clr: op_count=%0d (expect 0), accum_full=%0b (expect 0)",
                 op_count, accum_full);
        if (op_count !== 20'd0 || accum_full !== 1'b0) begin
            $display("  FAIL counter/flag not cleared");
            fail_count = fail_count + 1;
        end else $display("  PASS clear");

        // tile_depth still 4; run only 2 ops (should all accumulate)
        mul_ops(2);
        drain();

        exp_accum = 2 * 2120;  // 4240

        $display("  accum_out= %0d (expect %0d)", accum_out, exp_accum);
        $display("  op_count = %0d (expect 2)", op_count);
        $display("  accum_full=%0b (expect 0 — limit not reached)", accum_full);

        if (accum_out !== exp_accum) begin
            $display("  FAIL accum_out (got %0d)", accum_out); fail_count = fail_count + 1;
        end else $display("  PASS accum_out");

        if (op_count !== 20'd2) begin
            $display("  FAIL op_count (got %0d)", op_count); fail_count = fail_count + 1;
        end else $display("  PASS op_count");

        if (accum_full !== 1'b0) begin
            $display("  FAIL accum_full (should not be full yet)"); fail_count = fail_count + 1;
        end else $display("  PASS accum_full");

        do_clear();

        // =====================================================================
        // TEST 4 — tile_depth=1: only the very first MAC accumulates
        // =====================================================================
        $display("\n══ TEST 4: tile_depth=1, 3 MUL ops (only 1 should accumulate) ══");
        tile_depth = 20'd1;
        mul_ops(3);
        drain();

        exp_accum = 1 * 2120;  // 2120

        $display("  accum_out= %0d (expect %0d)", accum_out, exp_accum);
        $display("  op_count = %0d (expect 1)", op_count);
        $display("  accum_full=%0b (expect 1)", accum_full);

        if (accum_out !== exp_accum) begin
            $display("  FAIL accum_out (got %0d)", accum_out); fail_count = fail_count + 1;
        end else $display("  PASS accum_out");

        if (op_count !== 20'd1) begin
            $display("  FAIL op_count (got %0d)", op_count); fail_count = fail_count + 1;
        end else $display("  PASS op_count");

        if (accum_full !== 1'b1) begin
            $display("  FAIL accum_full"); fail_count = fail_count + 1;
        end else $display("  PASS accum_full");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n════════════════════════════════════════════");
        if (fail_count == 0)
            $display("  ALL 4 TESTS PASSED");
        else
            $display("  %0d TEST(S) FAILED", fail_count);
        $display("════════════════════════════════════════════\n");

        $finish;
    end

endmodule
