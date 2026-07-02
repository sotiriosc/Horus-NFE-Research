`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c20_boundary_trace
// Project  : HORUS v3 — HBS-C20: Closure Firewall Localization &
//            Causal Boundary Extraction
//
// Purpose  : Locate the exact causal boundary surface inside the HORUS v3
//            pipeline where injected perturbations stop propagating.
//            Characterize the geometry of that boundary via three isolation
//            stress modes.
//
// Architecture: Two simultaneous DUT instances (dut_ref / dut_inj) sharing
//   a clock.  dut_ref always receives canonical locked inputs.  dut_inj
//   receives controlled injection per mode.  Five boundary probes are
//   instrumented on BOTH paths:
//
//     B0  Input injection boundary    {op_a, op_b, op_sel, mode_tag, accum_clr}
//     B1  ALU compute boundary        {mant_sum, computed}
//     B2  Accumulation write boundary {accum_word, accum_reg}
//     B3  Output encoding boundary    {result, flags}
//     B4  Observation boundary        {result[11:6] = E-field, shadow_e_inj}
//
// Modes (2,000 cycles each = 6,000 total):
//
//   Mode A — Pure Injection Propagation Trace
//     A1 (local   0– 671, 672 cy): op_a_inj only (LFSR E-field sweep)
//     A2 (local 672–1343, 672 cy): mode_tag_inj only (LFSR 2-bit noise)
//     A3 (local 1344–1999, 656 cy): accum_clr_inj only (LFSR aggressive clr)
//
//   Mode B — Deterministic Reverse Isolation Sweep (2,000 cycles)
//     B1 (local   0– 999): op_a E-field sweep 0→63→0 + mode_tag cycling
//     B2 (local 1000–1999): pure mode_tag cycling, op_a locked canonical
//     Python: regression to extract dependency graph empirically
//
//   Mode C — Boundary Saturation Sweep (2,000 cycles)
//     op_a_inj locked canonical (no op_a perturbation — state-only stress)
//     mode_tag_inj = LFSR 100% BER
//     accum_clr_inj = LFSR random
//     shadow_e_inj = result_ref[11:6] ^ lfsr[5:0]  (observer jitter)
//
// Total: 6,000 cycles
//
// CSV: HBS_C20_BOUNDARY_TRACE.csv
// Columns:
//   cycle, mode, sub_mode, local_cycle, inj_channel,
//   b0_op_a_ref, b0_op_a_inj, b0_op_a_delta,
//   b0_mode_tag_ref, b0_mode_tag_inj, b0_mode_tag_delta,
//   b0_accum_clr_ref, b0_accum_clr_inj, b0_accum_clr_delta,
//   b1_mant_sum_ref, b1_mant_sum_inj, b1_mant_sum_delta,
//   b1_computed_ref, b1_computed_inj, b1_computed_delta,
//   b2_accum_word_ref, b2_accum_word_inj, b2_accum_word_delta,
//   b2_accum_reg_ref, b2_accum_reg_inj, b2_accum_reg_delta,
//   b3_result_ref, b3_result_inj, b3_result_delta,
//   b4_e_field_ref, b4_e_field_inj, b4_shadow_e_inj,
//   lfsr_state
// ============================================================================

module tb_hbs_c20_boundary_trace;

    // =========================================================================
    // Op-sel constants
    // =========================================================================
    localparam OP_ADD = 2'b00;
    localparam OP_MUL = 2'b10;

    localparam MODE_STANDARD  = 3'b000;

    // Canonical locked inputs (from C17 baseline)
    localparam [12:0] FIXED_OP_A = {1'b0, 6'd32, 6'd32};
    localparam [12:0] FIXED_OP_B = {1'b0, 6'd0,  6'd16};
    localparam [1:0]  FIXED_SEL  = OP_ADD;
    localparam [2:0]  FIXED_MODE = MODE_STANDARD;

    // Injection channel encoding (logged in CSV as inj_channel)
    localparam INJ_NONE    = 3'd0;
    localparam INJ_OP_A    = 3'd1;
    localparam INJ_MODE_TAG= 3'd2;
    localparam INJ_ACCUM   = 3'd3;
    localparam INJ_SWEEP   = 3'd4;
    localparam INJ_SATUR   = 3'd5;

    // Mode A sub-mode cycle boundaries
    localparam A1_END  = 672;   // op_a LFSR injection
    localparam A2_END  = 1344;  // mode_tag LFSR injection
    // A3: 1344-1999 (656 cy) accum divergence

    // =========================================================================
    // Clock + reset
    // =========================================================================
    reg clk, rst_n;
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // =========================================================================
    // 16-bit Fibonacci LFSR (seed 0xACE1, poly x^16+x^14+x^13+x^11+1)
    // =========================================================================
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= {lfsr[14:0],
                             lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    // =========================================================================
    // Deterministic sweep counter (Mode B)
    // =========================================================================
    reg [5:0] b_sweep_e;      // E-field sweep 0→63→0... for op_a_inj
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) b_sweep_e <= 6'd0;
        else        b_sweep_e <= b_sweep_e + 6'd1;  // wraps mod 64
    end

    // =========================================================================
    // DUT_REF inputs / outputs
    // =========================================================================
    reg  [12:0] op_a_ref,  op_b_ref;
    reg  [1:0]  op_sel_ref;
    reg  [2:0]  mode_tag_ref;
    reg         accum_en_ref,  accum_clr_ref;
    reg  [5:0]  depth_ref;

    wire [12:0] result_ref;
    wire [31:0] accum_out_ref;
    wire        rollover_ref, uf_ref, ovf_ref;
    wire [15:0] op_count_ref;
    wire        accum_full_ref;

    horus_system dut_ref (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a_ref), .op_b(op_b_ref), .op_sel(op_sel_ref),
        .mode_tag(mode_tag_ref),
        .accum_en(accum_en_ref), .accum_clr(accum_clr_ref),
        .host_tile_depth(depth_ref),
        .result(result_ref), .accum_out(accum_out_ref),
        .rollover_flag(rollover_ref), .underflow_flag(uf_ref),
        .exp_ovf_flag(ovf_ref),
        .op_count(op_count_ref), .accum_full(accum_full_ref)
    );

    // =========================================================================
    // DUT_INJ inputs / outputs
    // =========================================================================
    reg  [12:0] op_a_inj,  op_b_inj;
    reg  [1:0]  op_sel_inj;
    reg  [2:0]  mode_tag_inj;
    reg         accum_en_inj,  accum_clr_inj;
    reg  [5:0]  depth_inj;

    wire [12:0] result_inj;
    wire [31:0] accum_out_inj;
    wire        rollover_inj, uf_inj, ovf_inj;
    wire [15:0] op_count_inj;
    wire        accum_full_inj;

    horus_system dut_inj (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a_inj), .op_b(op_b_inj), .op_sel(op_sel_inj),
        .mode_tag(mode_tag_inj),
        .accum_en(accum_en_inj), .accum_clr(accum_clr_inj),
        .host_tile_depth(depth_inj),
        .result(result_inj), .accum_out(accum_out_inj),
        .rollover_flag(rollover_inj), .underflow_flag(uf_inj),
        .exp_ovf_flag(ovf_inj),
        .op_count(op_count_inj), .accum_full(accum_full_inj)
    );

    // =========================================================================
    // Internal boundary probes
    // =========================================================================
    // B1
    wire [7:0]  p_mant_sum_ref = dut_ref.u_nfe.mant_sum;
    wire [7:0]  p_mant_sum_inj = dut_inj.u_nfe.mant_sum;
    wire [12:0] p_computed_ref = dut_ref.u_nfe.computed;
    wire [12:0] p_computed_inj = dut_inj.u_nfe.computed;
    // B2
    wire [12:0] p_accum_word_ref = dut_ref.u_nfe.accum_word;
    wire [12:0] p_accum_word_inj = dut_inj.u_nfe.accum_word;
    wire [31:0] p_accum_ref      = dut_ref.u_nfe.accum_reg;
    wire [31:0] p_accum_inj      = dut_inj.u_nfe.accum_reg;

    // =========================================================================
    // Delta computation registers (sampled at negedge before each posedge)
    // =========================================================================
    reg [12:0] prev_computed_ref, prev_computed_inj;
    reg [31:0] prev_accum_ref,    prev_accum_inj;
    reg [12:0] prev_result_ref,   prev_result_inj;
    reg [7:0]  prev_mant_ref,     prev_mant_inj;
    reg [12:0] prev_aw_ref,       prev_aw_inj;
    reg [12:0] prev_op_a_ref,     prev_op_a_inj;
    reg [2:0]  prev_mt_ref,       prev_mt_inj;
    reg        prev_clr_ref,      prev_clr_inj;

    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_computed_ref <= 13'd0; prev_computed_inj <= 13'd0;
            prev_accum_ref    <= 32'd0; prev_accum_inj    <= 32'd0;
            prev_result_ref   <= 13'd0; prev_result_inj   <= 13'd0;
            prev_mant_ref     <=  8'd0; prev_mant_inj     <=  8'd0;
            prev_aw_ref       <= 13'd0; prev_aw_inj       <= 13'd0;
            prev_op_a_ref     <= 13'd0; prev_op_a_inj     <= 13'd0;
            prev_mt_ref       <=  3'd0; prev_mt_inj       <=  3'd0;
            prev_clr_ref      <=  1'b0; prev_clr_inj      <=  1'b0;
        end else begin
            prev_computed_ref <= p_computed_ref;
            prev_computed_inj <= p_computed_inj;
            prev_accum_ref    <= p_accum_ref;
            prev_accum_inj    <= p_accum_inj;
            prev_result_ref   <= result_ref;
            prev_result_inj   <= result_inj;
            prev_mant_ref     <= p_mant_sum_ref;
            prev_mant_inj     <= p_mant_sum_inj;
            prev_aw_ref       <= p_accum_word_ref;
            prev_aw_inj       <= p_accum_word_inj;
            prev_op_a_ref     <= op_a_ref;
            prev_op_a_inj     <= op_a_inj;
            prev_mt_ref       <= mode_tag_ref;
            prev_mt_inj       <= mode_tag_inj;
            prev_clr_ref      <= accum_clr_ref;
            prev_clr_inj      <= accum_clr_inj;
        end
    end

    // =========================================================================
    // Logging
    // =========================================================================
    integer  fd;
    integer  total_cyc;
    integer  c;
    reg [2:0]  cur_inj_ch;
    reg [5:0]  shadow_e_inj;   // B4 jittered E-field for Mode C

    task log_c20;
        input integer mode_id;
        input integer sub_mode_id;
        input integer local_cyc;
    begin : LOG
        // Compute deltas (XOR for word-level, absolute diff for accumulator)
        reg b0_op_a_delta;
        reg b0_mt_delta;
        reg b0_clr_delta;
        reg b1_mant_delta;
        reg b1_comp_delta;
        reg b2_aw_delta;
        reg b2_accum_delta;
        reg b3_res_delta;

        b0_op_a_delta  = (op_a_inj != prev_op_a_inj) ? 1'b1 : 1'b0;
        b0_mt_delta    = (mode_tag_inj != prev_mt_inj) ? 1'b1 : 1'b0;
        b0_clr_delta   = (accum_clr_inj != prev_clr_inj) ? 1'b1 : 1'b0;
        b1_mant_delta  = (p_mant_sum_inj != prev_mant_inj) ? 1'b1 : 1'b0;
        b1_comp_delta  = (p_computed_inj != prev_computed_inj) ? 1'b1 : 1'b0;
        b2_aw_delta    = (p_accum_word_inj != prev_aw_inj) ? 1'b1 : 1'b0;
        b2_accum_delta = (p_accum_inj != prev_accum_inj) ? 1'b1 : 1'b0;
        b3_res_delta   = (result_inj != prev_result_inj) ? 1'b1 : 1'b0;

        $fwrite(fd,
            "%0d,%0d,%0d,%0d,%0d,",
            total_cyc, mode_id, sub_mode_id, local_cyc, cur_inj_ch);
        // B0
        $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,",
            op_a_ref, op_a_inj, b0_op_a_delta,
            mode_tag_ref, mode_tag_inj, b0_mt_delta,
            accum_clr_ref, accum_clr_inj, b0_clr_delta);
        // B1
        $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,",
            p_mant_sum_ref, p_mant_sum_inj, b1_mant_delta,
            p_computed_ref, p_computed_inj, b1_comp_delta);
        // B2
        $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,",
            p_accum_word_ref, p_accum_word_inj, b2_aw_delta,
            p_accum_ref, p_accum_inj, b2_accum_delta);
        // B3
        $fwrite(fd, "%0d,%0d,%0d,",
            result_ref, result_inj, b3_res_delta);
        // B4
        $fwrite(fd, "%0d,%0d,%0d,",
            result_ref[11:6], result_inj[11:6], shadow_e_inj);
        // LFSR state
        $fwrite(fd, "%0d\n", lfsr);

        total_cyc = total_cyc + 1;
    end
    endtask

    // =========================================================================
    // Hard reset both DUTs
    // =========================================================================
    task hard_reset_both;
    begin
        @(negedge clk);
        rst_n = 1'b0;
        accum_clr_ref = 1'b1; accum_en_ref = 1'b0;
        accum_clr_inj = 1'b1; accum_en_inj = 1'b0;
        @(negedge clk); @(negedge clk);
        @(negedge clk); rst_n = 1'b1;
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;
        @(posedge clk); #1;
    end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin : MAIN
        $display("HBS-C20: Closure Firewall Localization & Causal Boundary Extraction — 6,000 cycles");

        // Safe defaults
        op_a_ref = FIXED_OP_A; op_b_ref = FIXED_OP_B;
        op_sel_ref = FIXED_SEL; mode_tag_ref = FIXED_MODE;
        accum_en_ref = 1'b0; accum_clr_ref = 1'b0; depth_ref = 6'd63;

        op_a_inj = FIXED_OP_A; op_b_inj = FIXED_OP_B;
        op_sel_inj = FIXED_SEL; mode_tag_inj = FIXED_MODE;
        accum_en_inj = 1'b0; accum_clr_inj = 1'b0; depth_inj = 6'd63;

        rst_n = 1'b0; total_cyc = 0;
        shadow_e_inj = 6'd0; cur_inj_ch = INJ_NONE;
        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C20_BOUNDARY_TRACE.csv", "w");
        $fwrite(fd, "cycle,mode,sub_mode,local_cycle,inj_channel,");
        $fwrite(fd, "b0_op_a_ref,b0_op_a_inj,b0_op_a_delta,");
        $fwrite(fd, "b0_mode_tag_ref,b0_mode_tag_inj,b0_mode_tag_delta,");
        $fwrite(fd, "b0_accum_clr_ref,b0_accum_clr_inj,b0_accum_clr_delta,");
        $fwrite(fd, "b1_mant_sum_ref,b1_mant_sum_inj,b1_mant_sum_delta,");
        $fwrite(fd, "b1_computed_ref,b1_computed_inj,b1_computed_delta,");
        $fwrite(fd, "b2_accum_word_ref,b2_accum_word_inj,b2_accum_word_delta,");
        $fwrite(fd, "b2_accum_reg_ref,b2_accum_reg_inj,b2_accum_reg_delta,");
        $fwrite(fd, "b3_result_ref,b3_result_inj,b3_result_delta,");
        $fwrite(fd, "b4_e_field_ref,b4_e_field_inj,b4_shadow_e_inj,");
        $fwrite(fd, "lfsr_state\n");

        // ─────────────────────────────────────────────────────────────────────
        // MODE A — Pure Injection Propagation Trace (2,000 cycles)
        //
        // dut_ref: always canonical locked ADD inputs, depth=63, clr every 64cy
        // dut_inj: one injection channel active per sub-mode
        // ─────────────────────────────────────────────────────────────────────
        $display("  Mode A: Pure Injection Propagation Trace...");
        hard_reset_both;
        // Reference canonical
        op_a_ref = FIXED_OP_A; op_b_ref = FIXED_OP_B;
        op_sel_ref = FIXED_SEL; mode_tag_ref = FIXED_MODE;
        accum_en_ref = 1'b1; depth_ref = 6'd63;
        // Injection baseline
        op_b_inj = FIXED_OP_B; op_sel_inj = FIXED_SEL;
        accum_en_inj = 1'b1; depth_inj = 6'd63;

        for (c = 0; c < 2000; c = c+1) begin
            // Reference periodic clear (re-opens gate every 64 cycles)
            accum_clr_ref = ((c % 64) == 63) ? 1'b1 : 1'b0;

            // ── A1 (0–671): op_a injection via LFSR E-field bits ───────────
            if (c < A1_END) begin
                cur_inj_ch  = INJ_OP_A;
                op_a_inj    = {1'b0, lfsr[5:0], lfsr[11:6]};  // LFSR E & f
                mode_tag_inj = FIXED_MODE;
                accum_clr_inj = accum_clr_ref;   // same as ref (isolate op_a)
                shadow_e_inj  = 6'd0;             // no shadow jitter in A1
            end

            // ── A2 (672–1343): mode_tag injection via LFSR 2 bits ─────────
            else if (c < A2_END) begin
                cur_inj_ch   = INJ_MODE_TAG;
                op_a_inj     = FIXED_OP_A;        // locked canonical
                mode_tag_inj = {1'b0, lfsr[1:0]}; // LFSR 2-bit noise
                accum_clr_inj = accum_clr_ref;
                shadow_e_inj  = 6'd0;
            end

            // ── A3 (1344–1999): accum divergence via LFSR accum_clr ───────
            else begin
                cur_inj_ch    = INJ_ACCUM;
                op_a_inj      = FIXED_OP_A;
                mode_tag_inj  = FIXED_MODE;
                accum_clr_inj = lfsr[0];          // LFSR-driven random clear
                shadow_e_inj  = 6'd0;
            end

            @(posedge clk); #1;
            log_c20(0, (c < A1_END) ? 0 : (c < A2_END) ? 1 : 2, c);
        end
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;

        // ─────────────────────────────────────────────────────────────────────
        // MODE B — Deterministic Reverse Isolation Sweep (2,000 cycles)
        //
        // B1 (0–999): op_a sweeps E-field 0→63 (64-cycle period) + mode_tag
        //             cycles 000→001→010→011 (4-cycle period)
        // B2 (1000–1999): op_a locked, mode_tag still cycling (pure state test)
        //
        // In Python: for each boundary signal, compute R² of:
        //   boundary ~ f(injection)   [forward: does injection predict boundary?]
        //   injection ~ f(boundary)   [reverse: does boundary predict injection?]
        // ─────────────────────────────────────────────────────────────────────
        $display("  Mode B: Deterministic Reverse Isolation Sweep...");
        hard_reset_both;
        op_b_ref = FIXED_OP_B; op_sel_ref = FIXED_SEL; mode_tag_ref = FIXED_MODE;
        op_b_inj = FIXED_OP_B; op_sel_inj = FIXED_SEL;
        accum_en_ref = 1'b1; depth_ref = 6'd63;
        accum_en_inj = 1'b1; depth_inj = 6'd63;

        for (c = 0; c < 2000; c = c+1) begin
            accum_clr_ref = ((c % 64) == 63) ? 1'b1 : 1'b0;
            accum_clr_inj = accum_clr_ref;

            // mode_tag cycles every 4 cycles throughout all of Mode B
            mode_tag_inj = {1'b0, c[1:0]};  // 000→001→010→011→000...

            if (c < 1000) begin
                // B1: op_a_inj sweeps E-field (64-cycle period)
                cur_inj_ch = INJ_SWEEP;
                op_a_ref   = FIXED_OP_A;
                op_a_inj   = {1'b0, b_sweep_e, 6'd32};  // E-field sweep, f=32
            end else begin
                // B2: op_a locked canonical, only mode_tag active
                cur_inj_ch = INJ_MODE_TAG;
                op_a_ref   = FIXED_OP_A;
                op_a_inj   = FIXED_OP_A;
            end
            shadow_e_inj = 6'd0;

            @(posedge clk); #1;
            log_c20(1, (c < 1000) ? 0 : 1, c);
        end
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;

        // ─────────────────────────────────────────────────────────────────────
        // MODE C — Boundary Saturation Sweep (2,000 cycles)
        //
        // op_a_inj is LOCKED canonical (no arithmetic input injection).
        // State injection at maximum amplitude:
        //   mode_tag_inj  = LFSR[1:0]  (100% BER random)
        //   accum_clr_inj = LFSR[0]    (random clearing)
        //   shadow_e_inj  = result_ref[11:6] ^ LFSR[5:0]  (observer jitter)
        //
        // Goal: does ANY saturation of state channels leak into B1 (computed)?
        // ─────────────────────────────────────────────────────────────────────
        $display("  Mode C: Boundary Saturation Sweep...");
        hard_reset_both;
        op_a_ref = FIXED_OP_A; op_b_ref = FIXED_OP_B;
        op_sel_ref = FIXED_SEL; mode_tag_ref = FIXED_MODE;
        accum_en_ref = 1'b1; depth_ref = 6'd63;

        op_a_inj = FIXED_OP_A; op_b_inj = FIXED_OP_B;
        op_sel_inj = FIXED_SEL;
        accum_en_inj = 1'b1; depth_inj = 6'd63;

        cur_inj_ch = INJ_SATUR;

        for (c = 0; c < 2000; c = c+1) begin
            accum_clr_ref = ((c % 64) == 63) ? 1'b1 : 1'b0;
            // Mode C: ALL state channels at maximum entropy
            mode_tag_inj  = {1'b0, lfsr[1:0]};  // LFSR 100% BER
            accum_clr_inj = lfsr[0];              // random aggressive clear

            @(posedge clk); #1;
            // Shadow E-field jitter (observer layer perturbation)
            shadow_e_inj = result_ref[11:6] ^ lfsr[5:0];
            log_c20(2, 0, c);
        end
        accum_clr_ref = 1'b0; accum_clr_inj = 1'b0;

        // ─────────────────────────────────────────────────────────────────────
        // Done
        // ─────────────────────────────────────────────────────────────────────
        $fclose(fd);
        $display("  Done. Total cycles: %0d", total_cyc);
        $display("  Output: HBS_C20_BOUNDARY_TRACE.csv");
        $finish;
    end

endmodule
