`timescale 1ns/1ps
// ============================================================================
// Module   : tb_hbs_c23_observer_decoupling
// Project  : HORUS v3 — HBS-C23: Observer-Decoupling Falsification Suite
//
// Purpose  : Determine whether HORUS v3 attractors (A1–A4) are INTRINSIC
//            dynamical properties of the computation, or COORDINATE ARTIFACTS
//            of the specific E-field extraction convention result[11:6].
//
// Strategy : Run a single DUT continuously (6,000 cycles).  At every cycle
//            apply ALL FOUR observer transforms simultaneously and log each
//            transform's attractor classification alongside the ground truth.
//
// HARD CONSTRAINTS:
//   1. Real HORUS RTL — no ALU or accumulator modifications.
//   2. All 4 transforms are EXTERNAL OBSERVATION TRANSFORMS only.
//   3. The DUT never "sees" any transform — its internal state is untouched.
//
// Four Observer Transforms (applied simultaneously every cycle):
// ──────────────────────────────────────────────────────────────
//
// GROUND TRUTH (E_obs — standard):
//   E_obs = result[11:6]
//   classify(E_obs) → attr_std (A1–A4)
//
// R1 — E-field Desynchronization:
//   E_alt = result[9:4] XOR result[12:7]   (two overlapping 6-bit windows XOR'd)
//   Adapted from spec's result[9:4]^result[15:10] for 13-bit NFE word.
//   Mixes E-field, f-field and sign bits in the 6-bit E-observer field.
//
// R2 — Nonlinear Re-Embedding:
//   E_r2 = popcount(result[12:0] XOR accum_reg[12:0])   [range: 0–13]
//   Operates in Hamming-distance space between NFE output and accumulator.
//   Attractor thresholds adapted: A1=0, A2≥12, A3=13, A4=1–11.
//
// R3 — Time-Scrambled Observation (1-cycle lag):
//   E_r3(t) = result(t-1)[11:6]   (one register delay)
//   Tests whether lagged observation preserves attractor identity.
//   KEY INVARIANT CHECK: A3 (E=63) → should observe A2 (E=62) with 1-cycle lag.
//
// R4 — Epoch-Varying Basis Rotation (Hard Test):
//   x' = rotl13(result, rot_k) XOR epoch_mask
//   E_r4 = x'[11:6]
//   rot_k cycles through (0, 3, 6, 9, 12, 2, 5, 8, 11, 1, 4, 7, 10) — all 13
//   rotations in turn, via step +3 mod 13 (coprime to 13).
//   epoch_mask is a 15-bit LFSR-driven 13-bit XOR mask, updated every 16 cycles.
//
// Attractor Classification (standard E-field):
//   A1: E == 0            (cancellation residual absorption)
//   A2: 50 ≤ E < 63       (geometric exponent explosion approach)
//   A3: E == 63           (Thoth rollover boundary)
//   A4: 1 ≤ E < 50        (entropic mid-range)
//
// Attractor Classification (R2 popcount proxy):
//   A1_pop: popcount == 0  (zero Hamming distance — identical bits)
//   A2_pop: popcount >= 12 (near-maximum Hamming distance)
//   A3_pop: popcount == 13 (maximum Hamming distance — all bits flipped)
//   A4_pop: 1 ≤ popcount ≤ 11 (mid-range Hamming distance)
//
// CSV columns (logged each of the 6,000 cycles):
//   cycle, e_sweep,
//   e_obs, attr_std,                              // Ground truth (standard)
//   e_alt, attr_r1, r1_disagree,                  // R1: desync
//   pop_xor, attr_r2, r2_disagree,                // R2: nonlinear
//   e_lag, attr_r3, r3_disagree,                  // R3: lagged
//   e_r4, attr_r4, r4_disagree, rot_k, epoch_mask // R4: rotation
//
// PASS / FAIL CONDITIONS (as per spec):
//   MODEL HOLDS:  all 4 transforms show <5% cross-regime disagreement
//   MODEL BREAKS: any of —
//     • Attractor identity changes under R2 or R4 (distribution shift)
//     • MI drops to ~0 under nonlinear embedding (R2)
//     • A3 ceases to be invariant under lagged observation (R3)
//     • A1/A2 swap identity under basis rotation (R4)
// ============================================================================

module tb_hbs_c23_observer_decoupling;

    // ── Constants ─────────────────────────────────────────────────────────
    localparam OP_ADD        = 2'b00;
    localparam MODE_STANDARD = 3'b000;
    localparam [12:0] FIXED_OP_B = {1'b0, 6'd0, 6'd8};  // small addend
    localparam TOTAL_CYCLES  = 6000;
    localparam EPOCH_LEN     = 16;    // R4: rotation changes every epoch

    // ── Clock / Reset ─────────────────────────────────────────────────────
    reg clk, rst_n;
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // ── Data LFSR (16-bit, resets on rst_n): f-field variation ────────────
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    end

    // ── E-field sweep ─────────────────────────────────────────────────────
    reg [5:0] e_sweep;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) e_sweep <= 6'd0;
        else        e_sweep <= e_sweep + 6'd1;
    end

    // ── Epoch LFSR (15-bit, free-running): R4 epoch mask ─────────────────
    reg [14:0] epoch_lfsr;
    initial epoch_lfsr = 15'h5A3F;
    always @(posedge clk) begin
        epoch_lfsr <= {epoch_lfsr[13:0], epoch_lfsr[0] ^ epoch_lfsr[2]};
    end

    // ── R4: Epoch counter + rotation amount + epoch mask ─────────────────
    reg  [3:0]  epoch_cnt;    // 0..15 within each epoch
    reg  [3:0]  rot_k;        // current rotation amount (0–12)
    reg  [12:0] epoch_mask;   // epoch-specific XOR mask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            epoch_cnt  <= 4'd0;
            rot_k      <= 4'd0;     // first epoch: identity rotation
            epoch_mask <= 13'h0000;
        end else begin
            if (epoch_cnt == EPOCH_LEN-1) begin
                epoch_cnt  <= 4'd0;
                // Step +3 mod 13 cycles through all 13 distinct rotations
                rot_k     <= (rot_k + 4'd3 >= 4'd13) ?
                             (rot_k + 4'd3 - 4'd13) : (rot_k + 4'd3);
                epoch_mask <= epoch_lfsr[12:0];
            end else begin
                epoch_cnt <= epoch_cnt + 4'd1;
            end
        end
    end

    // ── DUT ───────────────────────────────────────────────────────────────
    reg  [12:0] op_a;
    wire [12:0] result;
    wire [31:0] accum_out;
    wire        rollover, uf, ovf, accum_full;
    wire [15:0] op_count;
    reg         accum_en, accum_clr;

    horus_system dut (
        .clk(clk), .rst_n(rst_n),
        .op_a(op_a), .op_b(FIXED_OP_B), .op_sel(OP_ADD),
        .mode_tag(MODE_STANDARD),
        .accum_en(accum_en), .accum_clr(accum_clr),
        .host_tile_depth(6'd63),
        .result(result), .accum_out(accum_out),
        .rollover_flag(rollover), .underflow_flag(uf),
        .exp_ovf_flag(ovf), .op_count(op_count), .accum_full(accum_full)
    );

    // ── Internal probes ───────────────────────────────────────────────────
    wire [31:0] p_accum_reg = dut.u_nfe.accum_reg;

    // ═══════════════════════════════════════════════════════════════════════
    // OBSERVER TRANSFORMS
    // ═══════════════════════════════════════════════════════════════════════

    // Ground truth: standard E-field extraction
    wire [5:0] e_obs = result[11:6];

    // ── R1: E-field Desynchronization ─────────────────────────────────────
    // Spec: E_alt = result[9:4] XOR result[15:10]  (adapted for 13-bit word)
    // Adapted: E_alt = result[9:4] XOR result[12:7]  (two 6-bit overlapping windows)
    // This mixes:
    //   result[9:4]  = {E[3:0], f[5:4]}  — lower E bits + upper f bits
    //   result[12:7] = {sign, E[5:1]}    — sign + upper E bits
    wire [5:0] e_alt = result[9:4] ^ result[12:7];

    // ── R2: Nonlinear Re-Embedding (Hamming distance) ─────────────────────
    // E_r2 = popcount(result[12:0] XOR accum_reg[12:0])
    wire [12:0] xor_r2  = result[12:0] ^ p_accum_reg[12:0];
    wire [3:0]  pop_r2  = xor_r2[0] + xor_r2[1] + xor_r2[2] + xor_r2[3]
                        + xor_r2[4] + xor_r2[5] + xor_r2[6] + xor_r2[7]
                        + xor_r2[8] + xor_r2[9] + xor_r2[10]+ xor_r2[11]
                        + xor_r2[12];
    // popcount is in [0..13], use directly as attractor proxy

    // ── R3: Time-Scrambled Observation (1-cycle lag) ──────────────────────
    reg [12:0] result_lag1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) result_lag1 <= 13'd0;
        else        result_lag1 <= result;
    end
    wire [5:0] e_lag = result_lag1[11:6];

    // ── R4: Epoch-Varying Basis Rotation + XOR mask ───────────────────────
    // x' = rotl13(result, rot_k) XOR epoch_mask
    // E_r4 = x'[11:6]
    function automatic [12:0] rotl13;
        input [12:0] v;
        input [3:0]  k;
        reg [12:0] r;
        begin
            case (k)
                4'd0:  r = v;
                4'd1:  r = {v[11:0], v[12]};
                4'd2:  r = {v[10:0], v[12:11]};
                4'd3:  r = {v[9:0],  v[12:10]};
                4'd4:  r = {v[8:0],  v[12:9]};
                4'd5:  r = {v[7:0],  v[12:8]};
                4'd6:  r = {v[6:0],  v[12:7]};
                4'd7:  r = {v[5:0],  v[12:6]};
                4'd8:  r = {v[4:0],  v[12:5]};
                4'd9:  r = {v[3:0],  v[12:4]};
                4'd10: r = {v[2:0],  v[12:3]};
                4'd11: r = {v[1:0],  v[12:2]};
                4'd12: r = {v[0],    v[12:1]};
                default: r = v;
            endcase
            rotl13 = r;
        end
    endfunction

    wire [12:0] result_r4  = rotl13(result, rot_k) ^ epoch_mask;
    wire [5:0]  e_r4       = result_r4[11:6];

    // ═══════════════════════════════════════════════════════════════════════
    // ATTRACTOR CLASSIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    // Standard E-field classifier (A1–A4)
    function automatic [2:0] classify_e;
        input [5:0] e;
        begin
            if      (e == 6'd0)  classify_e = 3'd1;  // A1
            else if (e == 6'd63) classify_e = 3'd3;  // A3
            else if (e >= 6'd50) classify_e = 3'd2;  // A2
            else                 classify_e = 3'd4;  // A4
        end
    endfunction

    // R2: popcount-based proxy classifier (same semantic thresholds)
    function automatic [2:0] classify_pop;
        input [3:0] p;   // 0..13
        begin
            if      (p == 4'd0)  classify_pop = 3'd1;  // A1_pop: identical
            else if (p == 4'd13) classify_pop = 3'd3;  // A3_pop: maximal
            else if (p >= 4'd12) classify_pop = 3'd2;  // A2_pop: near-max
            else                 classify_pop = 3'd4;  // A4_pop: mid-range
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    // ATTRACTOR LABELS (combinational)
    // ═══════════════════════════════════════════════════════════════════════

    wire [2:0] attr_std  = classify_e(e_obs);      // Ground truth
    wire [2:0] attr_r1   = classify_e(e_alt);      // R1: desync
    wire [2:0] attr_r2   = classify_pop(pop_r2);   // R2: popcount
    wire [2:0] attr_r3   = classify_e(e_lag);      // R3: lag
    wire [2:0] attr_r4   = classify_e(e_r4);       // R4: rotation

    wire r1_disagree = (attr_std != attr_r1);
    wire r2_disagree = (attr_std != attr_r2);
    wire r3_disagree = (attr_std != attr_r3);
    wire r4_disagree = (attr_std != attr_r4);

    // ═══════════════════════════════════════════════════════════════════════
    // PREVIOUS CYCLE BUFFERS (for transition detection)
    // ═══════════════════════════════════════════════════════════════════════

    reg [2:0] prev_attr_std, prev_attr_r1, prev_attr_r2, prev_attr_r3, prev_attr_r4;

    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_attr_std <= 3'd4; prev_attr_r1 <= 3'd4;
            prev_attr_r2  <= 3'd4; prev_attr_r3 <= 3'd4;
            prev_attr_r4  <= 3'd4;
        end else begin
            prev_attr_std <= attr_std; prev_attr_r1 <= attr_r1;
            prev_attr_r2  <= attr_r2;  prev_attr_r3 <= attr_r3;
            prev_attr_r4  <= attr_r4;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // LOGGING
    // ═══════════════════════════════════════════════════════════════════════

    integer fd, c;

    task log_c23;
    begin : LOG_BLK
        reg ts, t1, t2, t3, t4;
        ts = (attr_std != prev_attr_std);
        t1 = (attr_r1  != prev_attr_r1);
        t2 = (attr_r2  != prev_attr_r2);
        t3 = (attr_r3  != prev_attr_r3);
        t4 = (attr_r4  != prev_attr_r4);

        $fwrite(fd, "%0d,%0d,", c, e_sweep);
        $fwrite(fd, "%0d,%0d,%0d,", e_obs, attr_std, ts);
        $fwrite(fd, "%0d,%0d,%0d,%0d,", e_alt, attr_r1, r1_disagree, t1);
        $fwrite(fd, "%0d,%0d,%0d,%0d,", pop_r2, attr_r2, r2_disagree, t2);
        $fwrite(fd, "%0d,%0d,%0d,%0d,", e_lag, attr_r3, r3_disagree, t3);
        $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d\n",
                e_r4, attr_r4, r4_disagree, t4, rot_k, epoch_mask);
    end
    endtask

    // ═══════════════════════════════════════════════════════════════════════
    // MAIN
    // ═══════════════════════════════════════════════════════════════════════

    initial begin : MAIN
        $display("HBS-C23: Observer-Decoupling Falsification Suite");
        $display("  R1=E_alt desync  R2=popcount  R3=lag  R4=rotation");
        $display("  6,000 cycles, all 4 transforms applied every cycle.");

        rst_n = 1'b0; op_a = 13'd0;
        accum_en = 1'b0; accum_clr = 1'b0;

        @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        accum_en = 1'b1;

        fd = $fopen("HBS_C23_OBSERVER_TRACE.csv", "w");
        $fwrite(fd, "cycle,e_sweep,");
        $fwrite(fd, "e_obs,attr_std,trans_std,");
        $fwrite(fd, "e_alt,attr_r1,r1_disagree,trans_r1,");
        $fwrite(fd, "pop_xor,attr_r2,r2_disagree,trans_r2,");
        $fwrite(fd, "e_lag,attr_r3,r3_disagree,trans_r3,");
        $fwrite(fd, "e_r4,attr_r4,r4_disagree,trans_r4,rot_k,epoch_mask\n");

        for (c = 0; c < TOTAL_CYCLES; c = c+1) begin
            accum_clr = ((c % 64) == 63) ? 1'b1 : 1'b0;
            op_a = {1'b0, e_sweep, lfsr[5:0]};
            @(posedge clk); #1;
            log_c23;
        end
        accum_clr = 1'b0;

        $fclose(fd);
        $display("  Done. 6,000 cycles logged to HBS_C23_OBSERVER_TRACE.csv");
        $finish;
    end

endmodule
