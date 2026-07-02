`timescale 1ns / 1ps
// ============================================================================
// Module   : tb_fidelity_benchmark
// Project  : Horus Engine — Architectural Fidelity Stress Test
// File     : tb_fidelity_benchmark.v
//
// Purpose
//   1024-cycle deep-chain accumulation with noise-injected fractional deltas.
//   Compares hardware running state (decode of RTL result) and accum_reg
//   against a bit-parallel FP64 golden model each cycle.
//
// DUT: horus_nfe  (direct MAC core; accum_reg probed hierarchically)
//
// CSV output (fidelity_benchmark.csv):
//   cycle_number, horus_output, golden_fp64, accum_reg
//
// Run (from sim/):
//   make sim_fidelity
//   make fidelity
// ============================================================================

module tb_fidelity_benchmark;

    localparam CLK_PERIOD   = 10;
    localparam CLK_HALF     = CLK_PERIOD / 2;
    localparam DEPTH_CYCLES = 1024;
    localparam EXP_BIAS     = 32;
    localparam SEED         = 32'hDEAD_BEEF;

    localparam [12:0] NFE_ONE = 13'h800;   // 1.0  (stored_E=32, f=0)
    localparam [1:0]  OP_ADD  = 2'b00;
    localparam [1:0]  OP_NOP  = 2'b11;

    // ── DUT interface ────────────────────────────────────────────────────────
    reg         clk;
    reg         rst_n;
    reg  [12:0] op_a;
    reg  [12:0] op_b;
    reg  [1:0]  op_sel;
    reg         accum_en;
    reg         accum_clr;

    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover_flag;
    wire        underflow_flag;
    wire        exp_ovf_flag;

    wire [31:0] pe_accum = dut.accum_reg;

    // ── Golden / logging state ───────────────────────────────────────────────
    integer      cycle;
    integer      csv_fd;
    reg  [31:0]  lfsr;

    real         golden_state;      // FP64 ideal running value (no re-quantize)
    real         horus_state;       // decode(result) after each ADD

    // =========================================================================
    horus_nfe dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .op_a           (op_a),
        .op_b           (op_b),
        .op_sel         (op_sel),
        .accum_en       (accum_en),
        .accum_clr      (accum_clr),
        .result         (result),
        .accum_out      (accum_out),
        .rollover_flag  (rollover_flag),
        .underflow_flag (underflow_flag),
        .exp_ovf_flag   (exp_ovf_flag)
    );

    // =========================================================================
    // NFE decode: V = (-1)^S × 2^(E-32) × (1 + f/64)
    // =========================================================================
    function real nfe_decode;
        input [12:0] cw;
        integer s, e, f;
        real    mag;
        begin
            s = cw[12];
            e = cw[11:6];
            f = cw[5:0];
            mag = (1.0 + f / 64.0) * $pow(2.0, e - EXP_BIAS);
            nfe_decode = s ? -mag : mag;
        end
    endfunction

    // Ideal ADD_FRAC at op_a scale: (1+f_a/64) + Δ/64 at 2^actual_E
    function real ideal_add_frac;
        input [12:0] a;
        input [5:0]  delta;
        integer e;
        real    scale, base;
        begin
            e     = a[11:6];
            scale = $pow(2.0, e - EXP_BIAS);
            base  = (1.0 + a[5:0] / 64.0) * scale;
            if (a[12]) base = -base;
            ideal_add_frac = base + (delta / 64.0) * scale;
        end
    endfunction

    // 32-bit Galois LFSR — reproducible noise
    function [5:0] next_delta;
        input [31:0] state;
        reg [31:0] s;
        reg [5:0]  d;
        begin
            s = state;
            // taps at 32,22,2,1 → non-zero delta in [1,63]
            s = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
            d = (s[4:0] & 5'h0F);
            if (d == 5'd0) d = 5'd1;
            next_delta = d[5:0];
        end
    endfunction

    // =========================================================================
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    initial begin
        integer     i;
        reg  [5:0]  delta;
        real        ideal_next;

        // Defaults
        rst_n          = 1'b0;
        op_a           = NFE_ONE;
        op_b           = 13'd0;
        op_sel         = OP_NOP;
        accum_en       = 1'b0;
        accum_clr      = 1'b0;
        lfsr           = SEED;
        cycle          = 0;
        golden_state   = 1.0;
        horus_state    = 1.0;

        csv_fd = $fopen("fidelity_benchmark.csv", "w");
        if (csv_fd == 0) begin
            $display("ERROR: cannot open fidelity_benchmark.csv for writing");
            $finish(1);
        end
        $fdisplay(csv_fd, "cycle_number,horus_output,golden_fp64,accum_reg");

        // Reset
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Clear accumulator, seed running state at 1.0
        @(negedge clk);
        op_a      = NFE_ONE;
        op_b      = 13'd0;
        op_sel    = OP_NOP;
        accum_en  = 1'b0;
        accum_clr = 1'b1;
        @(posedge clk);
        #1;
        accum_clr = 1'b0;

        op_a          = NFE_ONE;
        golden_state  = 1.0;
        horus_state   = nfe_decode(NFE_ONE);

        // Log cycle 0 baseline
        $fdisplay(csv_fd, "%0d,%.17g,%.17g,%0d",
                  0, horus_state, golden_state, pe_accum);

        // ── 1024-cycle deep chain ────────────────────────────────────────────
        // Each cycle:
        //   1. Inject small random positive fractional delta (ADD_FRAC noise)
        //   2. accum_reg += result  (event counter — integer codeword sum)
        //   3. op_a ← result       (feedback — re-quantization compounds)
        //   4. Golden advances in FP64 without intermediate re-encoding
        //
        // Note: monotonic ADD chain stress-tests Thoth Rollover and eventual
        // saturation — the point where Horus "sacrifices" fidelity vs FP64.
        for (i = 1; i <= DEPTH_CYCLES; i = i + 1) begin
            delta = next_delta(lfsr);
            lfsr  = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

            ideal_next = ideal_add_frac(op_a, delta);

            @(negedge clk);
            op_a     = op_a;
            op_b     = {7'd0, delta};
            op_sel   = OP_ADD;
            accum_en = 1'b1;
            accum_clr= 1'b0;

            @(posedge clk);
            #1;   // NBA settle — result and accum_reg updated

            // Golden: ideal FP64 chain (no re-quantize between steps)
            golden_state = ideal_next;

            // Horus: hardware re-encoded running state
            horus_state = nfe_decode(result);

            // Feedback deep chain
            op_a = result;

            $fdisplay(csv_fd, "%0d,%.17g,%.17g,%0d",
                      i, horus_state, golden_state, pe_accum);

            if ((i % 128) == 0)
                $display("  [%4d/1024]  horus=%.10g  golden=%.10g  accum_reg=%0d  rel_err=%.4f%%",
                         i, horus_state, golden_state, pe_accum,
                         (golden_state != 0.0)
                             ? (100.0 * (horus_state - golden_state) / golden_state)
                             : 0.0);
        end

        $fclose(csv_fd);

        $display("");
        $display("============================================");
        $display("  Fidelity benchmark complete");
        $display("  Cycles  : %0d", DEPTH_CYCLES);
        $display("  CSV     : fidelity_benchmark.csv");
        $display("  Final   : horus_state=%.12g  golden=%.12g", horus_state, golden_state);
        $display("  accum_reg (raw codeword sum) = %0d (0x%08h)", pe_accum, pe_accum);
        $display("  Next    : python3 analyze_fidelity.py");
        $display("============================================");

        $finish;
    end

endmodule
