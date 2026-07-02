`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c15_oob_falsification
// Project  : HORUS v3 — HBS-C15: OOB Controllability Falsification
//
// Purpose: Adversarial injector layer between stimulus generator and DUT.
// Falsification target: FULLY_CONTROLLABLE (C13) and COMPUTATIONALLY_EXPRESSIVE (C14)
//
// 5 regimes × 1,500 cycles = 7,500 cycles
//
// R1 — Latency Skew         : stale mode_tag (1–3 cycle delay)
// R2 — Phase Desync         : op_a delayed 2 cycles, mode delayed 1 cycle
// R3 — Burst Collapse       : MUL/SUB alternating every cycle (sub-epoch)
// R4 — Boundary Thrash      : E cycles through 15/16/47/48 every 4 cycles
// R5 — Control Noise Attack : mode_tag bit-flips at 10%/20%/30%
//
// CSV schema (per-cycle):
//   cycle,regime,local,intended_mode,actual_mode,op,E_in,E_out,
//   accum,region,UF,OVF,noise_level
// ============================================================================

module tb_hbs_c15_oob_falsification;

    localparam R_CYCS = 1500;
    localparam TOTAL  = 7500;
    localparam EPOCH  = 16;

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
    // Helpers
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
            if (d > 8'd16) c4_mode = 3'b010;
            else case (rgn)
                2'd2: c4_mode = 3'b000;
                2'd1: c4_mode = (cls==2'd1||cls==2'd3) ? 3'b010 : 3'b000;
                2'd0: c4_mode = (cls==2'd0) ? 3'b011 : 3'b010;
                2'd3: c4_mode = 3'b011;
                default: c4_mode = 3'b000;
            endcase
        end
    endfunction

    // Canonical presets
    localparam [12:0] A1_A = {1'b0, 6'd32, 6'd32};
    localparam [12:0] A1_B = {1'b0, 6'd32, 6'd35};
    localparam [12:0] A2_B = {1'b0, 6'd33, 6'd0};

    // =========================================================================
    // LFSR for pseudo-random injection
    // =========================================================================
    reg [15:0] lfsr;
    wire lfsr_fb = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hC15F;
        else        lfsr <= {lfsr[14:0], lfsr_fb};
    end

    // =========================================================================
    // Adversarial injector state
    // =========================================================================
    // R1: mode_tag delay pipeline (index 0 = newest)
    reg [2:0] mode_pipe [0:3];
    integer   r1_delay;

    // R2: operand delay pipeline
    reg [12:0] op_a_d1, op_a_d2;
    reg [2:0]  mode_d1;

    // R5: noise levels
    integer    noise_level;
    reg [4:0]  noise_t5;

    // =========================================================================
    // Simulation state
    // =========================================================================
    integer fd;
    integer total_cyc, regime_id, local_cyc, depth_cnt;
    reg [2:0] intended_mode, actual_mode;
    reg [1:0] cur_class;
    reg [12:0] mulfeed;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // Main
    // =========================================================================
    initial begin : MAIN
        integer i;
        $display("HBS-C15: OOB Controllability Falsification — 7,500 cycles");

        op_a = A1_A; op_b = A1_B; op_sel = 2'b01;
        mode_tag = 3'b000; accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0; depth_cnt = 0;
        mulfeed = {1'b0, 6'd32, 6'd0};

        for (i = 0; i < 4; i = i+1) mode_pipe[i] = 3'b000;
        op_a_d1 = A1_A; op_a_d2 = A1_A;
        mode_d1  = 3'b000;
        noise_level = 0;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C15_OOB.csv", "w");
        $fwrite(fd, "cycle,regime,local,intended_mode,actual_mode,op,E_in,E_out,accum,region,UF,OVF,noise_level\n");

        for (total_cyc = 0; total_cyc < TOTAL; total_cyc = total_cyc + 1) begin
            @(negedge clk);

            regime_id = total_cyc / R_CYCS;
            local_cyc = total_cyc % R_CYCS;

            // ── Epoch / accumulator management ────────────────────────────
            accum_clr = ((local_cyc % EPOCH) == 0) ? 1'b1 : 1'b0;
            if (accum_clr) depth_cnt = 0;

            // ── Clean baseline stimulus (A1: SUB E=32) ────────────────────
            op_a     = A1_A;
            op_b     = A1_B;
            op_sel   = 2'b01;  // SUB
            cur_class = 2'd1;
            noise_level = 0;

            // Intended mode from clean A1 baseline
            intended_mode = c4_mode(cur_class, A1_A[11:6], depth_cnt[7:0]);
            actual_mode   = intended_mode;

            // ================================================================
            // R1 — Latency Skew Injection
            // ================================================================
            if (regime_id == 0) begin
                // Shift mode pipeline: pipe[0]=newest, pipe[3]=oldest
                mode_pipe[3] = mode_pipe[2];
                mode_pipe[2] = mode_pipe[1];
                mode_pipe[1] = mode_pipe[0];
                mode_pipe[0] = intended_mode;

                // Select delay 1-3 based on LFSR[1:0]
                case (lfsr[1:0])
                    2'b00, 2'b01: r1_delay = 1;
                    2'b10:        r1_delay = 2;
                    default:      r1_delay = 3;
                endcase
                actual_mode = mode_pipe[r1_delay];
                // Operands unchanged: R1 only corrupts timing of mode_tag
            end

            // ================================================================
            // R2 — Phase Desynchronization
            // ================================================================
            else if (regime_id == 1) begin
                // Update operand delay pipeline
                op_a_d2 = op_a_d1;
                op_a_d1 = A1_A;  // baseline A1 op_a

                // Update mode delay pipeline
                mode_d1 = intended_mode;

                // DUT receives: 2-cycle-old operand, 1-cycle-old mode
                op_a        = op_a_d2;           // stale operand (E may differ)
                actual_mode = mode_d1;            // stale mode from last cycle
                // op_sel and op_b are current; depth_cnt is current
            end

            // ================================================================
            // R3 — Burst Collapse Injection (MUL/SUB sub-epoch oscillation)
            // ================================================================
            else if (regime_id == 2) begin
                if (local_cyc[0] == 1'b0) begin
                    // Even cycles: MUL chain (A2 attempt)
                    op_a      = mulfeed;
                    op_b      = A2_B;
                    op_sel    = 2'b10;
                    cur_class = 2'd3;
                end else begin
                    // Odd cycles: SUB cancel (A1 baseline)
                    op_a      = A1_A;
                    op_b      = A1_B;
                    op_sel    = 2'b01;
                    cur_class = 2'd1;
                end
                intended_mode = c4_mode(2'd1, A1_A[11:6], depth_cnt[7:0]);  // A1 baseline intended
                actual_mode   = c4_mode(cur_class, op_a[11:6], depth_cnt[7:0]);
            end

            // ================================================================
            // R4 — Boundary Thrashing
            // ================================================================
            else if (regime_id == 3) begin
                // Cycle through 4 boundary E values every 4 cycles
                op_sel = 2'b00;  // ADD at all boundary points
                cur_class = 2'd2;
                case (local_cyc % 4)
                    2'd0: begin op_a = {1'b0, 6'd15, 6'd32}; op_b = {1'b0, 6'd15, 6'd32}; end
                    2'd1: begin op_a = {1'b0, 6'd16, 6'd32}; op_b = {1'b0, 6'd16, 6'd32}; end
                    2'd2: begin op_a = {1'b0, 6'd47, 6'd32}; op_b = {1'b0, 6'd47, 6'd32}; end
                    default: begin op_a = {1'b0, 6'd48, 6'd32}; op_b = {1'b0, 6'd48, 6'd32}; end
                endcase
                intended_mode = c4_mode(2'd2, 6'd32, depth_cnt[7:0]);    // clean ADD E=32
                actual_mode   = c4_mode(cur_class, op_a[11:6], depth_cnt[7:0]);
            end

            // ================================================================
            // R5 — Control Noise Attack (bit-flip mode_tag)
            // ================================================================
            else begin
                // Noise level increases in 500-cycle steps: 10% → 20% → 30%
                noise_level = local_cyc / 500;  // 0, 1, or 2
                case (noise_level)
                    0: noise_t5 = 5'd3;    // 3/32 ≈  9.4%
                    1: noise_t5 = 5'd6;    // 6/32 ≈ 18.75%
                    default: noise_t5 = 5'd10; // 10/32 ≈ 31.25%
                endcase

                // Flip each mode_tag bit independently based on LFSR windows
                actual_mode[0] = intended_mode[0] ^ ((lfsr[4:0]  < noise_t5) ? 1'b1 : 1'b0);
                actual_mode[1] = intended_mode[1] ^ ((lfsr[9:5]  < noise_t5) ? 1'b1 : 1'b0);
                actual_mode[2] = intended_mode[2] ^ ((lfsr[14:10] < noise_t5) ? 1'b1 : 1'b0);
                // Operands remain clean A1 baseline
            end

            // ── Apply to DUT ──────────────────────────────────────────────
            mode_tag = actual_mode;

            accum_en = (op_sel != 2'b11 &&
                        classify(op_a[11:6]) != 2'd0 &&
                        classify(op_a[11:6]) != 2'd3) ? 1'b1 : 1'b0;

            @(posedge clk); #1;

            // ── MUL feedback ──────────────────────────────────────────────
            if (op_sel == 2'b10) begin
                if (exp_ovf_flag) mulfeed = {1'b0, 6'd32, 6'd0};
                else              mulfeed = result;
            end

            depth_cnt = depth_cnt + 1;

            // ── Log ──────────────────────────────────────────────────────
            $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,", total_cyc, regime_id, local_cyc,
                    intended_mode, actual_mode);

            case (op_sel)
                2'b00: $fwrite(fd, "ADD,");
                2'b01: $fwrite(fd, "SUB,");
                2'b10: $fwrite(fd, "MUL,");
                2'b11: $fwrite(fd, "NOP,");
            endcase

            $fwrite(fd, "%0d,%0d,%0d,", op_a[11:6], result[11:6], accum_out);

            case (classify(result[11:6]))
                2'd0: $fwrite(fd, "COLLAPSE,");
                2'd1: $fwrite(fd, "TRANSITION,");
                2'd2: $fwrite(fd, "STABLE,");
                2'd3: $fwrite(fd, "SATURATE,");
            endcase

            $fwrite(fd, "%0d,%0d,%0d\n", underflow_flag, exp_ovf_flag, noise_level);
        end

        $fclose(fd);
        $display("  7,500 cycles → HBS_C15_OOB.csv");
        $finish;
    end

endmodule
