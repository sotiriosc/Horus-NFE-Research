`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_hbs14_system_integration
// Project  : Horus Engine
// File     : tb/tb_hbs14_system_integration.v
//
// Purpose  : HBS-14 End-to-End System Consistency Suite.
//            Validates that all behaviours established by HBS-11 through
//            HBS-13 remain consistent when the full integrated pipeline is
//            exercised under all four policy modes.
//
// Key architectural facts (established before this suite):
//   • mode_tag only affects accum_reg; `result` is ALWAYS = computed.
//   • BIAS_LUT is initialised to all-zero → MODE_001 ≡ MODE_000 by default.
//   • MODE_010 (PRE_SCALED): decrements stored_E of each accumulated word.
//   • MODE_011 (SAFE_ACCUM): saturates accum at 32'hFFFF_FFFF, no wrap.
//   • Collapse boundary: stored_E = 15 ↔ 16.
//   • Saturation boundary: stored_E = 47 ↔ 48.
//
// DUTs instantiated:
//   horus_system         — NFE + pgate_ctrl (main path)
//   horus_systolic_array — 4×4 output-stationary array (consistency check)
//
// Tests:
//   HBS-14A (tid=14)  Full pipeline consistency  — mixed stimuli × 4 modes
//   HBS-14B (tid=15)  Mode interference          — rapid mode switching
//   HBS-14C (tid=16)  Cross-regime contradiction — boundary mid-chain, policy
//   HBS-14D (tid=17)  Long horizon stability     — 2000-cycle stream
//   HBS-14E (tid=18)  Policy + arithmetic        — result vs accum_out split
//   HBS-14G (tid=19)  Systolic array consistency — 4×4 array output check
//
// CSV schema:
//   test_id, subtest, cyc, mode_tag, stored_E, f_val, op_code,
//   result, accum_out, uf, ovf, rollover, extra
// ============================================================================

module tb_hbs14_system_integration;

    // =========================================================================
    // Constants
    // =========================================================================
    localparam CLK_HALF = 5;

    localparam [12:0] NFE_ONE   = 13'h800;  // 1.0  E=32 f=0
    localparam [12:0] NFE_HALF  = 13'h7C0;  // 0.5  E=31 f=0
    localparam [12:0] NFE_TWO   = 13'h840;  // 2.0  E=33 f=0
    localparam [12:0] NFE_FLOOR = 13'h000;  // floor sentinel

    localparam [2:0] MODE_STD  = 3'b000;    // Standard
    localparam [2:0] MODE_BIAS = 3'b001;    // Bias-Corrected (LUT=0→≡STD)
    localparam [2:0] MODE_PRSC = 3'b010;    // Pre-Scaled
    localparam [2:0] MODE_SAFE = 3'b011;    // Safe-Accumulation

    // =========================================================================
    // DUT — horus_system
    // =========================================================================
    reg         clk, rst_n;
    reg  [12:0] op_a, op_b;
    reg  [1:0]  op_sel;
    reg  [2:0]  mode_tag;
    reg         accum_en, accum_clr;
    reg  [5:0]  host_tile_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag, underflow_flag, exp_ovf_flag;
    wire [15:0] op_count;
    wire        accum_full;

    horus_system u_sys (
        .clk             (clk),
        .rst_n           (rst_n),
        .op_a            (op_a),
        .op_b            (op_b),
        .op_sel          (op_sel),
        .mode_tag        (mode_tag),
        .accum_en        (accum_en),
        .accum_clr       (accum_clr),
        .host_tile_depth (host_tile_depth),
        .result          (result),
        .accum_out       (accum_out),
        .rollover_flag   (rollover_flag),
        .underflow_flag  (underflow_flag),
        .exp_ovf_flag    (exp_ovf_flag),
        .op_count        (op_count),
        .accum_full      (accum_full)
    );

    // =========================================================================
    // DUT — horus_systolic_array (4×4)
    // =========================================================================
    reg  [12:0] row_act_0, row_act_1, row_act_2, row_act_3;
    reg  [12:0] col_wt_0,  col_wt_1,  col_wt_2,  col_wt_3;
    reg         sa_accum_en, sa_accum_clr;

    wire [31:0] row_out_0, row_out_1, row_out_2, row_out_3;

    horus_systolic_array u_sa (
        .clk       (clk),
        .rst_n     (rst_n),
        .accum_en  (sa_accum_en),
        .accum_clr (sa_accum_clr),
        .row_act_0 (row_act_0), .row_act_1 (row_act_1),
        .row_act_2 (row_act_2), .row_act_3 (row_act_3),
        .col_wt_0  (col_wt_0),  .col_wt_1  (col_wt_1),
        .col_wt_2  (col_wt_2),  .col_wt_3  (col_wt_3),
        .row_out_0 (row_out_0), .row_out_1 (row_out_1),
        .row_out_2 (row_out_2), .row_out_3 (row_out_3)
    );

    // =========================================================================
    // Module-level variables (Verilog-2001)
    // =========================================================================
    integer csv_fd;
    integer g_m, g_n, g_s, g_d;        // loop iterators

    reg [12:0] t_x, t_y;
    reg [5:0]  t_E, t_f;
    reg [12:0] chain_st;

    // 14A: per-mode result capture (mode 0..3)
    reg [12:0] a14_res  [0:3];
    reg [31:0] a14_acc  [0:3];

    // 14A stimulus tables
    integer a14_E [0:31];   // stored_E for 32 stimuli
    integer a14_f [0:31];   // f for 32 stimuli

    // 14B/14D: LFSR for pseudo-random stimulus
    reg [15:0] lfsr_state;

    // 14C: boundary sequence tracking
    reg [12:0] c14_ref, c14_obs;
    integer    c14_mismatch;

    // 14D: counters
    integer d14_uf_cnt, d14_ovf_cnt, d14_floor_cnt, d14_total;

    // 14E: result mismatch detection
    integer e14_res_mismatch;
    reg [12:0] e14_ref_res;

    // Systolic array capture
    reg [31:0] sa_row [0:3];

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // Tasks
    // =========================================================================

    task do_reset;
        begin
            rst_n = 1'b0;
            op_a = 13'd0; op_b = 13'd0; op_sel = 2'b11;
            mode_tag = MODE_STD; accum_en = 1'b0; accum_clr = 1'b0;
            host_tile_depth = 6'd63;  // 63 MACs before gate closes; reset on each clear
            sa_accum_en = 1'b0; sa_accum_clr = 1'b0;
            row_act_0 = 13'd0; row_act_1 = 13'd0;
            row_act_2 = 13'd0; row_act_3 = 13'd0;
            col_wt_0  = 13'd0; col_wt_1  = 13'd0;
            col_wt_2  = 13'd0; col_wt_3  = 13'd0;
            repeat(5) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // Clear accumulator (1-cycle accum_clr pulse); also re-opens the tile budget.
    task clear_accum;
        begin
            @(negedge clk); accum_clr = 1'b1; op_sel = 2'b11;
            host_tile_depth = 6'd63;
            @(posedge clk); #1;
            @(negedge clk); accum_clr = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // Execute single operation; latch result on next posedge
    task exec_op;
        input [12:0] a, b;
        input [1:0]  sel;
        input [2:0]  mode;
        input        do_accum;
        begin
            @(negedge clk);
            op_a      = a;
            op_b      = b;
            op_sel    = sel;
            mode_tag  = mode;
            accum_en  = do_accum;
            @(posedge clk); #1;
        end
    endtask

    // Write one CSV row
    task log_csv;
        input integer tid, sub, cyc;
        input [2:0]   mode;
        input [5:0]   sE, fv;
        input integer opc;
        input [12:0]  res;
        input [31:0]  acc;
        input integer luf, lovf, lro, lextra;
        begin
            $fwrite(csv_fd,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                tid, sub, cyc, mode, sE, fv, opc,
                res, acc, luf, lovf, lro, lextra);
        end
    endtask

    // Advance 16-bit Fibonacci LFSR (taps 16,14,13,11)
    task lfsr_step;
        begin
            lfsr_state = {lfsr_state[14:0],
                          lfsr_state[15] ^ lfsr_state[13]
                                         ^ lfsr_state[12]
                                         ^ lfsr_state[10]};
        end
    endtask

    // =========================================================================
    // Watchdog
    // =========================================================================
    initial begin : WATCHDOG
        #30_000_000; $display("*** HBS-14 WATCHDOG ***"); $finish;
    end

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin : MAIN

        $display("");
        $display("==============================================================");
        $display("  HBS-14: End-to-End System Consistency Suite");
        $display("  Policies: 000(STD) 001(BIAS,LUT=0) 010(PRSC) 011(SAFE)");
        $display("==============================================================");

        // ── Stimulus table: 32 representative operands ────────────────────
        // Mix of stable, near-boundary, and boundary-crossing E values.
        a14_E[ 0]=16; a14_f[ 0]= 0;   // first stable
        a14_E[ 1]=16; a14_f[ 1]=31;
        a14_E[ 2]=16; a14_f[ 2]=63;
        a14_E[ 3]=20; a14_f[ 3]=15;
        a14_E[ 4]=24; a14_f[ 4]= 0;   // safe self-mul anchor
        a14_E[ 5]=24; a14_f[ 5]=31;
        a14_E[ 6]=24; a14_f[ 6]=63;
        a14_E[ 7]=28; a14_f[ 7]=31;
        a14_E[ 8]=32; a14_f[ 8]= 0;   // natural anchor (E=actual 0)
        a14_E[ 9]=32; a14_f[ 9]=31;
        a14_E[10]=32; a14_f[10]=63;
        a14_E[11]=36; a14_f[11]=31;
        a14_E[12]=40; a14_f[12]= 0;
        a14_E[13]=40; a14_f[13]=31;
        a14_E[14]=44; a14_f[14]=31;
        a14_E[15]=47; a14_f[15]=31;   // last stable
        a14_E[16]=15; a14_f[16]= 0;   // collapse boundary
        a14_E[17]=15; a14_f[17]=31;
        a14_E[18]=15; a14_f[18]=32;   // ADD rescue threshold
        a14_E[19]=15; a14_f[19]=63;
        a14_E[20]=14; a14_f[20]=31;   // collapse zone
        a14_E[21]=12; a14_f[21]=31;
        a14_E[22]=48; a14_f[22]= 0;   // saturation boundary
        a14_E[23]=48; a14_f[23]=31;
        a14_E[24]=49; a14_f[24]=31;   // saturation zone
        a14_E[25]=51; a14_f[25]=31;
        a14_E[26]=47; a14_f[26]=32;   // ADD push threshold
        a14_E[27]=47; a14_f[27]=63;
        a14_E[28]= 0; a14_f[28]= 0;   // floor sentinel
        a14_E[29]= 1; a14_f[29]=31;   // near-floor
        a14_E[30]=63; a14_f[30]=63;   // near-max
        a14_E[31]=32; a14_f[31]=16;   // mid-stable

        // ── Open CSV ──────────────────────────────────────────────────────
        csv_fd = $fopen("HBS14_SYSTEM_INTEGRATION.csv", "w");
        $fwrite(csv_fd, "test_id,subtest,cyc,mode_tag,stored_E,f_val,op_code,result,accum_out,uf,ovf,rollover,extra\n");

        do_reset;
        lfsr_state = 16'hACE1;  // non-zero seed

        // =================================================================
        // HBS-14A  FULL PIPELINE CONSISTENCY TEST
        // ─────────────────────────────────────────────────────────────────
        // For each of 32 representative stimuli:
        //   Run MUL(x,x) under all 4 modes (no accum).
        //   Result must be identical across modes.
        // Then:
        //   Run all 32 with accum_en=1 under each mode; compare accum_out.
        //
        // subtest: 0=STD 1=BIAS 2=PRSC 3=SAFE (result comparison)
        //          4=STD 5=BIAS 6=PRSC 7=SAFE (accum comparison)
        // =================================================================
        $display("  [HBS-14A] Full Pipeline Consistency...");

        // Part 1: result consistency (no accum)
        for (g_n = 0; g_n < 32; g_n = g_n + 1) begin
            t_E = a14_E[g_n][5:0];
            t_f = a14_f[g_n][5:0];
            t_x = {1'b0, t_E, t_f};

            exec_op(t_x, t_x, 2'b10, MODE_STD,  1'b0);
            a14_res[0] = result;
            log_csv(14, 0, g_n, MODE_STD, t_E, t_f, 3, result, accum_out,
                    underflow_flag, exp_ovf_flag, rollover_flag, t_x);

            exec_op(t_x, t_x, 2'b10, MODE_BIAS, 1'b0);
            a14_res[1] = result;
            log_csv(14, 1, g_n, MODE_BIAS, t_E, t_f, 3, result, accum_out,
                    underflow_flag, exp_ovf_flag, rollover_flag, a14_res[0]);

            exec_op(t_x, t_x, 2'b10, MODE_PRSC, 1'b0);
            a14_res[2] = result;
            log_csv(14, 2, g_n, MODE_PRSC, t_E, t_f, 3, result, accum_out,
                    underflow_flag, exp_ovf_flag, rollover_flag, a14_res[0]);

            exec_op(t_x, t_x, 2'b10, MODE_SAFE, 1'b0);
            a14_res[3] = result;
            log_csv(14, 3, g_n, MODE_SAFE, t_E, t_f, 3, result, accum_out,
                    underflow_flag, exp_ovf_flag, rollover_flag, a14_res[0]);
        end

        // Part 2: accumulator comparison under each mode
        begin : A14_ACCUM
            integer mi;
            reg [2:0] modes [0:3];
            modes[0] = MODE_STD;
            modes[1] = MODE_BIAS;
            modes[2] = MODE_PRSC;
            modes[3] = MODE_SAFE;

            for (mi = 0; mi < 4; mi = mi + 1) begin
                clear_accum;
                for (g_n = 0; g_n < 32; g_n = g_n + 1) begin
                    t_E = a14_E[g_n][5:0];
                    t_f = a14_f[g_n][5:0];
                    t_x = {1'b0, t_E, t_f};
                    exec_op(t_x, t_x, 2'b10, modes[mi], 1'b1);
                    log_csv(14, mi+4, g_n, modes[mi], t_E, t_f, 3,
                            result, accum_out,
                            underflow_flag, exp_ovf_flag, rollover_flag, 0);
                end
            end
        end
        $display("  [HBS-14A] %0d rows logged.", 32*4 + 32*4);

        // =================================================================
        // HBS-14B  MODE INTERFERENCE TEST
        // ─────────────────────────────────────────────────────────────────
        // 500 cycles with LFSR-driven mode_tag and operands.
        // Operands weighted toward boundary zones (E=14..18, E=46..50).
        // No accum_en — testing result consistency only.
        //
        // subtest=0: random-mode stream (logged result and current mode)
        // extra = mode_tag used (for grouping in analysis)
        // =================================================================
        $display("  [HBS-14B] Mode Interference...");
        begin : B14_LOOP
            reg [2:0]  b14_mode;
            reg [5:0]  b14_E;
            reg [5:0]  b14_f;
            reg [12:0] b14_x;
            integer    b14_E_raw;

            for (g_n = 0; g_n < 500; g_n = g_n + 1) begin
                lfsr_step;
                b14_mode = lfsr_state[2:0];     // 3-bit mode (000..011 valid)
                if (b14_mode[2]) b14_mode = 3'b000;  // clamp reserved to STD

                // Operand: bias toward boundary zones
                // lfsr[7:2] selects E; weighted by lfsr[1:0]
                b14_E_raw = lfsr_state[7:2];   // 0..63
                if (lfsr_state[1:0] == 2'b00) begin
                    // 25% near collapse
                    b14_E = 14 + (lfsr_state[5:4] % 5);
                end else if (lfsr_state[1:0] == 2'b01) begin
                    // 25% near saturation
                    b14_E = 46 + (lfsr_state[5:4] % 5);
                end else begin
                    // 50% random
                    b14_E = b14_E_raw[5:0];
                end
                b14_f = lfsr_state[13:8] & 6'h3F;
                b14_x = {1'b0, b14_E, b14_f};

                exec_op(b14_x, b14_x, 2'b10, b14_mode, 1'b0);
                log_csv(15, 0, g_n, b14_mode, b14_E, b14_f, 3,
                        result, accum_out,
                        underflow_flag, exp_ovf_flag, rollover_flag, b14_x);
            end

            // Also run 100 cycles of mode-switching WITH accum_en to test
            // mixed-mode accumulator state
            clear_accum;
            for (g_n = 0; g_n < 100; g_n = g_n + 1) begin
                lfsr_step;
                b14_mode = lfsr_state[2:0];
                if (b14_mode[2]) b14_mode = 3'b000;
                b14_E = 28 + (lfsr_state[5:2] & 4'hF);  // E=28..43 (stable zone)
                b14_f = lfsr_state[13:8] & 6'h3F;
                b14_x = {1'b0, b14_E[5:0], b14_f};
                exec_op(b14_x, b14_x, 2'b10, b14_mode, 1'b1);
                log_csv(15, 1, g_n, b14_mode, b14_E[5:0], b14_f, 3,
                        result, accum_out,
                        underflow_flag, exp_ovf_flag, rollover_flag, 0);
            end
        end
        $display("  [HBS-14B] 600 rows logged.");

        // =================================================================
        // HBS-14C  CROSS-REGIME CONTRADICTION TEST
        // ─────────────────────────────────────────────────────────────────
        // 4 sequences that deliberately cross phase boundaries mid-chain.
        // For each sequence: run under MODE_STD and MODE_PRSC, compare.
        //
        // Sequence 0: E=24 scale-down through E=15 (collapse boundary)
        //   → MUL(x,x) at E=15 must UF regardless of mode.
        // Sequence 1: E=47 ADD(x,x) with f≥32 → pushes into E=48 (OVF)
        //   → OVF must fire regardless of mode.
        // Sequence 2: E=24 MUL(x, ONE) through collapse zone
        //   → identity preserved regardless of mode.
        // Sequence 3: E=32 deep chain with mode switch mid-chain
        //   → result unaffected; accum_out changes at mode switch.
        //
        // subtest = sequence index × 2 + mode (0=STD, 1=PRSC)
        // =================================================================
        $display("  [HBS-14C] Cross-Regime Contradiction...");
        begin : C14_LOOP
            integer c_seq, c_mi;
            reg [12:0] c_x;
            reg [2:0]  c_modes [0:1];
            c_modes[0] = MODE_STD;
            c_modes[1] = MODE_PRSC;

            // Sequence 0: scale-down from E=24 to floor, MUL(x,x) at each step
            for (c_mi = 0; c_mi < 2; c_mi = c_mi + 1) begin
                clear_accum;
                c_x = {1'b0, 6'd24, 6'd31};
                for (g_d = 0; g_d < 20; g_d = g_d + 1) begin
                    exec_op(c_x, c_x, 2'b10, c_modes[c_mi], 1'b1);
                    log_csv(16, c_mi, g_d,
                            c_modes[c_mi],
                            c_x[11:6], c_x[5:0], 3,
                            result, accum_out,
                            underflow_flag, exp_ovf_flag, rollover_flag, c_x);
                    exec_op(c_x, NFE_HALF, 2'b10, c_modes[c_mi], 1'b0);
                    c_x = result;
                end
            end

            // Sequence 1: E=47, ADD(x,x) with varying f — some cross to OVF
            for (c_mi = 0; c_mi < 2; c_mi = c_mi + 1) begin
                clear_accum;
                for (g_n = 0; g_n < 16; g_n = g_n + 1) begin
                    t_f = (g_n * 4) & 6'h3F;   // f = 0,4,8..60
                    c_x = {1'b0, 6'd47, t_f};
                    exec_op(c_x, c_x, 2'b00, c_modes[c_mi], 1'b1);  // ADD
                    log_csv(16, c_mi+2, g_n,
                            c_modes[c_mi], 6'd47, t_f, 1,
                            result, accum_out,
                            underflow_flag, exp_ovf_flag, rollover_flag, c_x);
                end
            end

            // Sequence 2: identity through collapse zone under both modes
            for (c_mi = 0; c_mi < 2; c_mi = c_mi + 1) begin
                clear_accum;
                c_x = {1'b0, 6'd24, 6'd31};
                for (g_d = 0; g_d < 25; g_d = g_d + 1) begin
                    exec_op(c_x, NFE_ONE, 2'b10, c_modes[c_mi], 1'b0);
                    log_csv(16, c_mi+4, g_d,
                            c_modes[c_mi],
                            c_x[11:6], c_x[5:0], 3,
                            result, accum_out,
                            underflow_flag, exp_ovf_flag, rollover_flag, c_x);
                    exec_op(c_x, NFE_HALF, 2'b10, c_modes[c_mi], 1'b0);
                    c_x = result;
                end
            end

            // Sequence 3: E=32 chain with mid-chain mode switch (STD→PRSC)
            clear_accum;
            c_x = {1'b0, 6'd32, 6'd31};
            for (g_d = 0; g_d < 32; g_d = g_d + 1) begin
                // Switch mode at depth 16
                if (g_d < 16)
                    c_mi = 0;
                else
                    c_mi = 1;
                exec_op(c_x, c_x, 2'b10, c_modes[c_mi], 1'b1);
                log_csv(16, 6, g_d,
                        c_modes[c_mi],
                        c_x[11:6], c_x[5:0], 3,
                        result, accum_out,
                        underflow_flag, exp_ovf_flag, rollover_flag, c_x);
                exec_op(c_x, NFE_HALF, 2'b10, c_modes[c_mi], 1'b0);
                c_x = result;
            end
        end
        $display("  [HBS-14C] ~222 rows logged.");

        // =================================================================
        // HBS-14D  LONG HORIZON STABILITY  (2000-cycle stream)
        // ─────────────────────────────────────────────────────────────────
        // Repeating 16-cycle pattern × 125 iterations:
        //   Phase 0 (4 cycles): stable MUL, E=32, f varies → NORM expected
        //   Phase 1 (4 cycles): boundary MUL, alternating E=15/16 → UF/NORM
        //   Phase 2 (4 cycles): ADD, boundary operands
        //   Phase 3 (4 cycles): NOP flush
        // Mode: STD for first 500 cycles, PRSC for 500, SAFE for 500, back to STD
        //
        // Metrics logged: result, accum_out, uf, ovf, rollover
        // extra = iteration index (for drift analysis)
        // =================================================================
        $display("  [HBS-14D] Long Horizon Stability (2000 cycles)...");
        begin : D14_LOOP
            integer d14_phase, d14_iter;
            reg [2:0] d14_mode;
            reg [12:0] d14_x;
            reg [5:0]  d14_f;

            d14_uf_cnt    = 0;
            d14_ovf_cnt   = 0;
            d14_floor_cnt = 0;
            d14_total     = 0;

            clear_accum;

            for (d14_iter = 0; d14_iter < 125; d14_iter = d14_iter + 1) begin
                // Mode schedule: changes every 500 cycles (31 iters)
                if (d14_iter < 32)
                    d14_mode = MODE_STD;
                else if (d14_iter < 63)
                    d14_mode = MODE_PRSC;
                else if (d14_iter < 94)
                    d14_mode = MODE_SAFE;
                else
                    d14_mode = MODE_STD;

                d14_f = (d14_iter * 13) & 6'h3F;  // deterministic f rotation

                // Phase 0: stable MUL (E=32)
                for (d14_phase = 0; d14_phase < 4; d14_phase = d14_phase + 1) begin
                    d14_x = {1'b0, 6'd32, d14_f};
                    exec_op(d14_x, d14_x, 2'b10, d14_mode, 1'b1);
                    log_csv(17, 0, d14_iter*16+d14_phase, d14_mode,
                            d14_x[11:6], d14_x[5:0], 3,
                            result, accum_out,
                            underflow_flag, exp_ovf_flag, rollover_flag, d14_iter);
                    if (underflow_flag) d14_uf_cnt  = d14_uf_cnt  + 1;
                    if (exp_ovf_flag)   d14_ovf_cnt = d14_ovf_cnt + 1;
                    if (result == 13'd0) d14_floor_cnt = d14_floor_cnt + 1;
                    d14_total = d14_total + 1;
                end

                // Phase 1: boundary MUL (alternating E=15 and E=16)
                for (d14_phase = 0; d14_phase < 4; d14_phase = d14_phase + 1) begin
                    if (d14_phase[0] == 0)
                        d14_x = {1'b0, 6'd15, d14_f};
                    else
                        d14_x = {1'b0, 6'd16, d14_f};
                    exec_op(d14_x, d14_x, 2'b10, d14_mode, 1'b1);
                    log_csv(17, 1, d14_iter*16+4+d14_phase, d14_mode,
                            d14_x[11:6], d14_x[5:0], 3,
                            result, accum_out,
                            underflow_flag, exp_ovf_flag, rollover_flag, d14_iter);
                    if (underflow_flag) d14_uf_cnt  = d14_uf_cnt  + 1;
                    if (exp_ovf_flag)   d14_ovf_cnt = d14_ovf_cnt + 1;
                    if (result == 13'd0) d14_floor_cnt = d14_floor_cnt + 1;
                    d14_total = d14_total + 1;
                end

                // Phase 2: ADD with boundary operands
                for (d14_phase = 0; d14_phase < 4; d14_phase = d14_phase + 1) begin
                    d14_x = {1'b0, 6'd24, d14_f};
                    exec_op(d14_x, d14_x, 2'b00, d14_mode, 1'b1);  // ADD
                    log_csv(17, 2, d14_iter*16+8+d14_phase, d14_mode,
                            d14_x[11:6], d14_x[5:0], 1,
                            result, accum_out,
                            underflow_flag, exp_ovf_flag, rollover_flag, d14_iter);
                    d14_total = d14_total + 1;
                end

                // Phase 3: NOP flush + tile budget refresh (gate re-opens)
                for (d14_phase = 0; d14_phase < 4; d14_phase = d14_phase + 1) begin
                    exec_op(13'd0, 13'd0, 2'b11, d14_mode, 1'b0);
                end
                // Periodic budget reset every 8 iterations (~96 MACs)
                if ((d14_iter & 7) == 7) begin
                    @(negedge clk); accum_clr = 1'b1; op_sel = 2'b11;
                    host_tile_depth = 6'd63;
                    @(posedge clk); #1;
                    @(negedge clk); accum_clr = 1'b0;
                    @(posedge clk); #1;
                end
            end
        end
        $display("  [HBS-14D] 1500 rows logged.  UF:%0d OVF:%0d Floor:%0d / %0d",
                 d14_uf_cnt, d14_ovf_cnt, d14_floor_cnt, d14_total);

        // =================================================================
        // HBS-14E  POLICY + ARITHMETIC INTERACTION TEST
        // ─────────────────────────────────────────────────────────────────
        // For each of 32 stimuli: run the same operation under all 4 modes.
        // accum_en = 1 for all to test the full accumulator path.
        //
        // Critical check: result must equal MODE_STD result for all modes.
        // Accumulator may legitimately differ (policy effect).
        //
        // Reference (mode=000) is logged in extra field for comparison.
        // =================================================================
        $display("  [HBS-14E] Policy + Arithmetic Interaction...");
        begin : E14_LOOP
            integer e_mode;
            reg [2:0] e_modes [0:3];
            reg [12:0] e_ref;
            e_modes[0] = MODE_STD;
            e_modes[1] = MODE_BIAS;
            e_modes[2] = MODE_PRSC;
            e_modes[3] = MODE_SAFE;
            e14_res_mismatch = 0;

            for (g_n = 0; g_n < 32; g_n = g_n + 1) begin
                t_E = a14_E[g_n][5:0];
                t_f = a14_f[g_n][5:0];
                t_x = {1'b0, t_E, t_f};

                // First get reference result under MODE_STD
                exec_op(t_x, t_x, 2'b10, MODE_STD, 1'b0);
                e_ref = result;

                // Run under each mode with accum; compare result to reference
                for (e_mode = 0; e_mode < 4; e_mode = e_mode + 1) begin
                    clear_accum;
                    exec_op(t_x, t_x, 2'b10, e_modes[e_mode], 1'b1);
                    if (result != e_ref)
                        e14_res_mismatch = e14_res_mismatch + 1;
                    log_csv(18, e_mode, g_n, e_modes[e_mode], t_E, t_f, 3,
                            result, accum_out,
                            underflow_flag, exp_ovf_flag, rollover_flag, e_ref);
                end
            end
        end
        $display("  [HBS-14E] 128 rows. Result mismatches vs STD: %0d",
                 e14_res_mismatch);

        // =================================================================
        // HBS-14G  SYSTOLIC ARRAY CONSISTENCY
        // ─────────────────────────────────────────────────────────────────
        // Test 1: All-zero inputs → all row_out = 0 after clr
        // Test 2: All NFE_ONE weights, all NFE_ONE activations
        //         → row_out = sum of accum'd products (deterministic)
        // Test 3: Row-differentiated activations: row_r = {0,24+r,31}
        //         → verify row_out values are row-distinct
        //
        // subtest=0: zero test
        // subtest=1: uniform 1.0 test
        // subtest=2: row-differentiated test
        // =================================================================
        $display("  [HBS-14G] Systolic Array Consistency...");

        // Test 0: zero inputs
        @(negedge clk); sa_accum_clr = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); sa_accum_clr = 1'b0;
        @(posedge clk); #1;
        @(negedge clk); sa_accum_en = 1'b0;
        @(posedge clk); #1;
        log_csv(19, 0, 0, MODE_STD, 6'd0, 6'd0, 3,
                13'd0, row_out_0, 0, 0, 0, row_out_1);

        // Test 1: all NFE_ONE × NFE_ONE, 8 stream cycles
        @(negedge clk);
        sa_accum_clr = 1'b1;
        row_act_0 = NFE_ONE; row_act_1 = NFE_ONE;
        row_act_2 = NFE_ONE; row_act_3 = NFE_ONE;
        col_wt_0  = NFE_ONE; col_wt_1  = NFE_ONE;
        col_wt_2  = NFE_ONE; col_wt_3  = NFE_ONE;
        @(posedge clk); #1;
        @(negedge clk); sa_accum_clr = 1'b0; sa_accum_en = 1'b1;
        @(posedge clk); #1;
        repeat(7) begin
            @(negedge clk);
            @(posedge clk); #1;
        end
        @(negedge clk); sa_accum_en = 1'b0;
        @(posedge clk); #1;
        sa_row[0] = row_out_0; sa_row[1] = row_out_1;
        sa_row[2] = row_out_2; sa_row[3] = row_out_3;
        log_csv(19, 1, 0, MODE_STD, 6'd32, 6'd0, 3,
                13'd0, sa_row[0], 0, 0, 0, sa_row[1]);
        log_csv(19, 1, 1, MODE_STD, 6'd32, 6'd0, 3,
                13'd0, sa_row[2], 0, 0, 0, sa_row[3]);

        // Test 2: row-differentiated activations
        @(negedge clk);
        sa_accum_clr = 1'b1;
        row_act_0 = {1'b0, 6'd24, 6'd31};
        row_act_1 = {1'b0, 6'd28, 6'd31};
        row_act_2 = {1'b0, 6'd32, 6'd31};
        row_act_3 = {1'b0, 6'd36, 6'd31};
        col_wt_0  = NFE_ONE; col_wt_1 = NFE_ONE;
        col_wt_2  = NFE_ONE; col_wt_3 = NFE_ONE;
        @(posedge clk); #1;
        @(negedge clk); sa_accum_clr = 1'b0; sa_accum_en = 1'b1;
        @(posedge clk); #1;
        repeat(7) begin
            @(negedge clk);
            @(posedge clk); #1;
        end
        @(negedge clk); sa_accum_en = 1'b0;
        @(posedge clk); #1;
        sa_row[0] = row_out_0; sa_row[1] = row_out_1;
        sa_row[2] = row_out_2; sa_row[3] = row_out_3;
        log_csv(19, 2, 0, MODE_STD, 6'd24, 6'd31, 3,
                13'd0, sa_row[0], 0, 0, 0, sa_row[1]);
        log_csv(19, 2, 1, MODE_STD, 6'd36, 6'd31, 3,
                13'd0, sa_row[2], 0, 0, 0, sa_row[3]);

        $display("  [HBS-14G] row_out_0=%0d row_out_1=%0d row_out_2=%0d row_out_3=%0d",
                 sa_row[0], sa_row[1], sa_row[2], sa_row[3]);

        // ── Close CSV ────────────────────────────────────────────────────
        $fclose(csv_fd);
        $display("");
        $display("  CSV  → HBS14_SYSTEM_INTEGRATION.csv");
        $display("  Next → python3 analyze_hbs14.py");
        $display("==============================================================");
        $finish;
    end // MAIN

endmodule
