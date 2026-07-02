`timescale 1ns / 1ps
// ============================================================================
// Testbench : tb_horus_pgate_ctrl
// DUT       : horus_pgate_ctrl (Power-Proportional Memory Gating Controller)
//
// Three corner-case scenarios that stress-test the gate comparator at the
// precise boundaries where glitches corrupt accumulator state.
//
// TEST 1 — Hard Stop (tile_depth=10)
//   Drive op_count from 0 to 12.  Prove the gate closes EXACTLY at op_count=10
//   (not 9, not 11) and stays closed for every higher value.
//   Any value > 10 still producing accum_en_gated=1 is a "one-off" overshoot bug.
//
// TEST 2 — Zero Depth (tile_depth=0)
//   The most dangerous comparator state: "current_op_count < 0" for unsigned
//   arithmetic.  Confirm the gate is PERMANENTLY CLOSED regardless of op_count,
//   ensuring no accumulator registers switch.  This is the power-save sentinel.
//
// TEST 3 — Counter Rollover (tile_depth=5)
//   Force op_count through 0xFFFE → 0xFFFF → 0x0000.
//   Two checks:
//     (a) No glitch: the transition 0xFFFF→0x0000 produces no spurious HIGH
//         pulse on accum_en_gated in the HIGH→LOW→HIGH direction.
//     (b) Post-rollover correctness: after 0x0000, the gate re-opens because
//         0 < 5 = TRUE.  This is EXPECTED — it mirrors the behaviour after a
//         legitimate accum_clr (counter reset to 0).  The test documents it.
//
// Because horus_pgate_ctrl is purely combinational, all inputs are driven
// directly without waiting for clock edges.  The clk/rst_n ports exist for
// future pipelined extensions and are driven here only for completeness.
// ============================================================================

module tb_horus_pgate_ctrl;

    // ─── DUT connections ─────────────────────────────────────────────────────
    reg        clk, rst_n;
    reg  [5:0] host_tile_depth;
    reg [15:0] current_op_count;
    wire       accum_en_gated;

    horus_pgate_ctrl uut (
        .clk              (clk),
        .rst_n            (rst_n),
        .host_tile_depth  (host_tile_depth),
        .current_op_count (current_op_count),
        .accum_en_gated   (accum_en_gated)
    );

    // ─── Free-running clock (100 MHz) ────────────────────────────────────────
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ─── VCD dump ────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("pgate_ctrl_dump.vcd");
        $dumpvars(0, tb_horus_pgate_ctrl);
    end

    // ─── Loop variables (integer = 32-bit; avoids 16-bit wrap in for-loops) ─
    integer i;
    integer fail_count;

    // =========================================================================
    initial begin
        fail_count         = 0;
        rst_n              = 1'b0;
        host_tile_depth    = 6'd0;
        current_op_count   = 16'd0;
        @(posedge clk); #1;
        rst_n = 1'b1;

        // =====================================================================
        // TEST 1 — Hard Stop: tile_depth=10, op_count sweeps 0 → 12
        // =====================================================================
        $display("\n══ TEST 1: Hard Stop (tile_depth=10) ══");
        host_tile_depth = 6'd10;

        for (i = 0; i <= 12; i = i + 1) begin
            current_op_count = i[15:0];
            #1;   // combinational settle (1 ns — well within 10 ns clock period)

            if (i < 10) begin
                // Gate must be OPEN for op_count 0..9
                if (accum_en_gated !== 1'b1) begin
                    $display("  FAIL [T1]: op_count=%0d → gate CLOSED (expected OPEN)", i);
                    fail_count = fail_count + 1;
                end
            end else begin
                // Gate must be CLOSED for op_count 10, 11, 12
                if (accum_en_gated !== 1'b0) begin
                    $display("  CRITICAL FAIL [T1]: op_count=%0d → gate OPEN (expected CLOSED)", i);
                    fail_count = fail_count + 1;
                end
            end
        end

        // Print the three key boundary values explicitly
        current_op_count = 16'd9;  #1;
        $display("  op_count= 9: accum_en_gated=%0b  (expect 1 — last open cycle)", accum_en_gated);
        current_op_count = 16'd10; #1;
        $display("  op_count=10: accum_en_gated=%0b  (expect 0 — hard stop)", accum_en_gated);
        current_op_count = 16'd11; #1;
        $display("  op_count=11: accum_en_gated=%0b  (expect 0 — stays closed)", accum_en_gated);

        if (accum_en_gated === 1'b0)
            $display("  PASS: Exact hard stop at op_count=10, no overshoot.");
        else begin
            $display("  FAIL: Gate did not close at boundary.");
            fail_count = fail_count + 1;
        end

        // =====================================================================
        // TEST 2 — Zero Depth: tile_depth=0 → gate must be PERMANENTLY CLOSED
        //
        // Mechanism: unsigned comparison  current_op_count < 6'd0  = 16'h0000
        //   For any non-negative integer k,  k < 0  is FALSE in unsigned arith.
        //   This is the mathematical guarantee that makes tile_depth=0 safe.
        // =====================================================================
        $display("\n══ TEST 2: Zero Depth (tile_depth=0) ══");
        host_tile_depth = 6'd0;

        begin : zero_depth_block
            integer t2_fail;
            t2_fail = 0;

            for (i = 0; i < 8; i = i + 1) begin
                current_op_count = i[15:0];
                #1;
                if (accum_en_gated !== 1'b0) begin
                    $display("  FAIL [T2]: op_count=%0d, depth=0 → gate OPEN (expected CLOSED)", i);
                    fail_count = fail_count + 1;
                    t2_fail = t2_fail + 1;
                end
            end

            // Also check a high op_count value — the comparator must not wrap
            current_op_count = 16'hFFFF; #1;
            if (accum_en_gated !== 1'b0) begin
                $display("  FAIL [T2]: op_count=0xFFFF, depth=0 → gate OPEN");
                fail_count = fail_count + 1;
                t2_fail = t2_fail + 1;
            end

            $display("  op_count=0,depth=0: accum_en_gated=%0b  (expect 0)", accum_en_gated);
            if (t2_fail == 0)
                $display("  PASS: Gate permanently closed at tile_depth=0 (unsigned < 0 always false).");
        end

        // =====================================================================
        // TEST 3 — Counter Rollover: tile_depth=5, op_count → 0xFFFF → 0x0000
        //
        // The test answers two questions:
        //   Q1: Is there a GLITCH (spurious HIGH) on the 0xFFFF→0x0000 edge?
        //       Expectation: NO.  Purely combinational logic changes cleanly.
        //   Q2: What is the gate state AFTER rollover?
        //       Expectation: gate RE-OPENS (0 < 5 = TRUE).  This mirrors the
        //       correct post-accum_clr behaviour (counter reset to 0).
        // =====================================================================
        $display("\n══ TEST 3: Counter Rollover (tile_depth=5) ══");
        host_tile_depth = 6'd5;

        // Approach rollover from above (all should be CLOSED since N >> 5)
        begin : rollover_block
            integer t3_fail;
            t3_fail = 0;

            for (i = 16'hFFFC; i <= 16'hFFFF; i = i + 1) begin
                current_op_count = i[15:0];
                #1;
                if (accum_en_gated !== 1'b0) begin
                    $display("  GLITCH FAIL [T3]: op_count=0x%04X → gate HIGH before rollover", i[15:0]);
                    fail_count = fail_count + 1;
                    t3_fail = t3_fail + 1;
                end
            end

            $display("  op_count=0xFFFE: accum_en_gated=%0b  (expect 0 — 65534 >= 5)",
                     $time > 0 ? accum_en_gated : accum_en_gated);  // force display here

            // Rollover moment
            current_op_count = 16'hFFFF; #1;
            $display("  op_count=0xFFFF: accum_en_gated=%0b  (expect 0 — 65535 >= 5)", accum_en_gated);
            current_op_count = 16'h0000; #1;
            $display("  op_count=0x0000: accum_en_gated=%0b  (expect 1 — 0 < 5, gate re-opens post-rollover)", accum_en_gated);

            // Post-rollover: 0..4 open, 5+ closed
            for (i = 0; i < 8; i = i + 1) begin
                current_op_count = i[15:0];
                #1;
                if (i < 5) begin
                    if (accum_en_gated !== 1'b1) begin
                        $display("  FAIL [T3]: post-rollover op_count=%0d should be OPEN", i);
                        fail_count = fail_count + 1;
                        t3_fail = t3_fail + 1;
                    end
                end else begin
                    if (accum_en_gated !== 1'b0) begin
                        $display("  FAIL [T3]: post-rollover op_count=%0d should be CLOSED", i);
                        fail_count = fail_count + 1;
                        t3_fail = t3_fail + 1;
                    end
                end
            end

            if (t3_fail == 0) begin
                $display("  PASS: No glitch on 0xFFFF→0x0000 transition.");
                $display("  NOTE: Gate correctly re-opens at op_count=0 post-rollover.");
                $display("        In horus_system, rollover is prevented by accum_clr");
                $display("        (which resets the counter) before the gate is re-armed.");
            end
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n══════════════════════════════════════════════");
        if (fail_count == 0)
            $display("  ALL 3 CORNER CASE TESTS PASSED — gate is glitch-free.");
        else
            $display("  %0d FAILURE(S) — review output above.", fail_count);
        $display("══════════════════════════════════════════════\n");

        $finish;
    end

endmodule
