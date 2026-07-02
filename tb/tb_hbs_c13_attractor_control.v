`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c13_attractor_control
// Project  : HORUS v3 — HBS-C13: Attractor Controllability & Phase Steering
// File     : tb_hbs_c13_attractor_control.v
//
// Purpose:
//   Determine whether HORUS v3 attractor dynamics can be intentionally steered
//   via input design alone (no RTL/compiler/policy changes).
//
//   C13A — Directed Attractor Steering:  12 transitions × 260 cycles  = 3,120
//   C13B — Minimal Control Signal:        20 perturbation tests × 50   = 1,000
//   C13C — Basin Boundary Mapping:         9 grid points × 32 cycles   =   288
//   C13D — Control Under Noise:           12 noisy-trans × 260 cycles  = 3,120
//
//   Total: 7,528 cycles
//
// C13A Transition table (trans_id, source→target):
//   0:A1→A2  1:A1→A3  2:A1→A4
//   3:A2→A1  4:A2→A3  5:A2→A4
//   6:A3→A1  7:A3→A2  8:A3→A4
//   9:A4→A1  10:A4→A2 11:A4→A3
// ============================================================================

module tb_hbs_c13_attractor_control;

    localparam C13A_START = 0;     localparam C13A_CYCS = 3120;
    localparam C13B_START = 3120;  localparam C13B_CYCS = 1000;
    localparam C13C_START = 4120;  localparam C13C_CYCS = 288;
    localparam C13D_START = 4408;  localparam C13D_CYCS = 3120;
    localparam TOTAL      = 7528;

    localparam EPOCH_DEPTH = 16;
    localparam BASELINE_CYCS = 100;  // cycles to establish source attractor
    localparam TARGET_CYCS   = 160;  // cycles to measure target attractor (10 epochs)
    localparam TRANS_CYCS    = BASELINE_CYCS + TARGET_CYCS;  // 260

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
    // C4 kernel
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
    // Common operand presets
    // =========================================================================
    localparam [12:0] A1_A = {1'b0, 6'd32, 6'd32};  // SUB base
    localparam [12:0] A1_B = {1'b0, 6'd32, 6'd35};  // SUB near-equal
    localparam [12:0] A2_B = {1'b0, 6'd33, 6'd0};   // MUL ×2 factor
    localparam [12:0] A3_AB = {1'b0, 6'd47, 6'd32}; // ADD at high boundary
    localparam [12:0] A4_S  = {1'b0, 6'd32, 6'd32}; // STABLE inject
    localparam [12:0] A4_C  = {1'b0, 6'd15, 6'd20}; // COLLAPSE inject
    localparam [12:0] A4_T  = {1'b0, 6'd48, 6'd10}; // SATURATE inject

    // =========================================================================
    // LFSR for C13D noise
    // =========================================================================
    reg [15:0] lfsr;
    wire       lfsr_fb = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hABCD;
        else        lfsr <= {lfsr[14:0], lfsr_fb};
    end

    // =========================================================================
    // State
    // =========================================================================
    integer fd;
    integer total_cyc, local_cyc, suite_id, test_id, depth_cnt;
    integer trans_id, trans_local, phase_c13, source_att, target_att, active_att;
    integer perturb_id, perturb_local, perturb_att, perturb_level;
    integer basin_id;
    integer noise_trans_id, noise_trans_local, noise_level, actual_trans_id;
    reg [12:0] mulfeed;
    reg [1:0]  cur_class;

    // =========================================================================
    // Task: set ops for a given attractor index and local-cycle position
    //   att: 0=A1, 1=A2, 2=A3, 3=A4
    //   cyc: local cycle (for A4 injection pattern)
    // =========================================================================
    task set_attractor_ops;
        input integer att;
        input integer cyc;
        begin
            case (att)
                0: begin  // A1: SUB near-equal
                    op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                end
                1: begin  // A2: MUL chain ×2
                    op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                end
                2: begin  // A3: ADD at high boundary (E=47)
                    op_a = A3_AB; op_b = A3_AB; op_sel = 2'b00; cur_class = 2'd2;
                end
                default: begin  // A4: 40/30/30 injection
                    op_sel = 2'b00; cur_class = 2'd0;
                    case (cyc % 10)
                        0,1,2,3: begin op_a = A4_S; op_b = A4_S; end
                        4,5,6:   begin op_a = A4_C; op_b = A4_C; end
                        default: begin op_a = A4_T; op_b = A4_T; end
                    endcase
                end
            endcase
        end
    endtask

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // Main
    // =========================================================================
    initial begin : MAIN
        $display("HBS-C13: Attractor Controllability Suite — 7,528 cycles");

        op_a = A1_A; op_b = A1_B; op_sel = 2'b11;
        mode_tag = 3'b000; accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0; depth_cnt = 0;
        mulfeed = {1'b0, 6'd32, 6'd0};

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C13_CONTROL.csv", "w");
        $fwrite(fd, "total_cycle,suite_id,local_cycle,test_id,phase,op,E_in,E_out,accum,region,UF,OVF,param\n");

        for (total_cyc = 0; total_cyc < TOTAL; total_cyc = total_cyc + 1) begin

            @(negedge clk);

            // ── Suite decode ─────────────────────────────────────────────────
            if (total_cyc < C13B_START) begin
                suite_id  = 0; local_cyc = total_cyc;
                trans_id  = local_cyc / TRANS_CYCS;
                trans_local = local_cyc % TRANS_CYCS;
                test_id   = trans_id;
                phase_c13 = (trans_local < BASELINE_CYCS) ? 0 : 1;
            end else if (total_cyc < C13C_START) begin
                suite_id      = 1; local_cyc = total_cyc - C13B_START;
                perturb_id    = local_cyc / 50;
                perturb_local = local_cyc % 50;
                test_id       = perturb_id;
                phase_c13     = (perturb_local < 25) ? 0 : 1;
                perturb_att   = perturb_id / 5;    // 0=A1→A2, 1=A1→A3, 2=A2→A1, 3=A3→A1
                perturb_level = perturb_id % 5;    // 0..4
            end else if (total_cyc < C13D_START) begin
                suite_id  = 2; local_cyc = total_cyc - C13C_START;
                basin_id  = local_cyc / 32;
                test_id   = basin_id;
                phase_c13 = 0;
            end else begin
                suite_id          = 3; local_cyc = total_cyc - C13D_START;
                noise_trans_id    = local_cyc / TRANS_CYCS;
                noise_trans_local = local_cyc % TRANS_CYCS;
                test_id           = noise_trans_id;
                phase_c13         = (noise_trans_local < BASELINE_CYCS) ? 0 : 1;
                noise_level       = noise_trans_id / 6;  // 0=NL2(30%frac), 1=NL4(E±1)
                actual_trans_id   = noise_trans_id % 6;  // maps to selected trans
            end

            // ── Epoch management ─────────────────────────────────────────────
            if (depth_cnt >= EPOCH_DEPTH || (suite_id == 0 && trans_local == 0) ||
                (suite_id == 1 && perturb_local == 0) ||
                (suite_id == 2 && (local_cyc % 32) == 0) ||
                (suite_id == 3 && noise_trans_local == 0)) begin
                accum_clr = 1'b1; depth_cnt = 0;
            end else begin
                accum_clr = 1'b0;
            end

            // ── Default ──────────────────────────────────────────────────────
            op_a = A1_A; op_b = A1_B; op_sel = 2'b11;
            cur_class = 2'd0;

            // ================================================================
            // C13A — Directed Attractor Steering
            // ================================================================
            if (suite_id == 0) begin
                // Decode source/target attractors
                if      (trans_id < 3) source_att = 0;  // A1
                else if (trans_id < 6) source_att = 1;  // A2
                else if (trans_id < 9) source_att = 2;  // A3
                else                   source_att = 3;  // A4

                case (trans_id)
                    0:  target_att = 1;  // A1→A2
                    1:  target_att = 2;  // A1→A3
                    2:  target_att = 3;  // A1→A4
                    3:  target_att = 0;  // A2→A1
                    4:  target_att = 2;  // A2→A3
                    5:  target_att = 3;  // A2→A4
                    6:  target_att = 0;  // A3→A1
                    7:  target_att = 1;  // A3→A2
                    8:  target_att = 3;  // A3→A4
                    9:  target_att = 0;  // A4→A1
                    10: target_att = 1;  // A4→A2
                    11: target_att = 2;  // A4→A3
                    default: target_att = 0;
                endcase

                active_att = phase_c13 ? target_att : source_att;

                // Reset mulfeed at transition start
                if (trans_local == 0) mulfeed = {1'b0, 6'd32, 6'd0};

                set_attractor_ops(active_att, trans_local);
            end

            // ================================================================
            // C13B — Minimal Control Signal Discovery
            // ================================================================
            else if (suite_id == 1) begin
                // perturb_att: 0=A1→A2  1=A1→A3  2=A2→A1  3=A3→A1
                // perturb_level:
                //   0: full target ops (guaranteed success)
                //   1: 50% source + 50% target interleaved
                //   2: source ops + E shifted ±1 toward target
                //   3: source ops only (no steering = baseline FAIL)
                //   4: 1/8 injection of target op in source stream

                // Reset mulfeed at start of each perturb test
                if (perturb_local == 0) mulfeed = {1'b0, 6'd32, 6'd0};

                case (perturb_att)
                    0: begin  // A1 → A2
                        if (phase_c13 == 0) begin
                            // Baseline: A1
                            op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                        end else begin
                            case (perturb_level)
                                0: begin  // Full MUL chain
                                    op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                                end
                                1: begin  // 50% MUL, 50% SUB interleaved
                                    if (perturb_local[0]) begin
                                        op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                                    end else begin
                                        op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                    end
                                end
                                2: begin  // SUB but E_b shifted +1 toward MUL regime
                                    op_a = A1_A; op_b = {1'b0, 6'd33, 6'd35}; op_sel = 2'b01; cur_class = 2'd1;
                                end
                                3: begin  // Source only (no steering) → FAIL expected
                                    op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                end
                                default: begin  // 1/8 MUL injection
                                    if ((perturb_local % 8) == 0) begin
                                        op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                                    end else begin
                                        op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                    end
                                end
                            endcase
                        end
                    end
                    1: begin  // A1 → A3
                        if (phase_c13 == 0) begin
                            op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                        end else begin
                            case (perturb_level)
                                0: begin  // Full ADD at E=47
                                    op_a = A3_AB; op_b = A3_AB; op_sel = 2'b00; cur_class = 2'd2;
                                end
                                1: begin  // 50% ADD E=47, 50% SUB E=32
                                    if (perturb_local[0]) begin
                                        op_a = A3_AB; op_b = A3_AB; op_sel = 2'b00; cur_class = 2'd2;
                                    end else begin
                                        op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                    end
                                end
                                2: begin  // ADD E=44 (close to boundary, E shifted toward E=47)
                                    op_a = {1'b0, 6'd44, 6'd32}; op_b = {1'b0, 6'd44, 6'd32};
                                    op_sel = 2'b00; cur_class = 2'd2;
                                end
                                3: begin  // Source only → FAIL
                                    op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                end
                                default: begin  // 1/8 ADD E=47 injection
                                    if ((perturb_local % 8) == 0) begin
                                        op_a = A3_AB; op_b = A3_AB; op_sel = 2'b00; cur_class = 2'd2;
                                    end else begin
                                        op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                    end
                                end
                            endcase
                        end
                    end
                    2: begin  // A2 → A1
                        if (phase_c13 == 0) begin
                            op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                        end else begin
                            case (perturb_level)
                                0: begin  // Full SUB (stop MUL chain)
                                    op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                end
                                1: begin  // 50% SUB, 50% MUL
                                    if (perturb_local[0]) begin
                                        op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                    end else begin
                                        op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                                    end
                                end
                                2: begin  // NOP (stop all ops)
                                    op_sel = 2'b11; cur_class = 2'd0;
                                end
                                3: begin  // Source only → FAIL
                                    op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                                end
                                default: begin  // Reduce MUL rate to 1/8
                                    if ((perturb_local % 8) == 0) begin
                                        op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                                    end else begin
                                        op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                    end
                                end
                            endcase
                        end
                    end
                    default: begin  // A3 → A1
                        if (phase_c13 == 0) begin
                            op_a = A3_AB; op_b = A3_AB; op_sel = 2'b00; cur_class = 2'd2;
                        end else begin
                            case (perturb_level)
                                0: begin  // Full SUB
                                    op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                end
                                1: begin  // ADD at E=44 (step away from boundary)
                                    op_a = {1'b0, 6'd44, 6'd32}; op_b = {1'b0, 6'd44, 6'd32};
                                    op_sel = 2'b00; cur_class = 2'd2;
                                end
                                2: begin  // ADD at E=43 (just inside STABLE)
                                    op_a = {1'b0, 6'd43, 6'd32}; op_b = {1'b0, 6'd43, 6'd32};
                                    op_sel = 2'b00; cur_class = 2'd0;
                                end
                                3: begin  // Source only → FAIL
                                    op_a = A3_AB; op_b = A3_AB; op_sel = 2'b00; cur_class = 2'd2;
                                end
                                default: begin  // 1/8 SUB injection into boundary ADD
                                    if ((perturb_local % 8) == 0) begin
                                        op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                                    end else begin
                                        op_a = A3_AB; op_b = A3_AB; op_sel = 2'b00; cur_class = 2'd2;
                                    end
                                end
                            endcase
                        end
                    end
                endcase
            end

            // ================================================================
            // C13C — Basin Boundary Mapping
            // ================================================================
            else if (suite_id == 2) begin
                // basin_id 0..8: (op, E) grid
                // op: basin_id / 3  (0=ADD, 1=SUB, 2=MUL)
                // E:  basin_id % 3  (0=E12/COLLAPSE, 1=E32/STABLE, 2=E47/TRANSITION)
                if (basin_id == 0 && (local_cyc % 32) == 0)
                    mulfeed = {1'b0, 6'd32, 6'd0};

                case (basin_id)
                    // ADD at E=12
                    0: begin
                        op_a = {1'b0, 6'd12, 6'd32}; op_b = {1'b0, 6'd12, 6'd32};
                        op_sel = 2'b00; cur_class = 2'd0;
                    end
                    // ADD at E=32
                    1: begin
                        op_a = {1'b0, 6'd32, 6'd32}; op_b = {1'b0, 6'd32, 6'd32};
                        op_sel = 2'b00; cur_class = 2'd0;
                    end
                    // ADD at E=47
                    2: begin
                        op_a = A3_AB; op_b = A3_AB; op_sel = 2'b00; cur_class = 2'd2;
                    end
                    // SUB at E=12
                    3: begin
                        op_a = {1'b0, 6'd12, 6'd32}; op_b = {1'b0, 6'd12, 6'd35};
                        op_sel = 2'b01; cur_class = 2'd1;
                    end
                    // SUB at E=32
                    4: begin
                        op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                    end
                    // SUB at E=47
                    5: begin
                        op_a = {1'b0, 6'd47, 6'd32}; op_b = {1'b0, 6'd47, 6'd35};
                        op_sel = 2'b01; cur_class = 2'd1;
                    end
                    // MUL at E=12 (factor ×2 from low E)
                    6: begin
                        op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                    end
                    // MUL at E=32 (standard chain)
                    7: begin
                        op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                    end
                    // MUL at E=47 (near SAT push)
                    default: begin
                        op_a = mulfeed; op_b = {1'b0, 6'd34, 6'd0};  // ×4
                        op_sel = 2'b10; cur_class = 2'd3;
                    end
                endcase
            end

            // ================================================================
            // C13D — Attractor Steering Under Noise
            // ================================================================
            else if (suite_id == 3) begin
                // actual_trans_id maps to C13A trans_ids: {0,1,3,6,9,10}
                integer real_trans;
                case (actual_trans_id)
                    0: real_trans = 0;   // A1→A2
                    1: real_trans = 1;   // A1→A3
                    2: real_trans = 3;   // A2→A1
                    3: real_trans = 6;   // A3→A1
                    4: real_trans = 9;   // A4→A1
                    default: real_trans = 10; // A4→A2
                endcase

                if (real_trans < 3)      source_att = 0;
                else if (real_trans < 6) source_att = 1;
                else if (real_trans < 9) source_att = 2;
                else                     source_att = 3;

                case (real_trans)
                    0:  target_att = 1;
                    1:  target_att = 2;
                    3:  target_att = 0;
                    6:  target_att = 0;
                    9:  target_att = 0;
                    default: target_att = 1;
                endcase

                active_att = phase_c13 ? target_att : source_att;
                if (noise_trans_local == 0) mulfeed = {1'b0, 6'd32, 6'd0};

                set_attractor_ops(active_att, noise_trans_local);

                // Apply noise to op_b based on noise_level
                if (noise_level == 0 && phase_c13 == 1) begin
                    // NL2: 30% fraction scramble
                    if (lfsr[9:0] < 10'd307) op_b[5:0] = lfsr[5:0];
                end else if (noise_level == 1 && phase_c13 == 1) begin
                    // NL4: E±1 jitter
                    case (lfsr[1:0])
                        2'b00: if (op_b[11:6] > 6'd1) op_b[11:6] = op_b[11:6] - 1;
                        2'b11: if (op_b[11:6] < 6'd62) op_b[11:6] = op_b[11:6] + 1;
                        default: ; // no change
                    endcase
                end
            end

            // ── C4 routing ──────────────────────────────────────────────────
            mode_tag = c4_mode(cur_class, op_a[11:6], depth_cnt[7:0]);

            // ── accum_en ────────────────────────────────────────────────────
            if (op_sel == 2'b11 ||
                classify(op_a[11:6]) == 2'd0 ||
                classify(op_a[11:6]) == 2'd3)
                accum_en = 1'b0;
            else
                accum_en = 1'b1;

            @(posedge clk); #1;

            // ── MUL feedback update ─────────────────────────────────────────
            if (op_sel == 2'b10) begin
                if (exp_ovf_flag)
                    mulfeed = {1'b0, 6'd32, 6'd0};
                else
                    mulfeed = result;
            end

            // ── Log ─────────────────────────────────────────────────────────
            $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,", total_cyc, suite_id, local_cyc, test_id, phase_c13);
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
            $fwrite(fd, "%0d,%0d,%0d\n", underflow_flag, exp_ovf_flag,
                    (suite_id == 3) ? noise_level : perturb_level);

            depth_cnt = depth_cnt + 1;
        end

        $fclose(fd);
        $display("  7,528 cycles → HBS_C13_CONTROL.csv");
        $finish;
    end

endmodule
