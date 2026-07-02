`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c9_singularity
// Project  : HORUS v3 — HBS-C9: Singularity Validation
// File     : tb_hbs_c9_singularity.v
//
// Purpose:
//   Attempt to falsify the C8 attractor model by probing the S1 singularity
//   zone: simultaneous high exponent pressure (X > 0.75) AND high cancellation
//   pressure (Y > 0.70). C8 predicts A1 and A2 are structurally independent
//   (interaction code I). This testbench tests whether their simultaneous
//   activation produces new behavior (merged attractor, bifurcation, limit
//   cycle) not explained by A1+A2+A3+A4.
//
// Workload families:
//   S1-A  Sequential: 250-cycle A2 drift THEN 250-cycle A1 cancel per run
//   S1-B  Interleaved: even=MUL(A2), odd=SUB(A1), independent feedbacks
//   S1-C  Alternating dominance: 32-cycle A1 blocks / 32-cycle A2 blocks
//   S1-D  Coupled feedback: SUB result feeds next MUL → tests limit-cycle orbit
//
// Structure:
//   20 seeds × 4 workloads × (500 stress + 50 recovery) = 44,000 cycles
//
// S1-D design (key experiment):
//   All ops share one feedback register. MUL grows E by 1/cycle. SUB at high E
//   produces a result with E ≈ E_in − log2(64/jitter), resetting the chain.
//   Net effect: periodic E orbit — GROWS for N_MUL cycles, RESETS on each SUB.
//   If this orbit is stable and bounded (not A2-like explosion, not A3 boundary),
//   it constitutes a limit-cycle attractor absent from the C8 model.
//
// NFE codeword:  {sign[12], stored_E[11:6], fraction[5:0]}  Bias-32
// op_sel:        2'b00=ADD  2'b01=SUB  2'b10=MUL  2'b11=NOP
// accum_out:     32-bit accumulator
//
// Log format (CSV):
//   total_cycle,seed,workload,run_cycle,depth,op,E_in,E_out,
//   accum,region,UF,OVF
// ============================================================================

module tb_hbs_c9_singularity;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter NUM_SEEDS       = 20;
    parameter NUM_WORKLOADS   = 4;
    parameter STRESS_CYCLES   = 500;
    parameter RECOVERY_CYCLES =  50;
    parameter CYCLES_PER_RUN  = STRESS_CYCLES + RECOVERY_CYCLES;  // 550
    parameter TOTAL_CYCLES    = NUM_SEEDS * NUM_WORKLOADS * CYCLES_PER_RUN;  // 44,000
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
    // C4 kernel (same as C5/C6/C7/C8)
    // =========================================================================
    function [1:0] classify;
        input [5:0] e;
        begin
            if      (e <= 6'd15) classify = 2'd0;
            else if (e <= 6'd19) classify = 2'd1;
            else if (e <= 6'd43) classify = 2'd2;
            else if (e <= 6'd47) classify = 2'd1;
            else                 classify = 2'd3;
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
                c4_mode = 3'b010;
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
    // Operand constants
    // =========================================================================
    localparam [12:0] NEUTRAL      = {1'b0, 6'd32, 6'd0};
    localparam [12:0] CANCEL_BASE  = {1'b0, 6'd32, 6'd32};  // E=32, f=32

    // =========================================================================
    // Test variables
    // =========================================================================
    integer  fd;
    integer  total_cyc, seed, wl, run_cyc, depth_cnt;

    // Per-workload feedbacks (reset at start of each run)
    reg [12:0] s1a_mulfeed;   // S1-A MUL phase chain
    reg [12:0] s1b_mulfeed;   // S1-B independent MUL chain
    reg [12:0] s1c_mulfeed;   // S1-C A2-heavy block chain
    reg [12:0] s1d_feed;      // S1-D coupled feedback (shared MUL/SUB)

    // Seed-derived parameters
    reg [5:0]  seed_e_factor;  // MUL factor exponent: 33..37
    reg [5:0]  seed_cancel_f;  // Cancel operand fraction jitter: 1..8
    reg [4:0]  seed_phase;     // S1-C phase offset: 0..16

    // Per-cycle selection
    reg [1:0]  cur_class;
    reg [1:0]  cur_wl_op;   // 0=MUL, 1=SUB, 2=NOP
    reg        is_recovery;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin : MAIN
        $display("");
        $display("============================================================");
        $display("  HBS-C9: Singularity Validation");
        $display("  %0d seeds × %0d workloads × %0d = %0d total cycles",
                 NUM_SEEDS, NUM_WORKLOADS, CYCLES_PER_RUN, TOTAL_CYCLES);
        $display("============================================================");

        op_a = NEUTRAL; op_b = NEUTRAL;
        op_sel = 2'b11; mode_tag = 3'b000;
        accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0;
        depth_cnt = 0;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C9_SINGULARITY.csv", "w");
        $fwrite(fd, "total_cycle,seed,workload,run_cycle,depth,op,E_in,E_out,accum,region,UF,OVF\n");

        for (total_cyc = 0; total_cyc < TOTAL_CYCLES; total_cyc = total_cyc + 1) begin

            seed    = total_cyc / (NUM_WORKLOADS * CYCLES_PER_RUN);   // 0..19
            wl      = (total_cyc / CYCLES_PER_RUN) % NUM_WORKLOADS;   // 0..3
            run_cyc = total_cyc % CYCLES_PER_RUN;                     // 0..549

            // ── Seed parameter derivation ─────────────────────────────────
            seed_e_factor = 6'd33 + (seed % 5);        // 33..37
            seed_cancel_f = 6'd1  + (seed % 8);        // 1..8 (small jitter)
            seed_phase    = (seed % 4) * 8;            // S1-C block offset: 0,8,16,24

            // ── Run reset ────────────────────────────────────────────────
            @(negedge clk);

            is_recovery = (run_cyc >= STRESS_CYCLES);

            if (run_cyc == 0) begin
                // Reset state for new run
                accum_clr   = 1'b1;
                depth_cnt   = 0;
                s1a_mulfeed = {1'b0, 6'd32, 6'd0};
                s1b_mulfeed = {1'b0, 6'd32, 6'd0};
                s1c_mulfeed = {1'b0, 6'd32, 6'd0};
                s1d_feed    = {1'b0, 6'd32, 6'd0};
            end else if (depth_cnt >= EPOCH_DEPTH) begin
                accum_clr = 1'b1;
                depth_cnt = 0;
            end else begin
                accum_clr = 1'b0;
            end

            // ── Workload stimulus ─────────────────────────────────────────
            if (is_recovery) begin
                // Recovery phase: neutral MUL anchor
                op_a     = NEUTRAL;
                op_b     = NEUTRAL;
                op_sel   = 2'b10;
                cur_class = 2'd3;
            end else begin
                case (wl)

                    // ── S1-A: Sequential A2 then A1 ───────────────────────
                    // First half: MUL chain (A2 attractor trigger)
                    // Second half: cancellation SUB (A1 attractor trigger)
                    0: begin
                        if (run_cyc < (STRESS_CYCLES/2)) begin
                            op_a     = s1a_mulfeed;
                            op_b     = {1'b0, seed_e_factor, 6'd0};
                            op_sel   = 2'b10;  // MUL
                            cur_class = 2'd3;  // CLASS_D
                        end else begin
                            if (run_cyc == (STRESS_CYCLES/2)) begin
                                // Phase boundary: reset mulfeed for clean separation
                                s1a_mulfeed = {1'b0, 6'd32, 6'd0};
                                accum_clr   = 1'b1;
                                depth_cnt   = 0;
                            end
                            op_a     = CANCEL_BASE;
                            op_b     = {1'b0, 6'd32, 6'd0 + seed_cancel_f};
                            op_sel   = 2'b01;  // SUB
                            cur_class = 2'd1;  // CLASS_B
                        end
                    end

                    // ── S1-B: Interleaved (independent feedbacks) ──────────
                    // Even cycles: MUL(s1b_mulfeed, factor) — A2 trigger
                    // Odd  cycles: SUB(E=32, E=32+jitter)   — A1 trigger
                    // s1b_mulfeed ONLY updated on MUL cycles (structural independence)
                    1: begin
                        if (run_cyc[0] == 1'b0) begin
                            op_a     = s1b_mulfeed;
                            op_b     = {1'b0, seed_e_factor, 6'd0};
                            op_sel   = 2'b10;  // MUL
                            cur_class = 2'd3;
                        end else begin
                            op_a     = CANCEL_BASE;
                            op_b     = {1'b0, 6'd32, seed_cancel_f};
                            op_sel   = 2'b01;  // SUB
                            cur_class = 2'd1;
                        end
                    end

                    // ── S1-C: Alternating 32-cycle dominance blocks ────────
                    // A1-heavy block: all SUB at E=32 (cancellation pressure)
                    // A2-heavy block: all MUL with chain (exponent pressure)
                    // Phase offset by seed to sample different alignment points
                    2: begin
                        if (((run_cyc + seed_phase) / 32) % 2 == 0) begin
                            // A1-heavy block
                            op_a     = CANCEL_BASE;
                            op_b     = {1'b0, 6'd32, seed_cancel_f};
                            op_sel   = 2'b01;
                            cur_class = 2'd1;
                        end else begin
                            // A2-heavy block
                            op_a     = s1c_mulfeed;
                            op_b     = {1'b0, seed_e_factor, 6'd0};
                            op_sel   = 2'b10;
                            cur_class = 2'd3;
                        end
                    end

                    // ── S1-D: Coupled feedback (KEY FALSIFICATION PROBE) ───
                    // SAME feedback register used for both MUL and SUB.
                    // SUB(s1d_feed, s1d_feed + jitter) → low-E result
                    // → low-E result feeds next MUL → chain restarts from low E
                    // MUL pattern: 6 MUL per 10 cycles; SUB: 4 per 10 cycles
                    // Hypothesis: creates stable periodic E orbit (limit cycle)
                    //             NOT present in C8 attractor model
                    default: begin
                        if (((run_cyc + seed * 7) % 10) < 6) begin
                            // MUL — grow E by seed_e_factor - 32
                            op_a     = s1d_feed;
                            op_b     = {1'b0, seed_e_factor, 6'd0};
                            op_sel   = 2'b10;
                            cur_class = 2'd3;
                        end else begin
                            // SUB — near-cancel: op_b has same E, jitter on fraction
                            op_a     = s1d_feed;
                            op_b     = {s1d_feed[12], s1d_feed[11:6], s1d_feed[5:0] + seed_cancel_f};
                            op_sel   = 2'b01;
                            cur_class = 2'd1;
                        end
                    end

                endcase
            end

            // ── C4 kernel ─────────────────────────────────────────────────
            mode_tag = c4_mode(cur_class, op_a[11:6], depth_cnt[7:0]);

            // ── accum_en policy ───────────────────────────────────────────
            if (is_recovery           ||
                depth_cnt >= EPOCH_DEPTH ||
                classify(op_a[11:6]) == 2'd0 ||
                classify(op_a[11:6]) == 2'd3)
                accum_en = 1'b0;
            else
                accum_en = 1'b1;

            @(posedge clk); #1;

            // ── Post-clock feedback updates ───────────────────────────────
            if (!is_recovery) begin
                case (wl)
                    0: if (run_cyc < (STRESS_CYCLES/2) && !exp_ovf_flag)
                            s1a_mulfeed = result;
                       else if (exp_ovf_flag)
                            s1a_mulfeed = {1'b0, 6'd32, 6'd0};
                    1: if (!run_cyc[0] && !exp_ovf_flag)
                            s1b_mulfeed = result;          // only on MUL cycles
                       else if (exp_ovf_flag)
                            s1b_mulfeed = {1'b0, 6'd32, 6'd0};
                    2: if (((run_cyc + seed_phase) / 32) % 2 == 1 && !exp_ovf_flag)
                            s1c_mulfeed = result;
                       else if (exp_ovf_flag)
                            s1c_mulfeed = {1'b0, 6'd32, 6'd0};
                    3: begin
                            // S1-D: ALWAYS update feedback from result (coupled)
                            if (exp_ovf_flag)
                                s1d_feed = {1'b0, 6'd32, 6'd0};
                            else
                                s1d_feed = result;
                        end
                endcase
            end

            // ── CSV log ───────────────────────────────────────────────────
            // workload name
            case (wl)
                0: $fwrite(fd, "%0d,%0d,S1A,", total_cyc, seed);
                1: $fwrite(fd, "%0d,%0d,S1B,", total_cyc, seed);
                2: $fwrite(fd, "%0d,%0d,S1C,", total_cyc, seed);
                default: $fwrite(fd, "%0d,%0d,S1D,", total_cyc, seed);
            endcase

            $fwrite(fd, "%0d,%0d,", run_cyc, depth_cnt);

            // op name
            case (op_sel)
                2'b00: $fwrite(fd, "ADD,");
                2'b01: $fwrite(fd, "SUB,");
                2'b10: $fwrite(fd, "MUL,");
                2'b11: $fwrite(fd, "NOP,");
            endcase

            $fwrite(fd, "%0d,%0d,", op_a[11:6], result[11:6]);
            $fwrite(fd, "%0d,", accum_out);

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
        $display("  %0d cycles logged to HBS_C9_SINGULARITY.csv", TOTAL_CYCLES);
        $display("============================================================");
        $finish;
    end

endmodule
