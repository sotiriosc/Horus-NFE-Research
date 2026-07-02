`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_boundary_stress
// Project  : Horus Engine — Boundary-Stress Simulation
// File     : tb_boundary_stress.v
//
// Purpose
//   Numerical edge-case stress test for horus_system (horus_nfe + pgate).
//   No RTL modifications — hierarchical probes read u_nfe.accum_reg and
//   top-level underflow_flag every clock cycle.
//
// DUT: horus_system  (single-tile PE wrapper; accum_reg ≡ pe_accum)
//
// Cases
//   1  UNDERFLOW  — operands / ops that force underflow floor
//   2  OVERFLOW   — operands that force exponent saturation (exp_ovf_flag)
//   3  MIXED ACC  — tiny MUL then large MUL into same accumulator
//
// Run (from sim/):
//   make sim_boundary && vvp sim_boundary
// ============================================================================

module tb_boundary_stress;

    localparam CLK_PERIOD = 10;
    localparam CLK_HALF   = CLK_PERIOD / 2;

    // ── v3 NFE canonical codewords (Bias-32, hidden bit) ─────────────────────
    localparam [12:0] NFE_MIN   = 13'h000;   // stored_E=0,f=0  → ~2.33e-10 (floor sentinel)
    localparam [12:0] NFE_ONE   = 13'h800;   // stored_E=32,f=0 → 1.0
    localparam [12:0] NFE_TINY  = 13'h582;   // ~0.001 (adversarial block encoding)
    localparam [12:0] NFE_LARGE = 13'h8D0;   // ~10.0
    localparam [12:0] NFE_MAX   = 13'hFFF;   // stored_E=63,f=63 → ~4.26e9

    localparam [1:0]  OP_ADD = 2'b00;
    localparam [1:0]  OP_SUB = 2'b01;
    localparam [1:0]  OP_MUL = 2'b10;
    localparam [1:0]  OP_NOP = 2'b11;

    // ── Stimulus ─────────────────────────────────────────────────────────────
    reg         clk;
    reg         rst_n;
    reg  [12:0] op_a;
    reg  [12:0] op_b;
    reg  [1:0]  op_sel;
    reg         accum_en;
    reg         accum_clr;
    reg  [5:0]  host_tile_depth;

    // ── DUT outputs ──────────────────────────────────────────────────────────
    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag;
    wire        underflow_flag;
    wire        exp_ovf_flag;
    wire [15:0] op_count;
    wire        accum_full;

    // ── Hierarchical probes (no RTL edit) ─────────────────────────────────────
    wire [31:0] pe_accum = dut.u_nfe.accum_reg;

    integer cycle;
    integer case_id;
    integer phase_id;

    // =========================================================================
    horus_system dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .op_a            (op_a),
        .op_b            (op_b),
        .op_sel          (op_sel),
        .accum_en        (accum_en),
        .accum_clr       (accum_clr),
        .host_tile_depth (host_tile_depth),
        .result          (result),
        .accum_out       (accum_out),
        .rollover_flag   (rollover_flag),
        .underflow_flag  (underflow_flag),
        .exp_ovf_flag    (exp_ovf_flag),
        .op_count        (op_count),
        .accum_full      (accum_full)
    );

    // =========================================================================
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // ── Per-cycle raw register dump ──────────────────────────────────────────
    always @(posedge clk) begin
        #1;   // NBA settle
        $display("CYCL %4d  CASE=%0d PHASE=%0d  op_a=0x%04h op_b=0x%04h sel=%b  result=0x%04h  pe_accum=0x%08h  accum_out=0x%08h  uf=%b ovf=%b rollover=%b  op_count=%0d",
                 cycle, case_id, phase_id,
                 op_a, op_b, op_sel,
                 result, pe_accum, accum_out,
                 underflow_flag, exp_ovf_flag, rollover_flag, op_count);
        cycle = cycle + 1;
    end

    // =========================================================================
    task drive_inputs;
        input [12:0] a;
        input [12:0] b;
        input [1:0]  sel;
        input        en;
        input        clr;
        begin
            @(negedge clk);
            op_a      = a;
            op_b      = b;
            op_sel    = sel;
            accum_en  = en;
            accum_clr = clr;
        end
    endtask

    task pulse_clr;
        begin
            drive_inputs(NFE_ONE, NFE_ONE, OP_NOP, 1'b0, 1'b1);
            @(posedge clk);
            drive_inputs(NFE_ONE, NFE_ONE, OP_NOP, 1'b0, 1'b0);
            @(posedge clk);
        end
    endtask

    task set_case;
        input integer id;
        input integer phase;
        begin
            case_id  = id;
            phase_id = phase;
        end
    endtask

    // =========================================================================
    initial begin : STIMULUS
        $dumpfile("boundary_stress.vcd");
        $dumpvars(0, tb_boundary_stress);

        cycle           = 0;
        case_id         = 0;
        phase_id        = 0;
        rst_n           = 1'b0;
        op_a            = 13'd0;
        op_b            = 13'd0;
        op_sel          = OP_NOP;
        accum_en        = 1'b0;
        accum_clr       = 1'b0;
        host_tile_depth = 6'd63;  // gate open (depth=0 CLOSES gate per pgate_ctrl RTL)

        $display("");
        $display("================================================================");
        $display("  HORUS BOUNDARY-STRESS SIMULATION");
        $display("  DUT: horus_system  |  pe_accum probe: dut.u_nfe.accum_reg");
        $display("================================================================");
        $display("  Format: v3 NFE  1s + 6 biased E + 6f  |  Bias=32  |  hidden 1.f");
        $display("  host_tile_depth=63 (gate open; depth=0 would CLOSE gate in pgate_ctrl)");
        $display("  PHASE key: C1 1=MUL min*min 2=MUL min*1.0 3=SUB E=0 4=SUB borrow");
        $display("             C2 1=MUL max*max 2=MUL max*1.0 3=MUL large*large");
        $display("             C3 1-3=tiny* tiny 4-5=large*large 6=tiny*large 7=NOP");
        $display("================================================================");
        $display("");

        // ── Reset ─────────────────────────────────────────────────────────────
        repeat(4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ==================================================================
        // CASE 1 — UNDERFLOW
        // ==================================================================
        $display("--- CASE 1: UNDERFLOW (inject / force below-format-floor behavior) ---");
        set_case(1, 1);   // UF: MUL floor x floor

        pulse_clr();

        // 1a: MUL(min × min) → exp_sum = 0+0−32 wraps → underflow floor
        drive_inputs(NFE_MIN, NFE_MIN, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);
        @(posedge clk);   // accum_out latency

        // 1b: MUL(min × one) — product still below representable range
        set_case(1, 2);   // UF: MUL floor x 1.0
        drive_inputs(NFE_MIN, NFE_ONE, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);
        @(posedge clk);

        // 1c: SUB Guard-A at minimum exponent, f_result → 0
        set_case(1, 3);   // UF: SUB Guard-A at E=0
        pulse_clr();
        drive_inputs(13'h001, 13'h001, OP_SUB, 1'b0, 1'b0);
        // op_a: stored_E=0,f=1 ; op_b delta m_b=1 → f_a>=m_b → f_result=0, e=0
        @(posedge clk);
        @(posedge clk);

        // 1d: SUB borrow at stored_E=0 → immediate floor
        set_case(1, 4);   // UF: SUB borrow at E=0
        pulse_clr();
        drive_inputs(13'h002, 13'h010, OP_SUB, 1'b0, 1'b0);
        // stored_E=0,f=2 ; delta m_b=16 > f_a → borrow, E=0 → floor
        @(posedge clk);
        @(posedge clk);

        // ==================================================================
        // CASE 2 — OVERFLOW
        // ==================================================================
        $display("");
        $display("--- CASE 2: OVERFLOW (inject above format max) ---");
        set_case(2, 1);   // OVF: MUL max x max

        pulse_clr();

        drive_inputs(NFE_MAX, NFE_MAX, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);
        @(posedge clk);

        set_case(2, 2);   // OVF: MUL max x 1.0
        drive_inputs(NFE_MAX, NFE_ONE, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);
        @(posedge clk);

        set_case(2, 3);   // OVF: MUL large x large
        drive_inputs(NFE_LARGE, NFE_LARGE, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);
        @(posedge clk);

        // ==================================================================
        // CASE 3 — MIXED ACCUMULATION (tiny + large)
        // ==================================================================
        $display("");
        $display("--- CASE 3: MIXED ACCUMULATION (tiny then large) ---");

        pulse_clr();
        accum_en = 1'b1;

        set_case(3, 1);   // MIX: tiny x tiny
        drive_inputs(NFE_TINY, NFE_TINY, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);

        set_case(3, 2);   // MIX: tiny x tiny #2
        drive_inputs(NFE_TINY, NFE_TINY, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);

        set_case(3, 3);   // MIX: tiny x tiny #3
        drive_inputs(NFE_TINY, NFE_TINY, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);

        set_case(3, 4);   // MIX: large x large
        drive_inputs(NFE_LARGE, NFE_LARGE, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);

        set_case(3, 5);   // MIX: large x large #2
        drive_inputs(NFE_LARGE, NFE_LARGE, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);

        set_case(3, 6);   // MIX: tiny x large
        drive_inputs(NFE_TINY, NFE_LARGE, OP_MUL, 1'b1, 1'b0);
        @(posedge clk);

        set_case(3, 7);   // MIX: NOP flush
        drive_inputs(NFE_ONE, NFE_ONE, OP_NOP, 1'b0, 1'b0);
        @(posedge clk);
        @(posedge clk);   // let accum_out catch accum_reg

        // ── Summary interpretation ───────────────────────────────────────────
        $display("");
        $display("================================================================");
        $display("  BOUNDARY-STRESS SUMMARY (observed in this simulation run)");
        $display("================================================================");
        $display("  CASE 1 UNDERFLOW:");
        $display("    MUL(floor x floor): expect result=0x000, uf=1 — FLOOR (not silent ghost)");
        $display("    SUB at E=0:         expect uf=1 when f_result hits minimum sentinel");
        $display("  CASE 2 OVERFLOW:");
        $display("    MUL(max x max):     expect result=0xFFF (saturate), exp_ovf_flag=1");
        $display("  CASE 3 MIXED ACC:");
        $display("    pe_accum sums raw 13-bit result words (zero-extended), not float values.");
        $display("    Inspect CYCL lines: does accum grow monotonically or reset on large op?");
        $display("================================================================");
        $display("  Final pe_accum=0x%08h  accum_out=0x%08h", pe_accum, accum_out);
        $display("  Waveform: boundary_stress.vcd");
        $display("================================================================");

        #20;
        $finish;
    end

endmodule
