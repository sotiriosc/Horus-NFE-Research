`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c14_attractor_computation
// Project  : HORUS v3 — HBS-C14: Attractor-to-Computation Synthesis
//
// Goal: Discover whether A1–A4 transitions implement useful computational
//       primitives and form an algebraic system under composition.
//
// C14A — Sequence Encoding (10 seqs × 5 reps × 80 cyc)       = 4,000
// C14B — Primitive Characterization (16 tests × 64 cyc)        = 1,024
// C14C — Algebra Closure (20 composition tests × 64 cyc)       = 1,280
// C14D — Equivalence Mapping (5 motif tests × 80 cyc)          =   400
// C14E — Minimal Program Synthesis (15 prog-runs × 80 cyc)     = 1,200
//
// Total: 7,904 cycles
//
// Attractor encoding (2-bit): A1=0 A2=1 A3=2 A4=3
//
// C14A sequences (5 phases × 2 bits packed MSB-first, 10-bit):
//  seq 0: A1×5       = 10'b00_00_00_00_00
//  seq 1: A2×5       = 10'b01_01_01_01_01
//  seq 2: A3×5       = 10'b10_10_10_10_10
//  seq 3: A4×5       = 10'b11_11_11_11_11
//  seq 4: A1A2A3A4A1 = 10'b00_01_10_11_00
//  seq 5: A4A3A2A1A1 = 10'b11_10_01_00_00
//  seq 6: A2A3A2A3A2 = 10'b01_10_01_10_01
//  seq 7: A1A2A1A2A1 = 10'b00_01_00_01_00
//  seq 8: A1A4A1A4A1 = 10'b00_11_00_11_00
//  seq 9: A3A1A3A1A3 = 10'b10_00_10_00_10
// ============================================================================

module tb_hbs_c14_attractor_computation;

    localparam C14A_START = 0;      localparam C14A_CYCS = 4000;
    localparam C14B_START = 4000;   localparam C14B_CYCS = 1024;
    localparam C14C_START = 5024;   localparam C14C_CYCS = 1280;
    localparam C14D_START = 6304;   localparam C14D_CYCS = 400;
    localparam C14E_START = 6704;   localparam C14E_CYCS = 1200;
    localparam TOTAL      = 7904;

    localparam PHASE_LEN  = 16;   // cycles per attractor phase
    localparam PROG_LEN   = 80;   // cycles per program (5 phases)
    localparam PRIM_LEN   = 64;   // cycles per primitive test
    localparam MOTIF_LEN  = 80;   // cycles per motif test

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

    // Sequence lookup: returns 2-bit attractor id for (seq_id, phase)
    function [1:0] seq_att;
        input [3:0] sid;
        input [2:0] ph;
        reg [9:0] seqbits;
        begin
            case (sid)
                4'd0: seqbits = 10'b00_00_00_00_00;  // A1×5
                4'd1: seqbits = 10'b01_01_01_01_01;  // A2×5
                4'd2: seqbits = 10'b10_10_10_10_10;  // A3×5
                4'd3: seqbits = 10'b11_11_11_11_11;  // A4×5
                4'd4: seqbits = 10'b00_01_10_11_00;  // A1→A2→A3→A4→A1
                4'd5: seqbits = 10'b11_10_01_00_00;  // A4→A3→A2→A1→A1
                4'd6: seqbits = 10'b01_10_01_10_01;  // A2-A3 oscillation
                4'd7: seqbits = 10'b00_01_00_01_00;  // A1-A2 alternation
                4'd8: seqbits = 10'b00_11_00_11_00;  // noise injection
                4'd9: seqbits = 10'b10_00_10_00_10;  // boundary detection
                default: seqbits = 10'd0;
            endcase
            seq_att = seqbits[(4-ph)*2 +: 2];
        end
    endfunction

    // C14E program sequences (5 programs, same 2-bit/phase encoding)
    function [1:0] prog_att;
        input [2:0] pid;
        input [2:0] ph;
        reg [9:0] pbits;
        begin
            case (pid)
                3'd0: pbits = 10'b00_00_00_00_00;  // stable accumulator: A1×5
                3'd1: pbits = 10'b01_01_10_00_00;  // saturation detector: A2A2A3A1A1
                3'd2: pbits = 10'b00_00_01_00_00;  // cancellation amplifier: A1A1A2A1A1
                3'd3: pbits = 10'b10_00_00_00_00;  // boundary trigger: A3A1A1A1A1
                3'd4: pbits = 10'b11_00_00_00_00;  // drift stabilizer: A4A1A1A1A1
                default: pbits = 10'd0;
            endcase
            prog_att = pbits[(4-ph)*2 +: 2];
        end
    endfunction

    // Canonical operand presets
    localparam [12:0] A1_A  = {1'b0, 6'd32, 6'd32};
    localparam [12:0] A1_B  = {1'b0, 6'd32, 6'd35};
    localparam [12:0] A2_B  = {1'b0, 6'd33, 6'd0};
    localparam [12:0] A3_AB = {1'b0, 6'd47, 6'd32};
    localparam [12:0] A4_S  = {1'b0, 6'd32, 6'd32};
    localparam [12:0] A4_C  = {1'b0, 6'd15, 6'd20};
    localparam [12:0] A4_T  = {1'b0, 6'd48, 6'd10};

    // =========================================================================
    // Operand assignment task
    // =========================================================================
    reg [1:0] cur_class;
    task set_att;
        input [1:0] att;
        input integer cyc;  // local cycle for A4 pattern
        begin
            case (att)
                2'd0: begin  // A1: SUB near-equal
                    op_a = A1_A; op_b = A1_B; op_sel = 2'b01; cur_class = 2'd1;
                end
                2'd1: begin  // A2: MUL chain
                    op_a = mulfeed; op_b = A2_B; op_sel = 2'b10; cur_class = 2'd3;
                end
                2'd2: begin  // A3: ADD at high boundary
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
    // LFSR
    // =========================================================================
    reg [15:0] lfsr;
    wire       lfsr_fb = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hBEEF;
        else        lfsr <= {lfsr[14:0], lfsr_fb};
    end

    // MUL feedback register
    reg [12:0] mulfeed;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // Main simulation loop
    // =========================================================================
    integer fd;
    integer total_cyc, local_cyc, suite_id, test_id;

    // C14A
    integer run_id, seq_id, rep_id, run_local, phase_idx, phase_local;
    // C14B
    integer prim_id, att_id, prim_level, prim_local;
    // C14C
    integer compose_id, compose_local, c_phase;
    integer comp_first, comp_second;
    // C14D
    integer motif_id, motif_local;
    // C14E
    integer prog_run, prog_id, prog_rep, prog_local;

    integer depth_cnt;
    reg [1:0] active_att;

    initial begin : MAIN
        $display("HBS-C14: Attractor Computation Synthesis — 7,904 cycles");

        op_a = A1_A; op_b = A1_B; op_sel = 2'b11;
        mode_tag = 3'b000; accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;
        rst_n = 1'b0; depth_cnt = 0;
        mulfeed = {1'b0, 6'd32, 6'd0};
        active_att = 2'd0;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C14_COMPUTATION.csv", "w");
        $fwrite(fd, "total_cycle,suite_id,local_cycle,test_id,phase,rep,att,op,E_in,E_out,accum,region,UF,OVF,param\n");

        for (total_cyc = 0; total_cyc < TOTAL; total_cyc = total_cyc + 1) begin
            @(negedge clk);

            accum_clr = 1'b0;
            op_a = A1_A; op_b = A1_B; op_sel = 2'b11;
            cur_class = 2'd0; active_att = 2'd0;

            // ==============================================================
            // C14A — Attractor Sequence Encoding (4,000 cycles)
            // ==============================================================
            if (total_cyc < C14B_START) begin
                suite_id  = 0; local_cyc = total_cyc;
                run_id    = local_cyc / PROG_LEN;    // 0..49
                run_local = local_cyc % PROG_LEN;    // 0..79
                seq_id    = run_id / 5;              // 0..9
                rep_id    = run_id % 5;              // 0..4
                phase_idx = run_local / PHASE_LEN;   // 0..4
                phase_local = run_local % PHASE_LEN; // 0..15
                test_id   = seq_id;

                // Reset state at start of each repetition
                if (run_local == 0) begin
                    accum_clr = 1'b1;
                    depth_cnt  = 0;
                    mulfeed    = {1'b0, 6'd32, 6'd0};
                end

                active_att = seq_att(seq_id[3:0], phase_idx[2:0]);
                set_att(active_att, run_local);
            end

            // ==============================================================
            // C14B — Primitive Characterization (1,024 cycles)
            // ==============================================================
            else if (total_cyc < C14C_START) begin
                suite_id   = 1; local_cyc = total_cyc - C14B_START;
                prim_id    = local_cyc / PRIM_LEN;  // 0..15
                prim_local = local_cyc % PRIM_LEN;  // 0..63
                att_id     = prim_id / 4;            // 0..3
                prim_level = prim_id % 4;            // 0..3
                test_id    = prim_id;

                if (prim_local == 0) begin
                    accum_clr = 1'b1; depth_cnt = 0;
                    mulfeed   = {1'b0, 6'd32, 6'd0};
                end

                case (att_id)
                    0: begin  // A1 primitives (4 tests)
                        op_sel = 2'b01; cur_class = 2'd1;
                        case (prim_level)
                            0: begin  // standard: E=32, delta=3
                                op_a = {1'b0, 6'd32, 6'd32};
                                op_b = {1'b0, 6'd32, 6'd35};
                            end
                            1: begin  // larger delta: delta=10
                                op_a = {1'b0, 6'd32, 6'd20};
                                op_b = {1'b0, 6'd32, 6'd30};
                            end
                            2: begin  // near boundary: E=40
                                op_a = {1'b0, 6'd40, 6'd32};
                                op_b = {1'b0, 6'd40, 6'd35};
                            end
                            default: begin  // very small delta (near-perfect cancel)
                                op_a = {1'b0, 6'd32, 6'd32};
                                op_b = {1'b0, 6'd32, 6'd33};
                            end
                        endcase
                        active_att = 2'd0;
                    end
                    1: begin  // A2 primitives (4 tests)
                        op_a = mulfeed; op_sel = 2'b10; cur_class = 2'd3;
                        case (prim_level)
                            0: op_b = {1'b0, 6'd33, 6'd0};  // ×2 standard
                            1: op_b = {1'b0, 6'd35, 6'd0};  // ×4 faster
                            2: begin                           // start from low E
                                if (prim_local == 0) mulfeed = {1'b0, 6'd20, 6'd0};
                                op_a = mulfeed; op_b = {1'b0, 6'd33, 6'd0};
                            end
                            default: begin                     // reset on OVF
                                op_b = {1'b0, 6'd33, 6'd0};
                            end
                        endcase
                        active_att = 2'd1;
                    end
                    2: begin  // A3 primitives (4 tests)
                        op_sel = 2'b00; cur_class = 2'd2;
                        case (prim_level)
                            0: begin  // high boundary E=47
                                op_a = {1'b0, 6'd47, 6'd32}; op_b = {1'b0, 6'd47, 6'd32};
                            end
                            1: begin  // low boundary E=15
                                op_a = {1'b0, 6'd15, 6'd32}; op_b = {1'b0, 6'd15, 6'd32};
                            end
                            2: begin  // mid-TRANSITION E=44
                                op_a = {1'b0, 6'd44, 6'd32}; op_b = {1'b0, 6'd44, 6'd32};
                            end
                            default: begin  // boundary with varying fraction
                                op_a = {1'b0, 6'd47, lfsr[5:0]};
                                op_b = {1'b0, 6'd47, lfsr[5:0]};
                            end
                        endcase
                        active_att = 2'd2;
                    end
                    default: begin  // A4 primitives (4 tests)
                        op_sel = 2'b00; cur_class = 2'd0;
                        case (prim_level)
                            0: begin  // standard 40/30/30
                                case (prim_local % 10)
                                    0,1,2,3: begin op_a = A4_S; op_b = A4_S; end
                                    4,5,6:   begin op_a = A4_C; op_b = A4_C; end
                                    default: begin op_a = A4_T; op_b = A4_T; end
                                endcase
                            end
                            1: begin  // equal 33/33/33
                                case (prim_local % 9)
                                    0,1,2: begin op_a = A4_S; op_b = A4_S; end
                                    3,4,5: begin op_a = A4_C; op_b = A4_C; end
                                    default: begin op_a = A4_T; op_b = A4_T; end
                                endcase
                            end
                            2: begin  // SAT-heavy 20/20/60
                                case (prim_local % 10)
                                    0,1:     begin op_a = A4_S; op_b = A4_S; end
                                    2,3:     begin op_a = A4_C; op_b = A4_C; end
                                    default: begin op_a = A4_T; op_b = A4_T; end
                                endcase
                            end
                            default: begin  // rapid switching (2-cycle pattern)
                                case (prim_local % 4)
                                    0,1: begin op_a = A4_S; op_b = A4_S; end
                                    2:   begin op_a = A4_C; op_b = A4_C; end
                                    default: begin op_a = A4_T; op_b = A4_T; end
                                endcase
                            end
                        endcase
                        active_att = 2'd3;
                    end
                endcase
            end

            // ==============================================================
            // C14C — Attractor Algebra Closure (1,280 cycles)
            // ==============================================================
            else if (total_cyc < C14D_START) begin
                suite_id      = 2; local_cyc = total_cyc - C14C_START;
                compose_id    = local_cyc / PRIM_LEN;  // 0..19
                compose_local = local_cyc % PRIM_LEN;  // 0..63
                test_id       = compose_id;

                if (compose_local == 0) begin
                    accum_clr = 1'b1; depth_cnt = 0;
                    mulfeed   = {1'b0, 6'd32, 6'd0};
                end

                // Determine which half of the 64-cycle test we're in
                c_phase = (compose_local < 32) ? 0 : 1;

                // Decode first/second attractor for each compose_id
                case (compose_id)
                    // CONCAT pairs: (A_i × 32, A_j × 32)
                    0:  begin comp_first = 0; comp_second = 1; end  // A1→A2
                    1:  begin comp_first = 0; comp_second = 2; end  // A1→A3
                    2:  begin comp_first = 0; comp_second = 3; end  // A1→A4
                    3:  begin comp_first = 1; comp_second = 0; end  // A2→A1
                    4:  begin comp_first = 1; comp_second = 2; end  // A2→A3
                    5:  begin comp_first = 1; comp_second = 3; end  // A2→A4
                    6:  begin comp_first = 2; comp_second = 0; end  // A3→A1
                    7:  begin comp_first = 2; comp_second = 1; end  // A3→A2
                    8:  begin comp_first = 2; comp_second = 3; end  // A3→A4
                    9:  begin comp_first = 3; comp_second = 0; end  // A4→A1
                    10: begin comp_first = 3; comp_second = 1; end  // A4→A2
                    11: begin comp_first = 3; comp_second = 2; end  // A4→A3
                    // LOOP: single attractor for full 64 cycles
                    12: begin comp_first = 0; comp_second = 0; end  // A1 LOOP
                    13: begin comp_first = 1; comp_second = 1; end  // A2 LOOP
                    14: begin comp_first = 2; comp_second = 2; end  // A3 LOOP
                    15: begin comp_first = 3; comp_second = 3; end  // A4 LOOP
                    // MIX: alternate every 16 cycles
                    16: begin comp_first = 0; comp_second = 1; end  // A1/A2 mix
                    17: begin comp_first = 0; comp_second = 2; end  // A1/A3 mix
                    18: begin comp_first = 1; comp_second = 3; end  // A2/A4 mix
                    // RESET: strong reset chain
                    default: begin comp_first = 3; comp_second = 0; end  // A4→RESET→A1
                endcase

                // MIX: alternate every PHASE_LEN instead of 32
                if (compose_id >= 16 && compose_id <= 18)
                    active_att = ((compose_local / PHASE_LEN) % 2 == 0) ?
                                  comp_first[1:0] : comp_second[1:0];
                else
                    active_att = (c_phase == 0) ? comp_first[1:0] : comp_second[1:0];

                set_att(active_att, compose_local);
            end

            // ==============================================================
            // C14D — Computation Equivalence Mapping (400 cycles)
            // ==============================================================
            else if (total_cyc < C14E_START) begin
                suite_id    = 3; local_cyc = total_cyc - C14D_START;
                motif_id    = local_cyc / MOTIF_LEN;  // 0..4
                motif_local = local_cyc % MOTIF_LEN;  // 0..79
                test_id     = motif_id;
                phase_idx   = motif_local / PHASE_LEN; // 0..4

                if (motif_local == 0) begin
                    accum_clr = 1'b1; depth_cnt = 0;
                    mulfeed   = {1'b0, 6'd32, 6'd0};
                end

                case (motif_id)
                    // Motif 0: MAC accumulation chain (ADD at E=32)
                    0: begin
                        op_a = {1'b0, 6'd32, 6'd32}; op_b = {1'b0, 6'd32, 6'd32};
                        op_sel = 2'b00; cur_class = 2'd0; active_att = 2'd0;
                    end
                    // Motif 1: Cancellation identity (near-perfect SUB)
                    1: begin
                        op_a = {1'b0, 6'd32, 6'd32}; op_b = {1'b0, 6'd32, 6'd33};
                        op_sel = 2'b01; cur_class = 2'd1; active_att = 2'd0;
                    end
                    // Motif 2: Threshold function (A3 boundary oscillation = clamping)
                    2: begin
                        set_att(2'd2, motif_local); active_att = 2'd2;
                    end
                    // Motif 3: Oscillatory filter (A2→A3 alternating, 2 epochs each)
                    3: begin
                        if ((motif_local / 32) % 2 == 0) begin
                            set_att(2'd1, motif_local); active_att = 2'd1;
                        end else begin
                            set_att(2'd2, motif_local); active_att = 2'd2;
                        end
                    end
                    // Motif 4: Bounded integrator (A1×3 → A3 → A1)
                    default: begin
                        case (phase_idx)
                            0,1,2: begin set_att(2'd0, motif_local); active_att = 2'd0; end
                            3:     begin set_att(2'd2, motif_local); active_att = 2'd2; end
                            default: begin set_att(2'd0, motif_local); active_att = 2'd0; end
                        endcase
                    end
                endcase
            end

            // ==============================================================
            // C14E — Minimal Program Synthesis (1,200 cycles)
            // ==============================================================
            else begin
                suite_id  = 4; local_cyc = total_cyc - C14E_START;
                prog_run  = local_cyc / PROG_LEN;   // 0..14
                prog_local = local_cyc % PROG_LEN;  // 0..79
                prog_id   = prog_run / 3;            // 0..4
                prog_rep  = prog_run % 3;            // 0..2
                phase_idx = prog_local / PHASE_LEN;  // 0..4
                test_id   = prog_id;

                if (prog_local == 0) begin
                    accum_clr = 1'b1; depth_cnt = 0;
                    mulfeed   = {1'b0, 6'd32, 6'd0};
                end

                active_att = prog_att(prog_id[2:0], phase_idx[2:0]);
                set_att(active_att, prog_local);
            end

            // ── C4 mode & accum_en ─────────────────────────────────────────
            mode_tag = c4_mode(cur_class, op_a[11:6], depth_cnt[7:0]);

            if (op_sel == 2'b11 ||
                classify(op_a[11:6]) == 2'd0 ||
                classify(op_a[11:6]) == 2'd3)
                accum_en = 1'b0;
            else
                accum_en = 1'b1;

            @(posedge clk); #1;

            // ── MUL feedback ───────────────────────────────────────────────
            if (op_sel == 2'b10) begin
                if (exp_ovf_flag) mulfeed = {1'b0, 6'd32, 6'd0};
                else              mulfeed = result;
            end

            depth_cnt = depth_cnt + 1;

            // ── Log ────────────────────────────────────────────────────────
            $fwrite(fd, "%0d,%0d,%0d,%0d,", total_cyc, suite_id, local_cyc, test_id);

            // phase and rep encoding
            if (suite_id == 0)
                $fwrite(fd, "%0d,%0d,", phase_idx, rep_id);
            else if (suite_id == 1)
                $fwrite(fd, "%0d,%0d,", prim_level, att_id);
            else if (suite_id == 2)
                $fwrite(fd, "%0d,%0d,", (compose_local < 32) ? 0 : 1, compose_id);
            else if (suite_id == 3)
                $fwrite(fd, "%0d,%0d,", motif_local / PHASE_LEN, 0);
            else
                $fwrite(fd, "%0d,%0d,", phase_idx, prog_rep);

            $fwrite(fd, "%0d,", active_att);

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
            $fwrite(fd, "%0d,%0d,%0d\n", underflow_flag, exp_ovf_flag,
                    (suite_id == 1) ? prim_level : phase_idx);
        end

        $fclose(fd);
        $display("  7,904 cycles → HBS_C14_COMPUTATION.csv");
        $finish;
    end

endmodule
