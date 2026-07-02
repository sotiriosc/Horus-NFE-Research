`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c17_feedback_closure
// Project  : HORUS v3 — HBS-C17: Accumulation Feedback Closure Falsification
//
// Purpose: Determine whether accum_reg EVER influences mant_sum, scale_reg,
//          or computed. If the ALU is strictly feedforward, all three are
//          completely independent of accumulator state.
//
// Method : Lock ALL primary inputs constant. Perturb ONLY the accumulation
//          path via 9 sub-tests covering 5 perturbation types:
//
//   A1_BASE   (sub 0) — accum_en=1, gate closes after 63 MACs  [500 cy]
//   A1_ALT    (sub 1) — accum_en=0, accum_reg stays 0         [500 cy]
//   A2_CLR    (sub 2) — accum_clr every 16 cycles              [500 cy]
//   A2_NOCLR  (sub 3) — no accum_clr, accum_reg grows freely   [500 cy]
//   A3_HIGH   (sub 4) — force accum_reg=0xFFFF_F000 (accum_en=0) [250 cy]
//   A3_LOW    (sub 5) — force accum_reg=0x0000_0001 (accum_en=0) [250 cy]
//   A4_ONTIME (sub 6) — accum_clr at cycles 0,16,32,...         [500 cy]
//   A4_LATE   (sub 7) — accum_clr at cycles 1,17,33,...         [500 cy]
//   A5_LONG   (sub 8) — 5,000-cycle long horizon, clr every 64  [5000 cy]
//
// Total: 8,500 cycles
//
// Fixed inputs locked for ALL sub-tests:
//   op_a = {0, E=32, f=32}  op_b = {0, E=0, f=16}  op_sel=ADD  mode_tag=000
//
// CSV columns:
//   cycle, sub_id, local_cycle,
//   accum_reg_pre, accum_word, accum_reg_post,
//   mant_sum, scale_reg, computed, result,
//   UF, OVF, accum_en_act
// ============================================================================

module tb_hbs_c17_feedback_closure;

    // =========================================================================
    // DUT
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

    horus_system dut (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a), .op_b(op_b), .op_sel(op_sel), .mode_tag(mode_tag),
        .accum_en(accum_en), .accum_clr(accum_clr),
        .host_tile_depth(host_tile_depth),
        .result(result), .accum_out(accum_out),
        .rollover_flag(rollover_flag), .underflow_flag(underflow_flag),
        .exp_ovf_flag(exp_ovf_flag), .op_count(op_count), .accum_full(accum_full)
    );

    // =========================================================================
    // Internal probe wires
    // =========================================================================
    wire [7:0]  p_mant_sum   = dut.u_nfe.mant_sum;
    wire [19:0] p_scale_reg  = dut.u_nfe.scale_reg;
    wire [12:0] p_computed   = dut.u_nfe.computed;
    wire [12:0] p_accum_word = dut.u_nfe.accum_word;
    wire [31:0] p_accum_reg  = dut.u_nfe.accum_reg;

    // =========================================================================
    // Locked inputs
    // =========================================================================
    localparam [12:0] FIXED_OP_A = {1'b0, 6'd32, 6'd32};  // E=32, f=32
    localparam [12:0] FIXED_OP_B = {1'b0, 6'd0,  6'd16};  // ADD delta=16
    localparam [1:0]  FIXED_SEL  = 2'b00;                  // ADD
    localparam [2:0]  FIXED_MODE = 3'b000;                 // STANDARD

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // Hard reset task — full synchronous reset, leaves DUT in known state
    // =========================================================================
    task hard_reset;
    begin
        @(negedge clk);
        rst_n = 1'b0; accum_clr = 1'b1; accum_en = 1'b0;
        @(negedge clk); @(negedge clk);
        @(negedge clk); rst_n = 1'b1; accum_clr = 1'b0;
        @(posedge clk); #1;
    end
    endtask

    // =========================================================================
    // Logging macro (via task — Verilog has no macros with side-effects)
    // =========================================================================
    integer fd;
    integer total_cyc, local_cyc;
    reg [31:0] ar_pre;   // accum_reg sampled at negedge before posedge

    task log_cycle;
        input integer sid;
        input integer ae_act;
    begin
        $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                total_cyc, sid, local_cyc,
                ar_pre,            // accum_reg pre-update (sampled at negedge)
                p_accum_word,      // policy-decoded word
                p_accum_reg,       // accum_reg post-update
                p_mant_sum,        // S1 ALU
                p_scale_reg,       // S1 ALU (MUL)
                p_computed,        // S2 post-ALU result
                result,            // S5 registered output
                underflow_flag,    // UF flag
                exp_ovf_flag,      // OVF flag
                ae_act);           // was accumulation active this cycle?
        total_cyc = total_cyc + 1;
        local_cyc = local_cyc + 1;
    end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    integer c;

    initial begin : MAIN
        $display("HBS-C17: Accumulation Feedback Closure Falsification — 8,500 cycles");

        // Lock all computation inputs
        op_a = FIXED_OP_A; op_b = FIXED_OP_B;
        op_sel = FIXED_SEL; mode_tag = FIXED_MODE;
        accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0; total_cyc = 0;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C17_FEEDBACK_CLOSURE.csv", "w");
        $fwrite(fd, "cycle,sub_id,local_cycle,accum_reg_pre,accum_word,accum_reg_post,");
        $fwrite(fd, "mant_sum,scale_reg,computed,result,UF,OVF,accum_en_act\n");

        // ── A1_BASE (sub 0): accum ON — gate closes after 63 MACs ────────────
        $display("  A1_BASE: accum_en=1, gate=63...");
        hard_reset;
        host_tile_depth = 6'd63; accum_en = 1'b1; accum_clr = 1'b0;
        local_cyc = 0;
        for (c = 0; c < 500; c = c+1) begin
            @(negedge clk); ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(0, (op_count < 16'd63) ? 1 : 0);
        end

        // ── A1_ALT (sub 1): accum OFF — accum_reg stays at 0 ─────────────────
        $display("  A1_ALT: accum_en=0...");
        hard_reset;
        host_tile_depth = 6'd63; accum_en = 1'b0; accum_clr = 1'b0;
        local_cyc = 0;
        for (c = 0; c < 500; c = c+1) begin
            @(negedge clk); ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(1, 0);
        end

        // ── A2_CLR (sub 2): accum_clr every 16 cycles ────────────────────────
        $display("  A2_CLR: periodic clear every 16...");
        hard_reset;
        host_tile_depth = 6'd63; accum_en = 1'b1;
        local_cyc = 0;
        for (c = 0; c < 500; c = c+1) begin
            @(negedge clk);
            accum_clr = ((c % 16) == 0) ? 1'b1 : 1'b0;
            ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(2, (op_count < 16'd63) ? 1 : 0);
        end
        accum_clr = 1'b0;

        // ── A2_NOCLR (sub 3): no accum_clr, accum_reg grows freely ──────────
        $display("  A2_NOCLR: no clear...");
        hard_reset;
        host_tile_depth = 6'd63; accum_en = 1'b1; accum_clr = 1'b0;
        local_cyc = 0;
        for (c = 0; c < 500; c = c+1) begin
            @(negedge clk); ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(3, (op_count < 16'd63) ? 1 : 0);
        end

        // ── A3_HIGH (sub 4): force accum_reg near max (accum_en=0) ───────────
        $display("  A3_HIGH: force accum_reg=0xFFFFF000...");
        hard_reset;
        accum_en = 1'b0; accum_clr = 1'b0; host_tile_depth = 6'd63;
        @(negedge clk);
        force dut.u_nfe.accum_reg = 32'hFFFF_F000;
        local_cyc = 0;
        for (c = 0; c < 250; c = c+1) begin
            @(negedge clk); ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(4, 0);
        end
        release dut.u_nfe.accum_reg;

        // ── A3_LOW (sub 5): force accum_reg near zero (accum_en=0) ───────────
        $display("  A3_LOW: force accum_reg=0x00000001...");
        hard_reset;
        accum_en = 1'b0; accum_clr = 1'b0; host_tile_depth = 6'd63;
        @(negedge clk);
        force dut.u_nfe.accum_reg = 32'h0000_0001;
        local_cyc = 0;
        for (c = 0; c < 250; c = c+1) begin
            @(negedge clk); ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(5, 0);
        end
        release dut.u_nfe.accum_reg;

        // ── A4_ONTIME (sub 6): accum_clr at 0,16,32,... (on-schedule) ────────
        $display("  A4_ONTIME: on-schedule clear...");
        hard_reset;
        host_tile_depth = 6'd63; accum_en = 1'b1;
        local_cyc = 0;
        for (c = 0; c < 500; c = c+1) begin
            @(negedge clk);
            accum_clr = ((c % 16) == 0) ? 1'b1 : 1'b0;
            ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(6, (op_count < 16'd63) ? 1 : 0);
        end
        accum_clr = 1'b0;

        // ── A4_LATE (sub 7): accum_clr at 1,17,33,... (1-cycle late) ─────────
        $display("  A4_LATE: 1-cycle-late clear...");
        hard_reset;
        host_tile_depth = 6'd63; accum_en = 1'b1;
        local_cyc = 0;
        for (c = 0; c < 500; c = c+1) begin
            @(negedge clk);
            accum_clr = ((c % 16) == 1) ? 1'b1 : 1'b0;
            ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(7, (op_count < 16'd63) ? 1 : 0);
        end
        accum_clr = 1'b0;

        // ── A5_LONG (sub 8): 5,000 cycles, accum_clr every 64, no RTL change ─
        $display("  A5_LONG: 5,000-cycle long horizon...");
        hard_reset;
        host_tile_depth = 6'd63; accum_en = 1'b1;
        local_cyc = 0;
        for (c = 0; c < 5000; c = c+1) begin
            @(negedge clk);
            accum_clr = ((c % 64) == 0) ? 1'b1 : 1'b0;
            ar_pre = p_accum_reg;
            @(posedge clk); #1;
            log_cycle(8, (op_count < 16'd63) ? 1 : 0);
        end
        accum_clr = 1'b0;

        $fclose(fd);
        $display("  8,500 cycles → HBS_C17_FEEDBACK_CLOSURE.csv");
        $finish;
    end

endmodule
