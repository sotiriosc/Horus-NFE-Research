`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c7_failure_domain
// Project  : HORUS v3 — HBS-C7: Failure-Domain Isolation Suite
// File     : tb_hbs_c7_failure_domain.v
//
// Purpose:
//   Precisely map the hardware failure domain under four minimal adversarial
//   regimes. Uses real horus_system RTL. NO RTL changes, NO new modes.
//   Stimulus-engineering only.
//
// Regimes:
//   R1  Cancellation Avalanche  — alternating SUB pairs with ±jitter, depth sweep
//   R2  Exponent Drift Chain    — repeated MUL × 2.0 with feedback; detect E explosion
//   R3  Boundary Hammering      — E=15↔16 and E=47↔48 oscillation
//   R4  Mixed-Regime Injection  — 40% STABLE / 30% COLLAPSE-edge / 30% SAT-edge
//
// Each regime: STRESS_CYCLES cycles of adversarial stimulus, then
//              RECOVERY_CYCLES cycles of neutral input (E=32 anchor, MUL).
//
// Structure (8 phases):
//   [0] R1_STRESS    [1] R1_RECOVERY
//   [2] R2_STRESS    [3] R2_RECOVERY
//   [4] R3_STRESS    [5] R3_RECOVERY
//   [6] R4_STRESS    [7] R4_RECOVERY
//
// horus_system interface (exact port names):
//   op_sel: 2'b00=ADD  2'b01=SUB  2'b10=MUL  2'b11=NOP
//   accum_out: 32-bit
//   accum_clr (not clear_accum)
//
// Log format (CSV):
//   cycle,phase,regime,regime_cycle,depth,E_in,E_out,op,mode,
//   result_hex,accum,region,UF,OVF
// ============================================================================

module tb_hbs_c7_failure_domain;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter STRESS_CYCLES   = 200;
    parameter RECOVERY_CYCLES =  75;
    parameter PHASE_TOTAL     = STRESS_CYCLES + RECOVERY_CYCLES;  // 275
    parameter TOTAL_CYCLES    = PHASE_TOTAL * 4;                  // 1100

    // Instability thresholds
    parameter EPOCH_DEPTH     = 16;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg         clk, rst_n;
    reg  [12:0] op_a, op_b;
    reg  [1:0]  op_sel;
    reg  [2:0]  mode_tag;
    reg         accum_en;
    reg         accum_clr;
    reg  [5:0]  host_tile_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag, underflow_flag, exp_ovf_flag;
    wire [15:0] op_count;
    wire        accum_full;

    // =========================================================================
    // DUT
    // =========================================================================
    horus_system dut (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a), .op_b(op_b),
        .op_sel(op_sel), .mode_tag(mode_tag),
        .accum_en(accum_en), .accum_clr(accum_clr),
        .host_tile_depth(host_tile_depth),
        .result(result), .accum_out(accum_out),
        .rollover_flag(rollover_flag),
        .underflow_flag(underflow_flag),
        .exp_ovf_flag(exp_ovf_flag),
        .op_count(op_count), .accum_full(accum_full)
    );

    // =========================================================================
    // C4 kernel: priority-encoded predicate evaluator (§1.3)
    // =========================================================================
    function [1:0] classify;
        input [5:0] e;
        begin
            if      (e <= 6'd15) classify = 2'd0;   // COLLAPSE
            else if (e <= 6'd19) classify = 2'd1;   // TRANSITION
            else if (e <= 6'd43) classify = 2'd2;   // STABLE
            else if (e <= 6'd47) classify = 2'd1;   // TRANSITION
            else                 classify = 2'd3;   // SATURATION
        end
    endfunction

    function [2:0] c4_mode;
        input [1:0] cls;
        input [5:0] e_in;
        input [7:0] d;
        reg [1:0] rgn;
        begin
            rgn = classify(e_in);
            if (d > 8'd16)
                c4_mode = 3'b010;   // terminal annihilation
            else case (rgn)
                2'd2: c4_mode = 3'b000;
                2'd1: c4_mode = (cls==2'd1||cls==2'd3) ? 3'b010 : 3'b000;
                2'd0: c4_mode = (cls==2'd0) ? 3'b011 : 3'b010;
                2'd3: c4_mode = 3'b011;
                default: c4_mode = 3'b000;
            endcase
        end
    endfunction

    // =========================================================================
    // NFE codeword constants  {sign, E[5:0], f[5:0]}
    // =========================================================================
    // R1: cancellation — equal-exponent SUB pairs
    localparam [12:0] R1_BASE   = {1'b0, 6'd32, 6'd32};  // E=32, f=32

    // R2: exponent drift — MUL(feedback, 2.0); 2.0 → E=33, f=0
    localparam [12:0] R2_INIT   = {1'b0, 6'd32, 6'd0};   // E=32 start
    localparam [12:0] R2_FACTOR = {1'b0, 6'd33, 6'd0};   // ×2 per MUL (E grows +1/cycle)

    // R3: boundary hammering — four boundary-adjacent values
    localparam [12:0] R3_COLL_A = {1'b0, 6'd15, 6'd32};  // E=15 with Rollover potential
    localparam [12:0] R3_COLL_B = {1'b0, 6'd15, 6'd0};   // E=15 below Rollover
    localparam [12:0] R3_SAT_A  = {1'b0, 6'd47, 6'd63};  // E=47 max (Rollover → 48)
    localparam [12:0] R3_SAT_B  = {1'b0, 6'd47, 6'd32};  // E=47 midrange

    // R4: mixed injection
    localparam [12:0] R4_STABLE = {1'b0, 6'd32, 6'd32};  // STABLE anchor
    localparam [12:0] R4_COLL   = {1'b0, 6'd15, 6'd20};  // COLLAPSE edge
    localparam [12:0] R4_SAT    = {1'b0, 6'd48, 6'd10};  // SATURATION edge

    // Recovery / neutral
    localparam [12:0] NEUTRAL   = {1'b0, 6'd32, 6'd0};   // E=32 anchor MUL

    // =========================================================================
    // Test variables
    // =========================================================================
    integer  fd;
    integer  cyc, phase, regime_cyc;
    integer  depth_cnt;
    reg [12:0] r2_feedback;
    reg [1:0]  cls_r;
    reg [5:0]  e_in_r;
    reg [6:0]  jitter_f;   // W1/R1 fraction jitter

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // =========================================================================
    // Main sweep
    // =========================================================================
    initial begin : MAIN
        $display("");
        $display("============================================================");
        $display("  HBS-C7: Failure-Domain Isolation Suite");
        $display("  4 regimes × %0d stress + %0d recovery = %0d total",
                 STRESS_CYCLES, RECOVERY_CYCLES, TOTAL_CYCLES);
        $display("============================================================");

        // Defaults
        op_a = NEUTRAL; op_b = NEUTRAL;
        op_sel = 2'b11; mode_tag = 3'b000;
        accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0;
        depth_cnt = 0;
        r2_feedback = R2_INIT;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C7_FAILURE_DOMAIN.csv", "w");
        $fwrite(fd, "cycle,phase,regime,regime_cycle,depth,E_in,E_out,op,mode,result_hex,accum,region,UF,OVF\n");

        for (cyc = 0; cyc < TOTAL_CYCLES; cyc = cyc + 1) begin

            phase      = cyc / PHASE_TOTAL;      // 0=R1, 1=R2, 2=R3, 3=R4
            regime_cyc = cyc % PHASE_TOTAL;       // 0..274

            @(negedge clk);

            // ── Epoch management ─────────────────────────────────────────
            if (depth_cnt > EPOCH_DEPTH || regime_cyc == 0) begin
                accum_clr = 1'b1;
                depth_cnt = 0;
            end else begin
                accum_clr = 1'b0;
            end

            // ── Regime / phase dispatch ───────────────────────────────────
            if (regime_cyc >= STRESS_CYCLES) begin
                // ── RECOVERY: neutral input for all regimes ──────────────
                cls_r  = 2'd0;
                op_a   = NEUTRAL;
                op_b   = NEUTRAL;
                op_sel = 2'b10;   // MUL neutral × neutral → stays E=32
            end else begin
                // ── STRESS phase ─────────────────────────────────────────
                case (phase)

                    // ── R1: Cancellation Avalanche ────────────────────────
                    // SUB(base, base+jitter) — jitter increases with depth
                    // to model increasing cancellation imperfection at depth.
                    0: begin
                        cls_r    = 2'd1;  // CLASS_B
                        jitter_f = 6'(29 + (regime_cyc % 7));
                        op_a     = R1_BASE;
                        op_b     = {1'b0, 6'd32, jitter_f[5:0]};
                        op_sel   = 2'b01;  // SUB
                    end

                    // ── R2: Exponent Drift Chain ──────────────────────────
                    // MUL(feedback, R2_FACTOR=2.0) → E grows +1 per cycle.
                    // On OVF: reset feedback and accum to restart the chain.
                    1: begin
                        cls_r  = 2'd3;  // CLASS_D (deep chain)
                        op_a   = r2_feedback;
                        op_b   = R2_FACTOR;
                        op_sel = 2'b10;  // MUL
                    end

                    // ── R3: Boundary Hammering ─────────────────────────────
                    // First half:  E=15 boundary (COLLAPSE side)
                    //   Even: ADD(R3_COLL_A, R3_COLL_A) → Rollover → E=16
                    //   Odd:  ADD(R3_COLL_B, R3_COLL_A) → no Rollover → E=15
                    // Second half: E=47 boundary (SATURATION side)
                    //   Even: ADD(R3_SAT_A,  R3_SAT_A)  → Rollover → E=48
                    //   Odd:  ADD(R3_SAT_B,  R3_SAT_B)  → E=47
                    2: begin
                        cls_r  = 2'd2;  // CLASS_C (scaling/normalization)
                        op_sel = 2'b00;  // ADD
                        if (regime_cyc < 100) begin
                            // low boundary
                            if (regime_cyc[0]) begin
                                op_a = R3_COLL_A; op_b = R3_COLL_A;
                            end else begin
                                op_a = R3_COLL_B; op_b = R3_COLL_A;
                            end
                        end else begin
                            // high boundary
                            if (regime_cyc[0]) begin
                                op_a = R3_SAT_A; op_b = R3_SAT_A;
                            end else begin
                                op_a = R3_SAT_B; op_b = R3_SAT_B;
                            end
                        end
                    end

                    // ── R4: Mixed-Regime Injection ────────────────────────
                    // Deterministic 10-cycle repeating pattern:
                    //   0–3: STABLE (40%)  4–6: COLLAPSE-edge (30%)  7–9: SAT-edge (30%)
                    default: begin
                        op_sel = 2'b00;  // ADD for all
                        case (regime_cyc % 10)
                            0,1,2,3: begin
                                cls_r = 2'd0; // CLASS_A
                                op_a = R4_STABLE; op_b = R4_STABLE;
                            end
                            4,5,6: begin
                                cls_r = 2'd1; // CLASS_B
                                op_a = R4_COLL; op_b = R4_COLL;
                            end
                            default: begin
                                cls_r = 2'd0; // CLASS_A
                                op_a = R4_SAT; op_b = R4_SAT;
                            end
                        endcase
                    end

                endcase
            end

            // ── C4 kernel: mode_tag ───────────────────────────────────────
            e_in_r   = op_a[11:6];
            mode_tag = c4_mode(cls_r, e_in_r, depth_cnt[7:0]);

            // ── accum_en ──────────────────────────────────────────────────
            if (cls_r == 2'd2          ||   // CLASS_C never accumulates
                depth_cnt > EPOCH_DEPTH ||
                classify(e_in_r) == 2'd0 ||
                classify(e_in_r) == 2'd3)
                accum_en = 1'b0;
            else
                accum_en = 1'b1;

            @(posedge clk); #1;

            // ── R2: update feedback; reset on OVF ────────────────────────
            if (phase == 1 && regime_cyc < STRESS_CYCLES) begin
                if (exp_ovf_flag) begin
                    r2_feedback = R2_INIT;   // deterministic restart
                    accum_clr   = 1'b1;      // also clear accum
                end else begin
                    r2_feedback = result;    // feed forward
                end
            end else if (regime_cyc == 0) begin
                r2_feedback = R2_INIT;       // reset at regime boundary
            end

            // ── CSV logging ───────────────────────────────────────────────
            // phase string
            case (phase)
                0: $fwrite(fd, "%0d,R1_%s,R1,", cyc,
                    (regime_cyc >= STRESS_CYCLES) ? "RECOVERY" : "STRESS");
                1: $fwrite(fd, "%0d,R2_%s,R2,", cyc,
                    (regime_cyc >= STRESS_CYCLES) ? "RECOVERY" : "STRESS");
                2: $fwrite(fd, "%0d,R3_%s,R3,", cyc,
                    (regime_cyc >= STRESS_CYCLES) ? "RECOVERY" : "STRESS");
                default: $fwrite(fd, "%0d,R4_%s,R4,", cyc,
                    (regime_cyc >= STRESS_CYCLES) ? "RECOVERY" : "STRESS");
            endcase

            $fwrite(fd, "%0d,%0d,", regime_cyc, depth_cnt);
            $fwrite(fd, "%0d,%0d,", e_in_r, result[11:6]);

            case (op_sel)
                2'b00: $fwrite(fd, "ADD,");
                2'b01: $fwrite(fd, "SUB,");
                2'b10: $fwrite(fd, "MUL,");
                2'b11: $fwrite(fd, "NOP,");
            endcase

            $fwrite(fd, "%0d,%0h,%0d,", mode_tag, result, accum_out);

            case (classify(result[11:6]))
                2'd0: $fwrite(fd, "COLLAPSE,");
                2'd1: $fwrite(fd, "TRANSITION,");
                2'd2: $fwrite(fd, "STABLE,");
                2'd3: $fwrite(fd, "SATURATE,");
            endcase

            $fwrite(fd, "%0d,%0d\n", underflow_flag, exp_ovf_flag);

            depth_cnt = depth_cnt + 1;
        end

        $fclose(fd);
        $display("  %0d cycles logged to HBS_C7_FAILURE_DOMAIN.csv", TOTAL_CYCLES);
        $display("============================================================");
        $display("");
        $finish;
    end

endmodule
