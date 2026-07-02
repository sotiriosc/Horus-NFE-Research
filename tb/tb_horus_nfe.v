`timescale 1ns / 1ps

module tb_horus_nfe;

    // =========================================================================
    // Signal declarations — widths match horus_nfe port definitions exactly
    // =========================================================================

    // Inputs to DUT: declared as reg (driven by testbench)
    reg         clk;
    reg         rst_n;
    reg  [12:0] op_a;        // was "A" — renamed to match module port
    reg  [12:0] op_b;        // was "B" — renamed to match module port
    reg  [1:0]  op_sel;      // was missing — must be 2'b10 for MUL
    reg         accum_en;    // was missing — tie low for these tests
    reg         accum_clr;   // was missing — tie low for these tests

    // Outputs from DUT: declared as wire (driven by module)
    wire [12:0] result;          // was "Result" — renamed to match module port
    wire [31:0] accum_out;       // was missing
    wire        rollover_flag;   // was missing
    wire        underflow_flag;  // was missing
    wire        exp_ovf_flag;    // was missing

    // =========================================================================
    // DUT instantiation — every port name matches horus_nfe EXACTLY
    // =========================================================================
    horus_nfe uut (
        .clk           (clk),
        .rst_n         (rst_n),
        .op_a          (op_a),
        .op_b          (op_b),
        .op_sel        (op_sel),
        .accum_en      (accum_en),
        .accum_clr     (accum_clr),
        .result        (result),
        .accum_out     (accum_out),
        .rollover_flag (rollover_flag),
        .underflow_flag(underflow_flag),
        .exp_ovf_flag  (exp_ovf_flag)
    );

    // =========================================================================
    // 100 MHz clock — required because horus_nfe is a synchronous module;
    // 'result' is a registered output that only updates on posedge clk.
    // Without a clock the output stays at X regardless of input values.
    // =========================================================================
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 10 ns period = 100 MHz

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin

        // Initialise all inputs before releasing reset
        rst_n     = 1'b0;
        op_a      = 13'd0;
        op_b      = 13'd0;
        op_sel    = 2'b10;   // MUL — fixed for both test cases
        accum_en  = 1'b0;
        accum_clr = 1'b0;

        // Hold reset for 4 cycles then release
        repeat(4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        // ── Biased-exponent encoding reminder ─────────────────────────────────────
        // actual_E = stored_E − 32.  To represent a value with actual_E = 0 (i.e.
        // 2^0 = 1.0 scale), store E = 0 + 32 = 32  (6'b100000).
        // Expected output E values therefore shift by +32 vs. the unbiased format.
        // ─────────────────────────────────────────────────────────────────────────

        // --- TEST CASE 1: 1.5 × 1.5 = 2.25 ---
        // 1.5 = 2^0 × (1 + 32/64):  actual_E=0  → stored_E=32  → 0_100000_100000
        // Expected: 2.25 = 2^1 × (1 + 8/64):   actual_E=1  → stored_E=33, f=8
        @(negedge clk);
        op_a = 13'b0_100000_100000;   // E_stored=32, f=32 → 1.5
        op_b = 13'b0_100000_100000;
        @(posedge clk); #1;
        $display("Test 1.5*1.5: Result E=%d (stored), f=%d  (Expected E=33, f=8  → 2.25)",
                 result[11:6], result[5:0]);

        // --- TEST CASE 2: 1.984375 × 1.984375 ≈ 3.9375 ---
        // 1.984375 = 2^0 × (1 + 63/64): stored_E=32 → 0_100000_111111
        // Expected: stored_E=33, f=62  → 2^1 × (1 + 62/64) ≈ 3.9375
        @(negedge clk);
        op_a = 13'b0_100000_111111;   // E_stored=32, f=63 → 1.984375
        op_b = 13'b0_100000_111111;
        @(posedge clk); #1;
        $display("Test Max:   Result E=%d (stored), f=%d  (Expected E=33, f=62 → ≈3.9375)",
                 result[11:6], result[5:0]);

        // --- TEST CASE 3: Underflow — product below 2^(−32) ---
        // E_stored=0 × E_stored=0: exp_sum = 0+0−32 → 8-bit wrap → underflow_flag
        @(negedge clk);
        op_a     = 13'b0_000000_000000;   // E_stored=0, f=0 → 2^(−32) × 1.0
        op_b     = 13'b0_000000_000000;
        op_sel   = 2'b10;                  // MUL
        @(posedge clk); #1;
        $display("Test UF:    Result=%0h  underflow=%b  (Expected underflow=1)",
                 result, underflow_flag);

        // --- TEST CASE 4: SUB Guard-B 2-cycle pipeline (LayerNorm Cascade fix) ---
        //
        // 1.5 − 0.75 = 0.75  (borrow path: f_a=32 < Δ=48, so Guard-B fires)
        //   op_a: 1.5  = 2^0 × (1 + 32/64):  E_stored=32, f=32 → 0_100000_100000
        //   op_b:         Δ = 48/64           f=48           → 0_000000_110000
        //
        //   Stage-1 (Cycle A): mant_sum = 64+32-48 = 48 → bits[5]=1 → norm_shift=1
        //     norm_mant = 48 << 1 = 96 = 0b1100000 → frac = 96[5:0] = 32
        //     e_a−1 = 32−1 = 31  FTZ? 32 > 1 → no
        //   Stage-2 (Cycle B, after NOP): e_final = 31−1 = 30, f=32
        //     result = {0, 30, 32} = 0_011110_100000
        //     Decoded: 2^(30−32) × (1+32/64) = 2^(−2) × 1.5 = 0.375
        //
        //   Wait — let me recalculate. 1.5 - 0.75 = 0.75
        //   0.75 = 2^(−1) × 1.5 = 2^(actual_E=−1) × 1.5
        //   stored_E = −1 + 32 = 31, f=32
        //   result = {0, 31, 32} = 0_011111_100000
        //
        //   Re-check Stage computation:
        //     norm_mant[5:0] = 96[5:0] = 96 & 63 = 32 ✓
        //     e_pre = e_a − 1 = 32−1 = 31
        //     e_final = e_pre − norm_shift = 31 − 1 = 30  ← stored E=30, actual_E=−2
        //
        //   Hmm: stored_E=30 → actual_E=30-32=−2, value=2^(−2)×1.5=0.375, NOT 0.75.
        //   Let's pick a simpler example that hits Guard-B without norm_shift ambiguity:
        //   Use 1.5 - 0.03125 (Δ=2/64):
        //   m_a=32, Δ=2 → m_a >= Δ → Guard-A (not Guard-B!)
        //   Need m_a < Δ. Try:
        //   op_a: E_stored=32, f=2 (value=2^0×(1+2/64)=1.03125)
        //   op_b:              Δ=48  (raw delta 48/64)
        //   m_a=2 < Δ=48 → Guard-B
        //   mant_sum = 64+2-48 = 18 = 0b010010, bits[4]=1 → norm_shift=2
        //   norm_mant = 18<<2 = 72 = 0b1001000 → frac = 72[5:0] = 8
        //   e_pre = 32-1 = 31
        //   FTZ? 32 > 2 → no
        //   e_final = 31-2 = 29, frac=8
        //   result = {0, 29, 8} = 0_011101_001000
        //   Decoded: 2^(29-32)×(1+8/64) = 2^(−3)×1.125 = 1.125/8 ≈ 0.140625
        //
        //   Direct check: 1.03125 - 48/64 = 1.03125 - 0.75 = 0.28125
        //   0.28125 = 2^(−2)×(1+1/64)×... let me recompute.
        //   Actually: result should be (1 + f_a/64 - Δ/64) × 2^actual_E_a
        //   = (1 + 2/64 - 48/64) × 2^0 = (64+2-48)/64 × 1 = 18/64 × 1
        //   But 18/64 < 1 — the hidden bit is missing! That's WHY we borrow:
        //   = 2^(−1) × (18/32) = 2^(−1) × (1 + (18-16)/16)... hmm.
        //   Let me think properly:
        //   raw = 64+2-48 = 18. After shift by 2: 18×4=72. hidden-1 at bit[6]=1.
        //   f_result = 72[5:0] = 8.
        //   actual_E_result = actual_E_a - 1 - norm_shift = 0 - 1 - 2 = -3
        //   stored_E_result = -3 + 32 = 29
        //   Value = 2^(−3) × (1+8/64) = 0.125 × 1.125 = 0.140625
        //   
        //   Cross-check: 1.03125 − 0.75 = 0.28125 ≠ 0.140625 ← WRONG
        //   The delta Δ is applied WITHOUT its own 2^E scale — it's a raw fraction.
        //   So op_b=48 means subtract 48/64 = 0.75 from op_a's mantissa fraction.
        //   1.03125 − 0.75 = 0.28125 = 2^(actual_E_result) × (1 + f/64)
        //   Closest: actual_E=-2, value=2^(-2)×1.125=0.28125? → 0.25×1.125=0.28125 ✓
        //   stored_E = -2+32 = 30, f = 8 ← expected
        //
        //   So my computation above has a mistake. Let me redo:
        //   raw = 18, norm_shift = ?
        //   mant_sum[5]=0 (18=0b010010), mant_sum[4]=1 → norm_shift=2
        //   norm_mant = 18<<2 = 72 = 0b1001000
        //   norm_mant[5:0] = 001000 = 8 ✓
        //   e_pre = 32-1 = 31
        //   e_final = 31 - norm_shift = 31 - 2 = 29
        //   stored_E = 29, actual_E = 29-32 = -3
        //   Value = 2^(-3) × 1.125 = 0.140625 ≠ 0.28125
        //
        //   There's a discrepancy. The issue: after borrow, we borrowed 1 unit of E
        //   (2^actual_E_a = 2^0), giving 64 extra mantissa units. So:
        //   op_a value = 2^0 × (1 + 2/64) = 1 + 2/64
        //   After borrow: mantissa = (1 + 2/64) × 2 - (48/64) = ... no, this isn't right.
        //   The operation is: f_a - Δ in fractional context:
        //   raw = f_a + 64 - Δ = 2 + 64 - 48 = 18
        //   In fractional context: 18 represents (18/64) of the 2^(e_a-1) scale
        //   = 2^(e_a-1) × (18/64)  — but this isn't normalized (18/64 < 1)
        //   Normalizing: 18/64 = 2^(-k) × (18×2^k/64) where 18×2^k ∈ [64, 128)
        //   k=2: 18×4=72 ∈ [64,128) ✓
        //   So normalized: 2^(e_a-1) × 2^(-2) × (72/64)
        //   = 2^(e_a-3) × (1 + 8/64)
        //   = 2^(0-3) × 1.125 = 0.140625
        //
        //   But we wanted 1.03125 - 0.75 = 0.28125!
        //   The inconsistency: SUB_FRAC subtracts Δ from the FRACTIONAL PART ONLY,
        //   NOT from the full value. So: result = (1 + f_a/64 - Δ/64) × 2^actual_E_a
        //   = (1 + 2/64 - 48/64) × 2^0 = 18/64 × 1
        //   After borrowing: = (18/64) × 1 = 2^(-actual_E_a_adj) × ... = hardware does
        //   normalize this as 2^(-3) × 1.125 = 0.140625 ✓ mathematically correct.
        //
        //   Correct expected: stored_E=29, f=8 → 2^(-3)×1.125 = 0.140625
        //   (Note: the SUB_FRAC contract subtracts raw fraction, not a full NFE value)
        // ─────────────────────────────────────────────────────────────────────

        // Cycle A: issue Guard-B SUB (borrow path) → Stage-1 registers
        @(negedge clk);
        op_a   = 13'b0_100000_000010;  // E_stored=32, f=2  → 2^0 × 1.03125
        op_b   = 13'b0_000000_110000;  // raw Δ = 48
        op_sel = 2'b01;                 // SUB_FRAC
        @(posedge clk); #1;
        $display("SUB G-B Cy1: sub_p1_armed (check only — result NOT valid yet)");

        // Cycle B: NOP bubble — Stage-2 fires, writes result
        @(negedge clk);
        op_a   = 13'd0;
        op_b   = 13'd0;
        op_sel = 2'b11;                 // NOP
        @(posedge clk); #1;
        $display("SUB G-B Cy2: Result={S=%b E=%0d(stored) f=%0d}  (Expected E=30, f=8 → 2^-2×1.125=0.28125)",
                 result[12], result[11:6], result[5:0]);

        $finish;
    end

endmodule
