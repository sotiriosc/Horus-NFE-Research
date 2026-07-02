`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c6_real_world_stress
// Project  : HORUS v3 — HBS-C6: Adversarial Real-World Workload Stress-Test
// File     : tb_hbs_c6_real_world_stress.v
//
// Purpose:
//   External realism validation of the C4/C5-verified kernel under
//   adversarial, non-uniform workload stimulus. Tests horus_system RTL.
//
//   Five workload generators (W1–W5) produce realistic, non-synthetic
//   distributions. C4 kernel is applied to derive mode_tag each cycle.
//   Epoch depth management is enforced via accum_clr.
//
// Workloads:
//   W1  Sparse MAC bursts (CLASS_A): 95% anchor-energy, 5% spike
//   W2  Cancellation chains (CLASS_B): near-zero SUB with ±5–10% jitter
//   W3  Boundary oscillation (CLASS_C): E=14/16/47/48 ADD/MUL cycling
//   W4  Deep transformer chain (CLASS_D): MUL→ADD→SUB→MUL with feedback
//   W5  Saturation spike injection (CLASS_A): 10% max-TRANSITION spikes
//
// DUT interface (horus_system.v — exact port names):
//   op_sel: 2'b00=ADD  2'b01=SUB  2'b10=MUL  2'b11=NOP
//   accum_out: 32-bit wide accumulator
//   accum_clr (not clear_accum)
//
// Output: HBS_C6_REAL_WORLD.csv
//   Columns: cycle,workload_id,class,E,depth,op,mode,result,accum,region,UF,OVF
// ============================================================================

module tb_hbs_c6_real_world_stress;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CYCLES_PER_WL = 500;
    parameter TOTAL_CYCLES  = CYCLES_PER_WL * 5;   // 2500 cycles
    parameter EPOCH_DEPTH   = 16;                   // C4 depth threshold

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg         clk, rst_n;
    reg  [12:0] op_a, op_b;
    reg  [1:0]  op_sel;      // 00=ADD 01=SUB 10=MUL 11=NOP (horus_system.v)
    reg  [2:0]  mode_tag;
    reg         accum_en;
    reg         accum_clr;
    reg  [5:0]  host_tile_depth;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag;
    wire        underflow_flag;
    wire        exp_ovf_flag;
    wire [15:0] op_count;
    wire        accum_full;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    horus_system dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .op_a           (op_a),
        .op_b           (op_b),
        .op_sel         (op_sel),
        .mode_tag       (mode_tag),
        .accum_en       (accum_en),
        .accum_clr      (accum_clr),
        .host_tile_depth(host_tile_depth),
        .result         (result),
        .accum_out      (accum_out),
        .rollover_flag  (rollover_flag),
        .underflow_flag (underflow_flag),
        .exp_ovf_flag   (exp_ovf_flag),
        .op_count       (op_count),
        .accum_full     (accum_full)
    );

    // =========================================================================
    // C4 kernel helpers (priority-encoded predicate evaluator — §1.3 C4 spec)
    // =========================================================================

    function [1:0] classify;
        input [5:0] e;
        begin
            if      (e <= 6'd15) classify = 2'd0;  // COLLAPSE
            else if (e <= 6'd19) classify = 2'd1;  // TRANSITION
            else if (e <= 6'd43) classify = 2'd2;  // STABLE
            else if (e <= 6'd47) classify = 2'd1;  // TRANSITION
            else                 classify = 2'd3;  // SATURATION
        end
    endfunction

    // Returns C4 mode_tag (3-bit) for (class, estimated_E, depth).
    // Depth override is the terminal annihilation step.
    function [2:0] c4_mode;
        input [1:0] cls;       // 0=A 1=B 2=C 3=D
        input [5:0] e_in;      // estimated_E from op_a[11:6]
        input [7:0] d;         // current epoch depth
        reg   [1:0] rgn;
        begin
            rgn = classify(e_in);
            if (d > 8'd16) begin
                c4_mode = 3'b010;            // terminal annihilation
            end else begin
                case (rgn)
                    2'd2: c4_mode = 3'b000;  // STABLE
                    2'd1: c4_mode = (cls == 2'd1 || cls == 2'd3)
                                    ? 3'b010 : 3'b000; // TRANSITION B/D vs A/C
                    2'd0: c4_mode = (cls == 2'd0)
                                    ? 3'b011 : 3'b010; // COLLAPSE A vs B/C/D
                    2'd3: c4_mode = 3'b011;  // SATURATION
                    default: c4_mode = 3'b000;
                endcase
            end
        end
    endfunction

    // =========================================================================
    // NFE codeword constants  {sign[1], E[6], f[6]}
    //   sign = bit[12]  E = bits[11:6]  f = bits[5:0]
    //   op_sel: 2'b00=ADD  2'b01=SUB  2'b10=MUL  2'b11=NOP
    // =========================================================================

    // W1: Sparse MAC — anchor background (E=32) and high-energy spike (E=40)
    localparam [12:0] W1_BG    = {1'b0, 6'd32, 6'd0};   // anchor: E=32, f=0
    localparam [12:0] W1_SPIKE = {1'b0, 6'd40, 6'd50};  // spike:  E=40, f=50

    // W2: Cancellation — base value and jittered subtrahend
    localparam [12:0] W2_BASE  = {1'b0, 6'd32, 6'd32};  // E=32, f=32

    // W3: Boundary oscillation — four boundary-adjacent values
    localparam [12:0] W3_COLL  = {1'b0, 6'd14, 6'd32};  // E=14 COLLAPSE edge
    localparam [12:0] W3_TLO   = {1'b0, 6'd16, 6'd0};   // E=16 TRANSITION lo
    localparam [12:0] W3_THI   = {1'b0, 6'd47, 6'd32};  // E=47 TRANSITION hi
    localparam [12:0] W3_SAT   = {1'b0, 6'd48, 6'd0};   // E=48 SATURATION

    // W4: Transformer chain — weight, bias, initial value
    localparam [12:0] W4_INIT  = {1'b0, 6'd32, 6'd32};  // E=32 initial
    localparam [12:0] W4_WGT   = {1'b0, 6'd32, 6'd20};  // E=32 weight
    localparam [12:0] W4_BIAS  = {1'b0, 6'd28, 6'd10};  // E=28 bias (lower)

    // W5: Saturation spikes — max TRANSITION spike and noise floor
    localparam [12:0] W5_SPIKE = {1'b0, 6'd47, 6'd63};  // E=47, f=63 max
    localparam [12:0] W5_NOISE = {1'b0, 6'd22, 6'd3};   // E=22 noise floor

    // =========================================================================
    // Test variables
    // =========================================================================
    integer  fd;
    integer  cyc, wid, cyc_local;
    integer  depth_cnt;
    reg [12:0] w4_feedback;   // W4: result from previous cycle
    reg [1:0]  cls_r;
    reg [5:0]  e_in_r;
    reg [5:0]  e_jitter;      // W2 jitter field

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // =========================================================================
    // Main exhaustive workload sweep
    // =========================================================================
    initial begin : MAIN
        $display("");
        $display("============================================================");
        $display("  HBS-C6: Adversarial Real-World Workload Stress-Test");
        $display("  5 workloads × %0d cycles = %0d total cycles",
                 CYCLES_PER_WL, TOTAL_CYCLES);
        $display("============================================================");

        // Defaults
        op_a = W1_BG; op_b = W1_BG;
        op_sel = 2'b11; mode_tag = 3'b000;
        accum_en = 1'b0; accum_clr = 1'b0;
        host_tile_depth = 6'd63;   // pgate fully open (HBS-14 fix)
        rst_n = 1'b0;
        depth_cnt = 0;
        w4_feedback = W4_INIT;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        fd = $fopen("HBS_C6_REAL_WORLD.csv", "w");
        $fwrite(fd,
            "cycle,workload_id,class,E,depth,op,mode,result,accum,region,UF,OVF\n");

        // ── Main loop ──────────────────────────────────────────────────────
        for (cyc = 0; cyc < TOTAL_CYCLES; cyc = cyc + 1) begin

            wid       = cyc / CYCLES_PER_WL;   // 0..4
            cyc_local = cyc % CYCLES_PER_WL;   // 0..499

            @(negedge clk);

            // ── Epoch boundary management ─────────────────────────────────
            if (depth_cnt > EPOCH_DEPTH || cyc_local == 0) begin
                accum_clr = 1'b1;
                depth_cnt = 0;
            end else begin
                accum_clr = 1'b0;
            end

            // ── Workload generators ───────────────────────────────────────

            case (wid)

                // ── W1: Sparse MAC bursts — CLASS_A ──────────────────────
                // 95% background MUL at E=32 anchor; 5% high-energy spike.
                // Models attention sparsity / token dropout.
                0: begin
                    cls_r  = 2'd0;
                    op_sel = 2'b10;  // MUL
                    if ((cyc_local % 20) == 0) begin
                        op_a = W1_SPIKE;  // 5% spike
                        op_b = W1_SPIKE;
                    end else begin
                        op_a = W1_BG;     // 95% anchor background
                        op_b = W1_BG;
                    end
                end

                // ── W2: Cancellation chains — CLASS_B ────────────────────
                // SUB(base, base±jitter) → near-zero residual stream.
                // Jitter is ±3/64 ≈ ±5% on fraction to break perfect cancel.
                1: begin
                    cls_r     = 2'd1;
                    op_sel    = 2'b01;   // SUB
                    e_jitter  = 6'(29 + (cyc_local % 7));   // range 29..35
                    op_a = W2_BASE;
                    op_b = {1'b0, 6'd32, e_jitter};
                end

                // ── W3: Boundary oscillation — CLASS_C ───────────────────
                // 4-phase cycle targeting E=14, E=16, E=47, E=48.
                // Forces continuous boundary-cliff exposure.
                2: begin
                    cls_r  = 2'd2;
                    case (cyc_local % 4)
                        2'd0: begin   // ADD at E=14 (COLLAPSE)
                            op_a = W3_COLL; op_b = W3_COLL; op_sel = 2'b00;
                        end
                        2'd1: begin   // MUL at E=16 (TRANSITION lo)
                            op_a = W3_TLO;  op_b = W3_TLO;  op_sel = 2'b10;
                        end
                        2'd2: begin   // ADD at E=47 (TRANSITION hi)
                            op_a = W3_THI;  op_b = W3_THI;  op_sel = 2'b00;
                        end
                        2'd3: begin   // SUB at E=48 (SATURATION)
                            op_a = W3_SAT;  op_b = W3_THI;  op_sel = 2'b01;
                        end
                    endcase
                end

                // ── W4: Deep transformer chain — CLASS_D ──────────────────
                // MUL→ADD→SUB→MUL with result feedback as operand.
                // Models layered inference (conv + residual + norm + scale).
                3: begin
                    cls_r  = 2'd3;
                    case (cyc_local % 4)
                        2'd0: begin   // MUL weight
                            op_a = w4_feedback; op_b = W4_WGT; op_sel = 2'b10;
                        end
                        2'd1: begin   // ADD bias
                            op_a = w4_feedback; op_b = W4_BIAS; op_sel = 2'b00;
                        end
                        2'd2: begin   // SUB normalization
                            op_a = w4_feedback; op_b = W4_BIAS; op_sel = 2'b01;
                        end
                        2'd3: begin   // MUL scale-back
                            op_a = w4_feedback; op_b = W4_WGT; op_sel = 2'b10;
                        end
                    endcase
                end

                // ── W5: Saturation spike injection — CLASS_A ──────────────
                // 10% max-TRANSITION spikes via ADD (triggers Thoth Rollover
                // → E=48 SATURATION); 90% low-energy noise.
                default: begin
                    cls_r  = 2'd0;
                    op_sel = 2'b00;  // ADD
                    if ((cyc_local % 10) == 0) begin
                        op_a = W5_SPIKE;  // 10% saturation spike
                        op_b = W5_SPIKE;
                    end else begin
                        op_a = W5_NOISE;  // 90% noise floor
                        op_b = W5_NOISE;
                    end
                end

            endcase

            // ── C4 kernel: compute mode_tag ───────────────────────────────
            e_in_r   = op_a[11:6];
            mode_tag = c4_mode(cls_r, e_in_r, depth_cnt[7:0]);

            // ── accum_en: disable for CLASS_C, COLLAPSE, SATURATION, DG ──
            if (cls_r    == 2'd2             ||   // CLASS_C never accumulates
                depth_cnt > EPOCH_DEPTH      ||   // depth override
                classify(e_in_r) == 2'd0     ||   // COLLAPSE routing
                classify(e_in_r) == 2'd3)         // SATURATION routing
                accum_en = 1'b0;
            else
                accum_en = 1'b1;

            @(posedge clk); #1;

            // ── Update W4 feedback ────────────────────────────────────────
            if (wid == 3) w4_feedback = result;

            // ── CSV logging ───────────────────────────────────────────────
            $fwrite(fd, "%0d,W%0d,", cyc, wid + 1);

            // class
            case (cls_r)
                2'd0: $fwrite(fd, "A,");
                2'd1: $fwrite(fd, "B,");
                2'd2: $fwrite(fd, "C,");
                2'd3: $fwrite(fd, "D,");
            endcase

            // E (result exponent), depth, op
            $fwrite(fd, "%0d,%0d,", result[11:6], depth_cnt);

            case (op_sel)
                2'b00: $fwrite(fd, "ADD,");
                2'b01: $fwrite(fd, "SUB,");
                2'b10: $fwrite(fd, "MUL,");
                2'b11: $fwrite(fd, "NOP,");
            endcase

            // mode (as decimal), result (hex), accum (decimal)
            $fwrite(fd, "%0d,%0h,%0d,", mode_tag, result, accum_out);

            // region of result
            case (classify(result[11:6]))
                2'd0: $fwrite(fd, "COLLAPSE,");
                2'd1: $fwrite(fd, "TRANSITION,");
                2'd2: $fwrite(fd, "STABLE,");
                2'd3: $fwrite(fd, "SATURATE,");
            endcase

            // UF, OVF
            $fwrite(fd, "%0d,%0d\n", underflow_flag, exp_ovf_flag);

            // increment depth (reset on next iteration if needed)
            depth_cnt = depth_cnt + 1;
        end

        $fclose(fd);
        $display("  %0d cycles logged to HBS_C6_REAL_WORLD.csv", TOTAL_CYCLES);
        $display("============================================================");
        $display("");
        $finish;
    end

endmodule
