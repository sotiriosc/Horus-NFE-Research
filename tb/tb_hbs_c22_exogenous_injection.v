`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c22_exogenous_injection
// Project  : HORUS v3 — HBS-C22: Exogenous Control Injection Test
//            (Strict Version — Option B, XOR coupling)
//
// Purpose  : Test whether an INDEPENDENT control stream (mode_tag via
//            external LFSR) can causally influence arithmetic outputs and
//            induce attractor imprinting.
//
// HARD CONSTRAINTS ENFORCED:
//   1. ALU RTL untouched — computed = f(op_a, op_b, op_sel) unchanged
//   2. accum_reg forbidden as injection source (no C21-style echo)
//   3. DUT mode_tag is FIXED at STANDARD (000) — accumulation isolated
//   4. mode_tag for observer coupling is EXOGENOUS (independent 15-bit LFSR)
//      — zero statistical dependency on any DUT internal signal
//
// Injection formula (Option B — XOR coupling):
//
//   computed_mod = computed XOR mode_mask(active_mode)
//
//   NFE-adapted 13-bit masks (adapted from spec's 32-bit scheme):
//     active_mode=2'b00: mask=13'h0000  identity (no change)
//     active_mode=2'b01: mask=13'h003F  flip mantissa (f-field bits 5:0)
//     active_mode=2'b10: mask=13'h0FC0  flip E-field (bits 11:6)
//     active_mode=2'b11: mask=13'h0FFF  flip both E-field and mantissa
//
//   Note: sign bit (bit 12) is never flipped — preserves positive quadrant.
//
// Mode LFSRs:
//   Data LFSR (16-bit, resets on rst_n):
//     seed 16'hACE1, poly x^16+x^14+x^13+x^11+1
//     drives op_a f-field variation (same sequence per regime)
//
//   Mode LFSR (15-bit, FREE-RUNNING — no rst_n dependency):
//     seed 15'h7FFF, poly x^15+x^3+1 (taps: bit0 XOR bit2)
//     drives active_mode — EXOGENOUS, ZERO DUT STATE DEPENDENCY
//
// Four regimes (1,500 cycles each = 6,000 total):
//
//   R1 — Baseline (active_mode locked 2'b00, mask=0)
//          computed_mod = computed throughout
//          Establishes reference attractor distribution
//
//   R2 — Low-frequency switching (mode updates every 16 cycles)
//          active_mode sampled from mode_lfsr every epoch boundary
//          Tests epoch-level attractor modulation
//
//   R3 — High-frequency switching (mode updates every cycle)
//          active_mode = mode_lfsr[1:0] each cycle
//          Maximum-bandwidth exogenous injection
//
//   R4 — Structured pattern (01→10→11→00, cycling every cycle)
//          Deterministic, uniform, fully controllable
//          Optimal for exact MI computation
//
// Input pattern (DUT, identical across all regimes):
//   op_a   : E-field cycles 0→63, f-field from data LFSR
//   op_b   : fixed {1'b0, 6'd0, 6'd16}
//   op_sel : ADD (2'b00)
//   mode_tag (DUT): STANDARD (3'b000) — always, all regimes
//   accum_en=1, depth=63, clr every 64 cycles
//
// Attractor classification (on computed and computed_mod separately):
//   A1: E==0            (cancellation residual)
//   A2: 50 ≤ E < 63     (geometric explosion approach)
//   A3: E==63           (Thoth rollover boundary)
//   A4: 1 ≤ E < 50      (entropic mid-range)
//
// CSV columns (per cycle):
//   cycle, regime, local_cycle, active_mode, mask_val,
//   computed, computed_mod,
//   e_field_base, e_field_mod,
//   attractor_base, attractor_mod, attractor_changed,
//   delta_computed, delta_mod, transition_base,
//   mode_lfsr_state
// ============================================================================

module tb_hbs_c22_exogenous_injection;

    // ── Constants ─────────────────────────────────────────────────────────
    localparam OP_ADD       = 2'b00;
    localparam MODE_STANDARD = 3'b000;
    localparam [12:0] FIXED_OP_B = {1'b0, 6'd0, 6'd16};

    localparam CYCLES_PER_REGIME = 1500;
    localparam R2_EPOCH          = 16;   // low-frequency epoch (cycles)

    // NFE-adapted 13-bit XOR masks
    localparam [12:0] MASK_00 = 13'h0000;  // identity
    localparam [12:0] MASK_01 = 13'h003F;  // flip mantissa (bits 5:0)
    localparam [12:0] MASK_10 = 13'h0FC0;  // flip E-field (bits 11:6)
    localparam [12:0] MASK_11 = 13'h0FFF;  // flip E+mantissa (bits 11:0)

    // ── Clock / Reset ─────────────────────────────────────────────────────
    reg clk, rst_n;
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ── Data LFSR (16-bit, resets on rst_n): op_a f-field variation ───────
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    end

    // ── Mode LFSR (15-bit, FREE-RUNNING — no rst_n dependency) ───────────
    // Spec: lfsr_state <= {lfsr_state[14:0], lfsr_state[0] ^ lfsr_state[2]}
    // This generates an exogenous mode_tag stream with NO DUT state dependency.
    reg [14:0] mode_lfsr;
    initial mode_lfsr = 15'h7FFF;   // Non-zero seed (initial only, no reset)
    always @(posedge clk) begin
        mode_lfsr <= {mode_lfsr[13:0], mode_lfsr[0] ^ mode_lfsr[2]};
    end

    // ── E-field sweep counter ─────────────────────────────────────────────
    reg [5:0] e_sweep;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) e_sweep <= 6'd0;
        else        e_sweep <= e_sweep + 6'd1;
    end

    // ── DUT ───────────────────────────────────────────────────────────────
    reg  [12:0] op_a;
    reg  [1:0]  op_sel;
    reg         accum_en, accum_clr;
    reg  [5:0]  host_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover, uf, ovf, accum_full;
    wire [15:0] op_count;

    horus_system dut (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a), .op_b(FIXED_OP_B), .op_sel(op_sel),
        .mode_tag(MODE_STANDARD),    // FIXED — accumulation isolated
        .accum_en(accum_en), .accum_clr(accum_clr),
        .host_tile_depth(host_depth),
        .result(result), .accum_out(accum_out),
        .rollover_flag(rollover), .underflow_flag(uf),
        .exp_ovf_flag(ovf),
        .op_count(op_count), .accum_full(accum_full)
    );

    // ── Internal probes ───────────────────────────────────────────────────
    wire [12:0] p_computed = dut.u_nfe.computed;

    // ── Observer-layer XOR coupling ───────────────────────────────────────
    // active_mode is the EXOGENOUS 2-bit control (from mode_lfsr or pattern)
    reg  [1:0]  active_mode;   // updated per regime logic
    reg  [12:0] mode_mask;
    always @(*) begin
        case (active_mode)
            2'b00: mode_mask = MASK_00;
            2'b01: mode_mask = MASK_01;
            2'b10: mode_mask = MASK_10;
            2'b11: mode_mask = MASK_11;
        endcase
    end
    wire [12:0] computed_mod = p_computed ^ mode_mask;

    // ── Attractor classification ───────────────────────────────────────────
    function automatic [2:0] classify;
        input [12:0] nfe;
        reg [5:0] ef;
        begin
            ef = nfe[11:6];
            if      (ef == 6'd0)    classify = 3'd1;  // A1
            else if (ef == 6'd63)   classify = 3'd3;  // A3
            else if (ef >= 6'd50)   classify = 3'd2;  // A2
            else                    classify = 3'd4;  // A4
        end
    endfunction

    // ── Previous-cycle delta registers ────────────────────────────────────
    reg [12:0] prev_computed, prev_computed_mod;
    reg [2:0]  prev_attr_base;

    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_computed     <= 13'd0;
            prev_computed_mod <= 13'd0;
            prev_attr_base    <= 3'd4;
        end else begin
            prev_computed     <= p_computed;
            prev_computed_mod <= computed_mod;
            prev_attr_base    <= classify(p_computed);
        end
    end

    // ── Logging ───────────────────────────────────────────────────────────
    integer  fd;
    integer  total_cyc;
    integer  c;

    task log_c22;
        input integer regime_id;
        input integer local_cyc;
    begin : LOG_BLK
        reg [2:0] ab, am;
        reg       changed, trans;
        reg [12:0] dc, dm;

        ab      = classify(p_computed);
        am      = classify(computed_mod);
        changed = (ab != am)           ? 1'b1 : 1'b0;
        trans   = (ab != prev_attr_base) ? 1'b1 : 1'b0;

        dc = (p_computed   >= prev_computed)   ?
             (p_computed   - prev_computed)    : (prev_computed   - p_computed);
        dm = (computed_mod >= prev_computed_mod) ?
             (computed_mod - prev_computed_mod) : (prev_computed_mod - computed_mod);

        $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,", total_cyc, regime_id, local_cyc, active_mode, mode_mask);
        $fwrite(fd, "%0d,%0d,", p_computed, computed_mod);
        $fwrite(fd, "%0d,%0d,", p_computed[11:6], computed_mod[11:6]);
        $fwrite(fd, "%0d,%0d,%0d,", ab, am, changed);
        $fwrite(fd, "%0d,%0d,%0d,", dc, dm, trans);
        $fwrite(fd, "%0d\n", mode_lfsr);

        total_cyc = total_cyc + 1;
    end
    endtask

    // ── Reset helper (DUT only — mode_lfsr continues free-running) ────────
    task dut_reset;
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
        $display("HBS-C22: Exogenous Control Injection Test (Strict Version)");
        $display("  Option B: computed_mod = computed XOR mask(mode_lfsr)");
        $display("  Regimes: R1=baseline, R2=low-freq, R3=high-freq, R4=structured");

        op_a       = 13'd0;
        op_sel     = OP_ADD;
        accum_en   = 1'b0;
        accum_clr  = 1'b0;
        host_depth = 6'd63;
        active_mode = 2'b00;
        rst_n      = 1'b0;
        total_cyc  = 0;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C22_INJECTION_TRACE.csv", "w");
        $fwrite(fd, "cycle,regime,local_cycle,active_mode,mask_val,");
        $fwrite(fd, "computed,computed_mod,");
        $fwrite(fd, "e_field_base,e_field_mod,");
        $fwrite(fd, "attractor_base,attractor_mod,attractor_changed,");
        $fwrite(fd, "delta_computed,delta_mod,transition_base,");
        $fwrite(fd, "mode_lfsr_state\n");

        // ─────────────────────────────────────────────────────────────────
        // REGIME 1 — Baseline (active_mode = 00, mask = 0)
        // computed_mod = computed throughout.
        // Establishes reference attractor distribution with this input pattern.
        // ─────────────────────────────────────────────────────────────────
        $display("  Regime 1: Baseline (mask=0, computed_mod=computed)...");
        dut_reset;
        op_sel = OP_ADD; accum_en = 1'b1; host_depth = 6'd63;
        active_mode = 2'b00;  // Locked — no XOR

        for (c = 0; c < CYCLES_PER_REGIME; c = c+1) begin
            accum_clr = ((c % 64) == 63) ? 1'b1 : 1'b0;
            op_a = {1'b0, e_sweep, lfsr[5:0]};
            @(posedge clk); #1;
            log_c22(1, c);
        end
        accum_clr = 1'b0;

        // ─────────────────────────────────────────────────────────────────
        // REGIME 2 — Low-frequency mode switching (every 16 cycles)
        // mode_lfsr drives active_mode only at epoch boundaries.
        // ─────────────────────────────────────────────────────────────────
        $display("  Regime 2: Low-frequency switching (epoch=16 cycles)...");
        dut_reset;
        op_sel = OP_ADD; accum_en = 1'b1; host_depth = 6'd63;
        active_mode = mode_lfsr[1:0];   // initial value

        for (c = 0; c < CYCLES_PER_REGIME; c = c+1) begin
            accum_clr = ((c % 64) == 63) ? 1'b1 : 1'b0;
            // Sample new mode from mode_lfsr at 16-cycle boundaries
            if ((c % R2_EPOCH) == 0) active_mode = mode_lfsr[1:0];
            op_a = {1'b0, e_sweep, lfsr[5:0]};
            @(posedge clk); #1;
            log_c22(2, c);
        end
        accum_clr = 1'b0;

        // ─────────────────────────────────────────────────────────────────
        // REGIME 3 — High-frequency mode switching (every cycle)
        // active_mode = mode_lfsr[1:0] on every clock edge.
        // Maximum bandwidth exogenous injection.
        // ─────────────────────────────────────────────────────────────────
        $display("  Regime 3: High-frequency switching (every cycle)...");
        dut_reset;
        op_sel = OP_ADD; accum_en = 1'b1; host_depth = 6'd63;

        for (c = 0; c < CYCLES_PER_REGIME; c = c+1) begin
            accum_clr  = ((c % 64) == 63) ? 1'b1 : 1'b0;
            active_mode = mode_lfsr[1:0];   // updated every cycle
            op_a = {1'b0, e_sweep, lfsr[5:0]};
            @(posedge clk); #1;
            log_c22(3, c);
        end
        accum_clr = 1'b0;

        // ─────────────────────────────────────────────────────────────────
        // REGIME 4 — Structured deterministic pattern (01→10→11→00 cycle)
        // Uniform, deterministic, 4-phase cycle.
        // Optimal for exact MI computation (equal occupancy per mode_tag).
        // ─────────────────────────────────────────────────────────────────
        $display("  Regime 4: Structured pattern (01→10→11→00 per cycle)...");
        dut_reset;
        op_sel = OP_ADD; accum_en = 1'b1; host_depth = 6'd63;

        for (c = 0; c < CYCLES_PER_REGIME; c = c+1) begin
            accum_clr = ((c % 64) == 63) ? 1'b1 : 1'b0;
            // Structured 4-phase cycle: 01, 10, 11, 00, 01, ...
            case (c % 4)
                0: active_mode = 2'b01;   // flip mantissa
                1: active_mode = 2'b10;   // flip E-field
                2: active_mode = 2'b11;   // flip both
                3: active_mode = 2'b00;   // identity
            endcase
            // Use FULL-LFSR op_a (NOT e_sweep) to prevent period-4 aliasing
            // between mode cycle and input E-field cycle.
            op_a = {1'b0, lfsr[11:6], lfsr[5:0]};
            @(posedge clk); #1;
            log_c22(4, c);
        end
        accum_clr = 1'b0;

        $fclose(fd);
        $display("  Done. Total cycles: %0d", total_cyc);
        $display("  Output: HBS_C22_INJECTION_TRACE.csv");
        $finish;
    end

endmodule
