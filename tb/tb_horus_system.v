`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_horus_system
// Project  : Horus Engine
// File     : tb_horus_system.v
//
// Purpose
//   Full-system simulation testbench exercising horus_input_buffer (×2) and
//   horus_top (horus_controller + horus_systolic_array + 16 horus_nfe PEs).
//   Verifies one complete computation window from reset through data_valid.
//
// ─────────────────────────────────────────────────────────────────────────────
// Test Vector Selection
// ─────────────────────────────────────────────────────────────────────────────
//   TEST_ACT = TEST_WT = 13'h7C0  (S=0, stored_E=31, f=0 → real value = 0.5)
//
//   Encoding rationale (Bias-32, v3 NFE):
//     actual_E  = stored_E − 32 = 31 − 32 = −1
//     value     = (−1)^0 × 2^(−1) × (1 + 0/64) = 0.5  ✓
//
//   NFE multiplication result (op_a = op_b = 13'h7C0):
//     Full mantissa A = {1, f_a} = 64 + 0 = 64  (7-bit hidden-bit form)
//     Full mantissa B = {1, f_b} = 64 + 0 = 64
//     Product P = 64 × 64 = 4096  (14-bit; P[13]=0 → hidden-1 at P[12])
//     f_result  = P[11:6] = 0b00_0000 = 0
//     exp_sum   = E_a + E_b − EXP_BIAS = 31 + 31 − 32 = 30  (P[13]=0, no +1)
//     result_word = {0, 6'd30, 6'd0} = 13'h780 = 13'd1920
//
//     Decoded check: actual_E = 30 − 32 = −2; value = 1.0 × 2^(−2) = 0.25  ✓
//
//   Accumulation (pre-filled pipeline → all 16 PEs valid from STREAM cycle 0):
//     STREAM duration  = 7 cycles
//     Per-PE accum_reg = 7 × 1920 = 13440
//     Row output       = 4 PEs × 13440 = 53760 = 32'h0000D200
//
//   Expected: 4 * (0.5 * 0.5 * PE_COUNT) = 53760
//             ALL FOUR row_out_* = 32'd53760 (identical, constant input vectors)
//
// ─────────────────────────────────────────────────────────────────────────────
// Testbench Timeline (cycle-accurate, 100 MHz clock)
// ─────────────────────────────────────────────────────────────────────────────
//
//  Cycle  Event
//  ─────  ──────────────────────────────────────────────────────────────────
//    0    rst=1 asserted  (active-high top-level; rst_n=0 for sub-modules)
//    9    rst=0 released  (at negedge between cycles 9 and 10)
//   10    input_valid=1; act_data and wt_data loaded (constant test vectors)
//   11    Skew buffer ch0 → row/col boundary inputs valid (combinational)
//   12    Skew buffer ch1 → one-cycle pipeline stage clocks through
//   13    Skew buffer ch2 → two-cycle pipeline complete
//   13    Array act_reg[0..2][0..2] zones filling
//   14    Skew buffer ch3 → three-cycle pipeline complete; ALL out_ch* valid
//   14-17 Array act_reg and wt_reg fully filling (max depth = 3 hops + 1)
//   18    ALL 32 pipeline registers (act_reg, wt_reg) hold TEST_NFE value ✓
//   18    start_compute asserted at negedge (sampled at posedge 19)
//   19    FSM: IDLE → SETUP  (accum_clr=1 — zeroes all 16 accum_regs)
//   20    FSM: SETUP → STREAM (accum_en=1 starts; cycle_cnt=0)
//   20-26 STREAM: all 16 PEs accumulate 16 per cycle × 7 cycles = 112 each
//   27    FSM: STREAM → READY (cycle_cnt==6 hit; accum_en deasserted)
//   27    READY posedge: accum_out ← 112 for all PEs (NOP flush)
//   27    data_valid=1 (combinational from READY state decode)
//   27    row_out_0..3 = 4×112 = 448 (combinational adder tree)
//   ~28   Testbench reads results; asserts result_ack
//   29    FSM: READY → IDLE
//
// ─────────────────────────────────────────────────────────────────────────────
// DUT Hierarchy
// ─────────────────────────────────────────────────────────────────────────────
//
//   tb_horus_system
//   ├── u_act_buf  horus_input_buffer   (row activation skew buffer)
//   ├── u_wt_buf   horus_input_buffer   (column weight skew buffer)
//   └── u_top      horus_top
//                  ├── u_ctrl   horus_controller
//                  └── u_array  horus_systolic_array #(ROWS=4, COLS=4)
//                               └── GEN_ROW[0..3].GEN_COL[0..3].pe_inst
//                                   horus_nfe  (×16)
// ============================================================================

module tb_horus_system;

    // =========================================================================
    // Simulation constants
    // =========================================================================
    localparam CLK_PERIOD    = 10;   // 10 ns → 100 MHz testbench clock
    localparam CLK_HALF      = CLK_PERIOD / 2;

    // ── Test NFE word ──────────────────────────────────────────────────────────
    // Bias-32 v3 encoding of 0.5:
    //   S=0, stored_E=31, f=0  →  actual_E = 31−32 = −1  →  value = 0.5
    //   bit[12]=0, bits[11:6]=6'd31=6'b011111, bits[5:0]=6'd0 → 13'h7C0
    //
    // Legacy vector 13'h020 (S=0, stored_E=0, f=32) was an earlier-iteration
    // artifact that predates Bias-32 normalisation.  See docs/NUMERICS.md.
    localparam [12:0] TEST_ACT = 13'b0_011111_000000;   // 13'h7C0 = 0.5
    localparam [12:0] TEST_WT  = 13'b0_011111_000000;   // 13'h7C0 = 0.5

    // ── 52-bit packed input buses (all four channels carry the same word) ──────
    // Layout: [51:39]=ch3  [38:26]=ch2  [25:13]=ch1  [12:0]=ch0
    localparam [51:0] ACT_BUS = {TEST_ACT, TEST_ACT, TEST_ACT, TEST_ACT};
    localparam [51:0] WT_BUS  = {TEST_WT,  TEST_WT,  TEST_WT,  TEST_WT};

    // ── Expected output ────────────────────────────────────────────────────────
    // MUL path: {1,0}×{1,0}=4096; P[13]=0; f=P[11:6]=0; exp=30; word=13'h780=1920
    // Expected: 4 * (0.5 * 0.5 * PE_COUNT) = 53760
    //           7 STREAM cycles × 1920 = 13440 per PE; 4 PEs per row: 4×13440 = 53760
    localparam [31:0] EXPECTED = 32'd53760;  // 0x0000D200

    // ── Pre-fill cycles ────────────────────────────────────────────────────────
    // Minimum: 3 (input buffer ch3 depth) + 3 (array max pipeline hop) + 1 = 7
    // Using 8 for one cycle of margin.
    localparam PRE_FILL   = 8;
    // Watchdog: maximum cycles to wait for data_valid before declaring timeout
    localparam WATCHDOG   = 200;

    // =========================================================================
    // Signal declarations
    // =========================================================================

    // ── Global timing and reset ───────────────────────────────────────────────
    reg  clk;
    reg  rst;           // Active-HIGH → horus_top
    wire rst_n;         // Active-LOW  → horus_input_buffer instances

    // ── Input buffer stimulus ─────────────────────────────────────────────────
    reg  [51:0] act_data;     // 52-bit row activation flat bus
    reg  [51:0] wt_data;      // 52-bit column weight flat bus
    reg         input_valid;  // Clock-enable for both skew buffers

    // ── Skewed outputs: input buffers → horus_top boundary ports ──────────────
    wire [12:0] row_act_0, row_act_1, row_act_2, row_act_3;
    wire [12:0] col_wt_0,  col_wt_1,  col_wt_2,  col_wt_3;

    // ── FSM control handshake ─────────────────────────────────────────────────
    reg  start_compute;
    reg  result_ack;
    wire data_valid;

    // ── Dot-product outputs ───────────────────────────────────────────────────
    wire [31:0] row_out_0, row_out_1, row_out_2, row_out_3;

    // ── Scoreboard ────────────────────────────────────────────────────────────
    integer pass_cnt;
    integer fail_cnt;

    // =========================================================================
    // Clock generation  —  100 MHz
    // =========================================================================
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // Reset polarity adapter
    // ─────────────────────────────────────────────────────────────────────────
    // horus_top exposes active-HIGH rst.
    // horus_input_buffer uses active-LOW rst_n.
    // Both are driven from the same testbench variable `rst`.
    // =========================================================================
    assign rst_n = ~rst;

    // =========================================================================
    // u_act_buf  —  Row Activation Skew Buffer
    // ─────────────────────────────────────────────────────────────────────────
    // Slices the 52-bit act_data bus and staggers the four channels:
    //   out_ch0 (0-cycle) → row_act_0    out_ch2 (2-cycle) → row_act_2
    //   out_ch1 (1-cycle) → row_act_1    out_ch3 (3-cycle) → row_act_3
    // =========================================================================
    horus_input_buffer u_act_buf (
        .clk         (clk),
        .rst_n       (rst_n),
        .input_valid (input_valid),
        .data_in     (act_data),
        .out_ch0     (row_act_0),
        .out_ch1     (row_act_1),
        .out_ch2     (row_act_2),
        .out_ch3     (row_act_3)
    );

    // =========================================================================
    // u_wt_buf  —  Column Weight Skew Buffer
    // ─────────────────────────────────────────────────────────────────────────
    // Mirrors u_act_buf for the vertical (top-boundary) weight lanes:
    //   out_ch0 (0-cycle) → col_wt_0    out_ch2 (2-cycle) → col_wt_2
    //   out_ch1 (1-cycle) → col_wt_1    out_ch3 (3-cycle) → col_wt_3
    // =========================================================================
    horus_input_buffer u_wt_buf (
        .clk         (clk),
        .rst_n       (rst_n),
        .input_valid (input_valid),
        .data_in     (wt_data),
        .out_ch0     (col_wt_0),
        .out_ch1     (col_wt_1),
        .out_ch2     (col_wt_2),
        .out_ch3     (col_wt_3)
    );

    // =========================================================================
    // u_top  —  Horus Engine Top-Level
    // ─────────────────────────────────────────────────────────────────────────
    // Wraps horus_controller and horus_systolic_array.
    // rst is active-HIGH (inverted internally to rst_n for sub-modules).
    // =========================================================================
    horus_top u_top (
        .clk           (clk),
        .rst           (rst),
        .start_compute (start_compute),
        .result_ack    (result_ack),
        .data_valid    (data_valid),
        .row_act_0     (row_act_0),
        .row_act_1     (row_act_1),
        .row_act_2     (row_act_2),
        .row_act_3     (row_act_3),
        .col_wt_0      (col_wt_0),
        .col_wt_1      (col_wt_1),
        .col_wt_2      (col_wt_2),
        .col_wt_3      (col_wt_3),
        .row_out_0     (row_out_0),
        .row_out_1     (row_out_1),
        .row_out_2     (row_out_2),
        .row_out_3     (row_out_3)
    );

    // =========================================================================
    // Watchdog  —  independent timeout process
    // ─────────────────────────────────────────────────────────────────────────
    // Kills the simulation if data_valid does not assert within WATCHDOG cycles
    // after start of simulation.  Prevents infinite hangs on RTL bugs.
    // =========================================================================
    initial begin : WATCHDOG_PROC
        repeat(WATCHDOG + 30) @(posedge clk);   // +30 for reset + pre-fill cycles
        $display("");
        $display("  *** WATCHDOG TIMEOUT at %0t ns — data_valid never asserted ***", $time);
        $display("  Check FSM state transitions and pipeline connectivity.");
        $finish;
    end

    // =========================================================================
    // check_row task  —  PASS/FAIL comparison helper
    // =========================================================================
    task check_row;
        input integer     row_idx;
        input [31:0]      actual;
        input [31:0]      expected;
        begin
            if (actual === expected) begin
                $display("  [PASS] row_out_%0d = %0d (0x%08h)   expected %0d",
                         row_idx, actual, actual, expected);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL] row_out_%0d = %0d (0x%08h)   expected %0d (0x%08h)",
                         row_idx, actual, actual, expected, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Main stimulus  —  reset → pre-fill → compute → verify → finish
    // =========================================================================
    initial begin : STIMULUS

        // ── Waveform dump ─────────────────────────────────────────────────────
        $dumpfile("system_dump.vcd");
        $dumpvars(0, tb_horus_system);

        // ── Signal initialisation ─────────────────────────────────────────────
        rst           = 1'b1;
        start_compute = 1'b0;
        result_ack    = 1'b0;
        input_valid   = 1'b0;
        act_data      = 52'd0;
        wt_data       = 52'd0;
        pass_cnt      = 0;
        fail_cnt      = 0;

        // ── Test banner ────────────────────────────────────────────────────────
        $display("");
        $display("============================================================");
        $display("  HORUS ENGINE — Full System Testbench");
        $display("  tb_horus_system.v   @   100 MHz clock");
        $display("============================================================");
        $display("  Test vectors:");
        $display("    ACT = 13'h%03h  (S=0  stored_E=31  f=0  → 0.5)", TEST_ACT);
        $display("    WT  = 13'h%03h  (S=0  stored_E=31  f=0  → 0.5)", TEST_WT);
        $display("  MUL result word : 13'h780 = 1920  (decodes to 0.25)");
        $display("  STREAM cycles   : 7");
        $display("  Expected per PE : 7 x 1920 = 13440");
        $display("  Expected per row: 4 x 13440 = 53760 (0x%08h)", EXPECTED);
        $display("============================================================");

        // ── Phase 1: Reset (100 ns = 10 clock cycles) ─────────────────────────
        $display("");
        $display("[%0t ns] PHASE 1 — Reset assertion (100 ns)", $time);
        #100;
        // Drive signals after the negedge to avoid setup violations at posedge
        @(negedge clk);
        rst = 1'b0;
        $display("[%0t ns]   rst deasserted — FSM and pipeline released.", $time);

        // ── Phase 2: Pipeline pre-fill ────────────────────────────────────────
        // Present constant test vectors to both input buffers immediately after
        // reset release.  Hold for PRE_FILL cycles so that:
        //   • The 3-stage input buffer shift chains for ch3 complete their fill.
        //   • The systolic array's act_reg / wt_reg 2-D arrays propagate the
        //     constant value all the way to PE[3,3] (deepest corner).
        // By the time start_compute fires, all 32 pipeline registers hold
        // TEST_ACT / TEST_WT so every STREAM cycle is a valid accumulation.
        $display("[%0t ns] PHASE 2 — Loading test vectors; pre-filling pipeline (%0d cycles)...",
                 $time, PRE_FILL);
        @(negedge clk);
        input_valid = 1'b1;
        act_data    = ACT_BUS;   // {ch3, ch2, ch1, ch0} = all TEST_ACT
        wt_data     = WT_BUS;    // {ch3, ch2, ch1, ch0} = all TEST_WT
        $display("[%0t ns]   input_valid=1  act_data=0x%013h  wt_data=0x%013h",
                 $time, act_data, wt_data);

        // Hold input_valid for PRE_FILL clock cycles before triggering the FSM
        repeat(PRE_FILL) @(posedge clk);
        $display("[%0t ns]   Pre-fill complete.  All act_reg / wt_reg arrays fully loaded.", $time);

        // ── Phase 3: Trigger the computation window ───────────────────────────
        // Assert start_compute for exactly 1 clock cycle (level-sensitive; FSM
        // samples it at the following posedge and moves IDLE → SETUP).
        $display("[%0t ns] PHASE 3 — Triggering computation: start_compute=1", $time);
        @(negedge clk);
        start_compute = 1'b1;
        @(negedge clk);
        start_compute = 1'b0;
        $display("[%0t ns]   start_compute deasserted.  FSM running:", $time);
        $display("         IDLE(1cy) → SETUP(1cy) → STREAM(7cy) → READY");

        // ── Phase 4: Wait for data_valid ──────────────────────────────────────
        // The FSM takes 9 cycles from start_compute being sampled:
        //   1 (IDLE) + 1 (SETUP) + 7 (STREAM) = 9 cycles → READY → data_valid=1
        // `wait` is level-sensitive and triggers as soon as data_valid goes high
        // in the same simulation time step as the READY state entry posedge.
        $display("[%0t ns] PHASE 4 — Waiting for data_valid...", $time);
        wait(data_valid === 1'b1);
        // Allow one additional posedge for accum_out to fully stabilise.
        // (accum_out <= accum_reg fires at the same READY posedge; the extra
        //  clock below gives the combinational adder tree a complete cycle to
        //  propagate the final sums to row_out_0..3.)
        @(posedge clk);
        #1;   // 1 ns delta: all NBA updates have committed
        $display("[%0t ns]   data_valid asserted!  Capturing row outputs.", $time);

        // ── Phase 5: Read and verify results ──────────────────────────────────
        $display("");
        $display("============================================================");
        $display("  RESULT REPORT");
        $display("------------------------------------------------------------");
        check_row(0, row_out_0, EXPECTED);
        check_row(1, row_out_1, EXPECTED);
        check_row(2, row_out_2, EXPECTED);
        check_row(3, row_out_3, EXPECTED);
        $display("------------------------------------------------------------");
        if (fail_cnt == 0)
            $display("  OVERALL: ALL %0d CHECKS PASSED", pass_cnt);
        else
            $display("  OVERALL: %0d PASSED / %0d FAILED", pass_cnt, fail_cnt);
        $display("============================================================");

        // ── Phase 6: Host acknowledgement ─────────────────────────────────────
        // Assert result_ack for 1 cycle to return FSM from READY → IDLE.
        $display("");
        $display("[%0t ns] PHASE 6 — Asserting result_ack (FSM → IDLE)", $time);
        @(negedge clk);
        result_ack = 1'b1;
        @(negedge clk);
        result_ack = 1'b0;
        $display("[%0t ns]   result_ack deasserted.  FSM returned to IDLE.", $time);

        // ── Finish ────────────────────────────────────────────────────────────
        #50;
        $display("");
        $display("[%0t ns] Simulation complete.  Waveform: system_dump.vcd", $time);
        $display("============================================================");
        $finish;

    end // STIMULUS

endmodule
