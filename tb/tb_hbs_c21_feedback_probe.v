`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c21_feedback_probe
// Project  : HORUS v3 — HBS-C21: Controlled Feedback Coupling Experiment
//            (Option A — Accumulator Right-Shift Injection)
//
// Purpose  : Introduce ONE controlled side-channel coupling from the state
//            subsystem back into the arithmetic observation path and measure
//            whether attractors become computationally visible, whether
//            closure breaks, or whether the system self-stabilizes.
//
// ARCHITECTURE INVARIANT (enforced):
//   - horus_nfe.v RTL is NOT modified
//   - horus_system.v RTL is NOT modified
//   - computed = f(op_a, op_b, op_sel) remains unaltered inside the DUT
//   - The modulation term is computed OUTSIDE the DUT (testbench layer only)
//
// Coupling formula (Option A — accumulator injection):
//
//   coupling_term = (accum_reg >> shift_k) & 13'h1FFF  [13-bit mask]
//   computed_mod  = computed + coupling_term            [13-bit wrap]
//
//   Three shift values sweep from weak to strong coupling:
//     Regime 1  (R1)  shift_k = 12  — ~accum/4096  (mantissa-only perturbation)
//     Regime 2  (R2)  shift_k = 10  — ~accum/1024  (low E-field bits affected)
//     Regime 3  (R3)  shift_k =  8  — ~accum/256   (full E-field perturbation)
//
// Input pattern (identical across all regimes for fair comparison):
//   op_a  : E-field cycles 0→63 (one increment per clock), f from LFSR
//   op_b  : fixed {1'b0, 6'd0, 6'd16}
//   op_sel: ADD (2'b00)
//   mode  : Standard (3'b000)
//   accum : enabled, depth=63, periodic clear every 64 cycles
//
// Attractor classification (on computed and computed_mod independently):
//   A1  E_field == 0          (cancellation residual)
//   A2  50 <= E_field < 63    (geometric explosion approach)
//   A3  E_field == 63         (Thoth rollover boundary)
//   A4  1 <= E_field < 50     (entropic mid-range)
//
// CSV: HBS_C21_FEEDBACK_TRACE.csv
// Columns (per cycle):
//   cycle, regime, shift_k, local_cycle,
//   op_a, op_b, op_sel,
//   computed, accum_reg, coupling_term, computed_mod,
//   e_field_base, e_field_mod,
//   attractor_base, attractor_mod, attractor_changed,
//   delta_computed, delta_mod,
//   transition_base,          <- 1 if attractor_base changed vs prev cycle
//   lfsr_state
// ============================================================================

module tb_hbs_c21_feedback_probe;

    // ── Fixed input constants ─────────────────────────────────────────────
    localparam OP_ADD  = 2'b00;
    localparam MODE_STD = 3'b000;
    localparam [12:0] FIXED_OP_B = {1'b0, 6'd0, 6'd16};

    // ── Regime shift amounts ──────────────────────────────────────────────
    localparam SHIFT_R1 = 4'd12;
    localparam SHIFT_R2 = 4'd10;
    localparam SHIFT_R3 = 4'd8;

    localparam CYCLES_PER_REGIME = 2000;

    // ── Clock / Reset ─────────────────────────────────────────────────────
    reg clk, rst_n;
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ── 16-bit LFSR ───────────────────────────────────────────────────────
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    end

    // ── E-field sweep counter (0→63→0...) ────────────────────────────────
    reg [5:0] e_sweep;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) e_sweep <= 6'd0;
        else        e_sweep <= e_sweep + 6'd1;
    end

    // ── DUT ───────────────────────────────────────────────────────────────
    reg  [12:0] op_a;
    reg  [1:0]  op_sel;
    reg  [2:0]  mode_tag;
    reg         accum_en, accum_clr;
    reg  [5:0]  host_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover, uf, ovf, accum_full;
    wire [15:0] op_count;

    horus_system dut (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a), .op_b(FIXED_OP_B), .op_sel(op_sel),
        .mode_tag(mode_tag),
        .accum_en(accum_en), .accum_clr(accum_clr),
        .host_tile_depth(host_depth),
        .result(result), .accum_out(accum_out),
        .rollover_flag(rollover), .underflow_flag(uf),
        .exp_ovf_flag(ovf),
        .op_count(op_count), .accum_full(accum_full)
    );

    // ── Internal probes ───────────────────────────────────────────────────
    wire [12:0] p_computed  = dut.u_nfe.computed;
    wire [31:0] p_accum_reg = dut.u_nfe.accum_reg;

    // ── Active coupling shift (changes per regime) ────────────────────────
    reg  [3:0]  shift_k;

    // ── Side-channel modulation (testbench only — DUT untouched) ─────────
    reg  [12:0] coupling_term;
    wire [12:0] computed_mod = p_computed + coupling_term;

    always @(*) begin
        coupling_term = (p_accum_reg >> shift_k) & 13'h1FFF;
    end

    // ── Attractor classification function ─────────────────────────────────
    // Returns 1-4 corresponding to A1-A4.
    // Operates on the 6-bit E-field (bits[11:6]) of an NFE word.
    function automatic [2:0] classify;
        input [12:0] nfe;
        reg [5:0] ef;
        begin
            ef = nfe[11:6];
            if (ef == 6'd0)              classify = 3'd1;  // A1 cancellation
            else if (ef == 6'd63)        classify = 3'd3;  // A3 rollover
            else if (ef >= 6'd50)        classify = 3'd2;  // A2 explosion
            else                         classify = 3'd4;  // A4 entropic
        end
    endfunction

    // ── Previous-cycle registers for delta / transition detection ─────────
    reg [12:0] prev_computed, prev_computed_mod;
    reg [2:0]  prev_attractor_base;

    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_computed      <= 13'd0;
            prev_computed_mod  <= 13'd0;
            prev_attractor_base <= 3'd4;
        end else begin
            prev_computed      <= p_computed;
            prev_computed_mod  <= computed_mod;
            prev_attractor_base <= classify(p_computed);
        end
    end

    // ── Logging ───────────────────────────────────────────────────────────
    integer fd;
    integer total_cyc;
    integer c;

    task log_c21;
        input integer regime_id;
        input integer local_cyc;
    begin : LOG_BLK
        reg [2:0] attr_base, attr_mod;
        reg       attr_changed, transition_base;
        reg [12:0] d_computed, d_mod;

        attr_base    = classify(p_computed);
        attr_mod     = classify(computed_mod);
        attr_changed = (attr_base != attr_mod) ? 1'b1 : 1'b0;
        transition_base = (attr_base != prev_attractor_base) ? 1'b1 : 1'b0;

        // Unsigned absolute difference (13-bit)
        d_computed = (p_computed >= prev_computed)   ?
                     (p_computed - prev_computed)    :
                     (prev_computed - p_computed);
        d_mod      = (computed_mod >= prev_computed_mod) ?
                     (computed_mod - prev_computed_mod)  :
                     (prev_computed_mod - computed_mod);

        $fwrite(fd,
            "%0d,%0d,%0d,%0d,",
            total_cyc, regime_id, shift_k, local_cyc);
        $fwrite(fd,
            "%0d,%0d,%0d,",
            op_a, FIXED_OP_B, op_sel);
        $fwrite(fd,
            "%0d,%0d,%0d,%0d,",
            p_computed, p_accum_reg, coupling_term, computed_mod);
        $fwrite(fd,
            "%0d,%0d,",
            p_computed[11:6], computed_mod[11:6]);
        $fwrite(fd,
            "%0d,%0d,%0d,",
            attr_base, attr_mod, attr_changed);
        $fwrite(fd,
            "%0d,%0d,%0d,",
            d_computed, d_mod, transition_base);
        $fwrite(fd, "%0d\n", lfsr);

        total_cyc = total_cyc + 1;
    end
    endtask

    // ── Reset helper ──────────────────────────────────────────────────────
    task do_reset;
    begin
        @(negedge clk); rst_n = 1'b0;
        accum_clr = 1'b1; accum_en = 1'b0;
        @(negedge clk); @(negedge clk);
        @(negedge clk); rst_n = 1'b1;
        accum_clr = 1'b0;
        @(posedge clk); #1;
    end
    endtask

    // ── Main ─────────────────────────────────────────────────────────────
    initial begin : MAIN
        $display("HBS-C21: Controlled Feedback Coupling Experiment — 6,000 cycles");
        $display("  Option A: computed_mod = computed + (accum_reg >> k)");
        $display("  Regimes: k=12 (weak), k=10 (medium), k=8 (strong)");

        // Defaults
        op_a     = 13'd0;
        op_sel   = OP_ADD;
        mode_tag = MODE_STD;
        accum_en = 1'b0; accum_clr = 1'b0; host_depth = 6'd63;
        shift_k  = SHIFT_R1;
        rst_n    = 1'b0; total_cyc = 0;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C21_FEEDBACK_TRACE.csv", "w");
        $fwrite(fd,
            "cycle,regime,shift_k,local_cycle,");
        $fwrite(fd,
            "op_a,op_b,op_sel,");
        $fwrite(fd,
            "computed,accum_reg,coupling_term,computed_mod,");
        $fwrite(fd,
            "e_field_base,e_field_mod,");
        $fwrite(fd,
            "attractor_base,attractor_mod,attractor_changed,");
        $fwrite(fd,
            "delta_computed,delta_mod,transition_base,");
        $fwrite(fd, "lfsr_state\n");

        // ─────────────────────────────────────────────────────────────────
        // Regime 1 — Weak coupling (k=12, ~accum/4096)
        // ─────────────────────────────────────────────────────────────────
        $display("  Regime 1: shift_k=12 (weak, mantissa-level perturbation)...");
        do_reset;
        shift_k    = SHIFT_R1;
        op_sel     = OP_ADD;
        mode_tag   = MODE_STD;
        accum_en   = 1'b1;
        host_depth = 6'd63;

        for (c = 0; c < CYCLES_PER_REGIME; c = c+1) begin
            // Periodic accumulator clear (re-opens gate every 64 cycles)
            accum_clr = ((c % 64) == 63) ? 1'b1 : 1'b0;
            // Sweep E-field, vary f with LFSR
            op_a = {1'b0, e_sweep, lfsr[5:0]};
            @(posedge clk); #1;
            log_c21(1, c);
        end
        accum_clr = 1'b0;

        // ─────────────────────────────────────────────────────────────────
        // Regime 2 — Medium coupling (k=10, ~accum/1024)
        // ─────────────────────────────────────────────────────────────────
        $display("  Regime 2: shift_k=10 (medium, low E-field bits affected)...");
        do_reset;
        shift_k    = SHIFT_R2;
        op_sel     = OP_ADD;
        mode_tag   = MODE_STD;
        accum_en   = 1'b1;
        host_depth = 6'd63;

        for (c = 0; c < CYCLES_PER_REGIME; c = c+1) begin
            accum_clr = ((c % 64) == 63) ? 1'b1 : 1'b0;
            op_a = {1'b0, e_sweep, lfsr[5:0]};
            @(posedge clk); #1;
            log_c21(2, c);
        end
        accum_clr = 1'b0;

        // ─────────────────────────────────────────────────────────────────
        // Regime 3 — Strong coupling (k=8, ~accum/256, E-field perturbed)
        // ─────────────────────────────────────────────────────────────────
        $display("  Regime 3: shift_k=8 (strong, E-field directly perturbed)...");
        do_reset;
        shift_k    = SHIFT_R3;
        op_sel     = OP_ADD;
        mode_tag   = MODE_STD;
        accum_en   = 1'b1;
        host_depth = 6'd63;

        for (c = 0; c < CYCLES_PER_REGIME; c = c+1) begin
            accum_clr = ((c % 64) == 63) ? 1'b1 : 1'b0;
            op_a = {1'b0, e_sweep, lfsr[5:0]};
            @(posedge clk); #1;
            log_c21(3, c);
        end
        accum_clr = 1'b0;

        $fclose(fd);
        $display("  Done. Total cycles: %0d", total_cyc);
        $display("  Output: HBS_C21_FEEDBACK_TRACE.csv");
        $finish;
    end

endmodule
