// SPDX-License-Identifier: CERN-OHL-S-2.0
// =============================================================================
// Testbench : tb_horus_mesh_top
// DUT       : horus_mesh_top  (MESH_SIZE=2, FLIT_W=17, MESH_DIM=2)
//
//  2×2 tile grid layout:
//
//    West bdry                     East bdry
//    row 0 ──→  [Rtr|Sys](0,0) ──── [Rtr|Sys](0,1)
//                    │                    │
//    row 1 ──→  [Rtr|Sys](1,0) ──── [Rtr|Sys](1,1)
//
//  FLIT_W=17: [16:15]=dest_y [14:13]=dest_x [12:0]=13-bit NFE payload
//
// Tests
// ─────
//  T1: Flit → tile (0,1) — dest_x=1, dest_y=0, payload=13'h55A
//      Route: West→rtr(0,0) input buf (cycle 1)
//             rtr(0,0) routes East → e_out reg (cycle 2)
//             rtr(0,1) receives on w_in buf (cycle 3)
//             rtr(0,1) routes Local → l_out reg (cycle 4)
//      Verify: GEN_ROW[0].GEN_COL[1].loc_v = 1
//              GEN_ROW[0].GEN_COL[1].loc_d[12:0] = 13'h55A
//              GEN_ROW[0].GEN_COL[0].loc_v = 0  (not for this tile)
//
//  T2: Flit → tile (1,0) — dest_x=0, dest_y=1, payload=13'h2A7
//      Route: West→rtr(1,0) input buf (cycle 1)
//             rtr(1,0) receives on w_in, dest_x=0=TILE_X → routes South
//             rtr(1,0) s_out reg has the flit going down... wait.
//             Hmm: dest_x=0=MY_X for row-1-col-0, and dest_y=1=MY_Y(1)
//             → routes LOCAL immediately from row-1's West input!
//      Verify: GEN_ROW[1].GEN_COL[0].loc_v = 1
//
//  T3: MUL accumulation — inject op_a to tile (0,0), supply op_b via weight bus
//      dest_x=0, dest_y=0, payload=op_a (some NFE value)
//      op_b set via weight_flat[0*2+0 = 0]
//      op_sel=MUL, accum_en=1
//      Verify accum_out changes for tile (0,0)
// =============================================================================

`timescale 1ns / 1ps

module tb_horus_mesh_top;

    // ── DUT parameters ────────────────────────────────────────────────────────
    localparam MESH_SIZE = 2;
    localparam FLIT_W    = 17;
    localparam MESH_DIM  = 2;

    // Helper to build a flit
    function [FLIT_W-1:0] make_flit;
        input [MESH_DIM-1:0] dy;
        input [MESH_DIM-1:0] dx;
        input [12:0]         payload;
        begin
            make_flit = {dy, dx, payload};
        end
    endfunction

    // ── Clock and reset ───────────────────────────────────────────────────────
    reg clk, rst_n;
    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ── DUT ports ─────────────────────────────────────────────────────────────
    reg  [1:0]                           op_sel;
    reg                                  accum_en;
    reg                                  accum_clr;
    reg  [5:0]                           host_tile_depth;
    reg  [MESH_SIZE*MESH_SIZE*13-1:0]    weight_flat;
    reg  [MESH_SIZE*FLIT_W-1:0]          west_din_flat;
    reg  [MESH_SIZE-1:0]                 west_vin_flat;
    wire [MESH_SIZE-1:0]                 west_rin_flat;
    wire [MESH_SIZE*MESH_SIZE*13-1:0]    result_flat;
    wire [MESH_SIZE*MESH_SIZE*32-1:0]    accum_flat;

    // ── DUT ───────────────────────────────────────────────────────────────────
    horus_mesh_top #(
        .MESH_SIZE (MESH_SIZE),
        .FLIT_W    (FLIT_W),
        .MESH_DIM  (MESH_DIM)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .op_sel         (op_sel),
        .accum_en       (accum_en),
        .accum_clr      (accum_clr),
        .host_tile_depth(host_tile_depth),
        .weight_flat    (weight_flat),
        .west_din_flat  (west_din_flat),
        .west_vin_flat  (west_vin_flat),
        .west_rin_flat  (west_rin_flat),
        .result_flat    (result_flat),
        .accum_flat     (accum_flat)
    );

    // ── Hierarchical signal aliases for readability ───────────────────────────
    // Router (0,0) local port
    wire        r00_loc_v = dut.GEN_ROW[0].GEN_COL[0].loc_v;
    wire [FLIT_W-1:0] r00_loc_d = dut.GEN_ROW[0].GEN_COL[0].loc_d;
    // Router (0,1) local port
    wire        r01_loc_v = dut.GEN_ROW[0].GEN_COL[1].loc_v;
    wire [FLIT_W-1:0] r01_loc_d = dut.GEN_ROW[0].GEN_COL[1].loc_d;
    // Router (1,0) local port
    wire        r10_loc_v = dut.GEN_ROW[1].GEN_COL[0].loc_v;
    wire [FLIT_W-1:0] r10_loc_d = dut.GEN_ROW[1].GEN_COL[0].loc_d;
    // Router (1,1) local port
    wire        r11_loc_v = dut.GEN_ROW[1].GEN_COL[1].loc_v;

    // Accumulator outputs per tile (flattened)
    wire [31:0] acc_00 = accum_flat[ 0*32 +: 32];  // tile (0,0)
    wire [31:0] acc_01 = accum_flat[ 1*32 +: 32];  // tile (0,1)
    wire [31:0] acc_10 = accum_flat[ 2*32 +: 32];  // tile (1,0)
    wire [31:0] acc_11 = accum_flat[ 3*32 +: 32];  // tile (1,1)

    // ── VCD dump ──────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_horus_mesh_top.vcd");
        $dumpvars(0, tb_horus_mesh_top);
    end

    // ── Helpers ───────────────────────────────────────────────────────────────
    integer fail_count, pass_count;

    // Wait N posedges then settle
    task tick;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
            #1;
        end
    endtask

    // ── Main stimulus ─────────────────────────────────────────────────────────
    initial begin
        fail_count = 0;
        pass_count = 0;

        // Defaults
        op_sel         = 2'b11;  // NOP
        accum_en       = 1'b0;
        accum_clr      = 1'b0;
        host_tile_depth= 6'd0;   // unlimited
        weight_flat    = 0;
        west_din_flat  = 0;
        west_vin_flat  = 2'b00;

        // Reset
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;

        // =====================================================================
        // TEST 1: Flit routed to tile (0,1) via West boundary, row 0
        //   dest_y=0, dest_x=1, payload=13'h55A
        //   Path: West bdry → rtr(0,0) W-port → (route East) → rtr(0,1) W-port
        //         → (route Local) → l_dout=flit, l_vout=1
        //   Total 2-cycle hops × 2 routers = ~4 clock cycles
        // =====================================================================
        $display("\n[TEST 1] Flit to tile (0,1): West-row0 → E-passthrough → LOCAL");
        @(negedge clk);
        west_din_flat[0*FLIT_W +: FLIT_W] = make_flit(2'd0, 2'd1, 13'h55A);
        west_vin_flat[0] = 1'b1;
        @(posedge clk); #1;   // flit captured in rtr(0,0) West input buffer
        @(negedge clk);
        west_vin_flat[0] = 1'b0;
        west_din_flat[0*FLIT_W +: FLIT_W] = {FLIT_W{1'b0}};

        // Allow up to 6 cycles for flit to reach tile (0,1) local output
        begin : wait_t1
            integer i;
            for (i = 0; i < 6; i = i + 1) begin
                @(posedge clk); #1;
                if (r01_loc_v) i = 6; // early exit
            end
        end

        if (r01_loc_v && r01_loc_d[12:0] === 13'h55A) begin
            $display("  PASS: rtr(0,1) loc_v=1, payload=0x%03X (expect 0x55A)", r01_loc_d[12:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: rtr(0,1) loc_v=%0b loc_d[12:0]=0x%03X (expect 1, 0x55A)",
                     r01_loc_v, r01_loc_d[12:0]);
            fail_count = fail_count + 1;
        end

        if (!r00_loc_v) begin
            $display("  PASS: rtr(0,0) loc_v=0 (flit did not stop at wrong tile)");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: rtr(0,0) loc_v=%0b (should be 0 — flit mis-delivered)", r00_loc_v);
            fail_count = fail_count + 1;
        end

        repeat (4) @(posedge clk); #1;

        // =====================================================================
        // TEST 2: Flit routed to tile (1,0) via West boundary, row 1
        //   dest_y=1, dest_x=0, payload=13'h2A7
        //   Path: West bdry → rtr(1,0) W-port → dest_x=0=TILE_X, dest_y=1=TILE_Y
        //         → routes LOCAL directly (no East hop needed)
        //   Total: 2 cycles (1 for West input buffer, 1 for local output register)
        // =====================================================================
        $display("\n[TEST 2] Flit to tile (1,0): West-row1 → LOCAL (dest already matches)");
        @(negedge clk);
        west_din_flat[1*FLIT_W +: FLIT_W] = make_flit(2'd1, 2'd0, 13'h2A7);
        west_vin_flat[1] = 1'b1;
        @(posedge clk); #1;
        @(negedge clk);
        west_vin_flat[1] = 1'b0;
        west_din_flat[1*FLIT_W +: FLIT_W] = {FLIT_W{1'b0}};

        begin : wait_t2
            integer i;
            for (i = 0; i < 4; i = i + 1) begin
                @(posedge clk); #1;
                if (r10_loc_v) i = 4;
            end
        end

        if (r10_loc_v && r10_loc_d[12:0] === 13'h2A7) begin
            $display("  PASS: rtr(1,0) loc_v=1, payload=0x%03X (expect 0x2A7)", r10_loc_d[12:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: rtr(1,0) loc_v=%0b loc_d[12:0]=0x%03X (expect 1, 0x2A7)",
                     r10_loc_v, r10_loc_d[12:0]);
            fail_count = fail_count + 1;
        end

        repeat (4) @(posedge clk); #1;

        // =====================================================================
        // TEST 3: MUL accumulation at tile (0,0)
        //   Inject op_a=13'h0040 (E=32, f=0, value≈1.0 with bias-32)
        //   op_b=13'h0040  (same, ≈1.0)
        //   dest_x=0, dest_y=0 → local delivery to (0,0)
        //   op_sel=MUL (2'b10), accum_en=1
        //
        //   IMPORTANT: host_tile_depth must be non-zero.  With horus_pgate_ctrl,
        //   depth=0 means "gate permanently CLOSED" (verified by corner-case tests).
        //   Set depth=63 to allow up to 63 MACs before the tile budget is exhausted.
        //
        //   Expect: accum_out for tile (0,0) is non-zero after delivery
        // =====================================================================
        $display("\n[TEST 3] MUL accumulation at tile (0,0) — verify accum_out changes");
        // NFE encoding of 1.0 under Bias-32:
        //   stored_E = actual_E + 32 = 0 + 32 = 32 = 6'b100000
        //   f = 0
        //   word = {sign=0, E=6'b100000, f=6'b000000} = 13'b0_100000_000000 = 13'h0800
        weight_flat[0*13 +: 13] = 13'h0800;  // op_b = 1.0 for tile (0,0)
        op_sel          = 2'b10;              // MUL
        accum_en        = 1'b1;
        host_tile_depth = 6'd63;              // open gate: allow up to 63 MACs

        @(negedge clk);
        west_din_flat[0*FLIT_W +: FLIT_W] = make_flit(2'd0, 2'd0, 13'h0800); // op_a = 1.0
        west_vin_flat[0] = 1'b1;
        @(posedge clk); #1;
        @(negedge clk);
        west_vin_flat[0] = 1'b0;
        west_din_flat[0*FLIT_W +: FLIT_W] = {FLIT_W{1'b0}};

        // Wait for flit to arrive at tile (0,0) local port (2 cycles) + 1 more for accum
        begin : wait_t3
            integer i;
            for (i = 0; i < 5; i = i + 1) begin
                @(posedge clk); #1;
                if (r00_loc_v) i = 5;
            end
        end
        // horus_nfe: accum_out <= accum_reg (registered, 1-cycle behind accum_reg).
        // Cycle P+3: MAC fires  → accum_reg updates, accum_out still 0.
        // Cycle P+4: accum_out catches up with new accum_reg (non-zero).
        @(posedge clk); #1;   // P+3 — accum_reg updated
        @(posedge clk); #1;   // P+4 — accum_out reflects new value

        if (acc_00 !== 32'd0) begin
            $display("  PASS: accum_out(0,0)=0x%08X (non-zero — MUL accumulated)", acc_00);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: accum_out(0,0)=0  (MUL did not accumulate into tile (0,0))");
            fail_count = fail_count + 1;
        end

        // Verify OTHER tiles did not accumulate
        if (acc_01 === 32'd0 && acc_10 === 32'd0 && acc_11 === 32'd0) begin
            $display("  PASS: Other tiles (0,1)(1,0)(1,1) accumulator = 0 (flit isolated)");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Spurious accumulation: acc_01=%08X acc_10=%08X acc_11=%08X",
                     acc_01, acc_10, acc_11);
            fail_count = fail_count + 1;
        end

        op_sel          = 2'b11;  // back to NOP
        accum_en        = 1'b0;
        host_tile_depth = 6'd0;   // close gate: Tests 4 onward are routing-only
        repeat (4) @(posedge clk); #1;

        // =====================================================================
        // TEST 4: Simultaneous dual-row injection
        //   Row 0: flit to (0,1), payload=13'h111
        //   Row 1: flit to (1,1), payload=13'h222
        //   Both arrive at their respective tiles within ~4 cycles
        // =====================================================================
        $display("\n[TEST 4] Simultaneous dual-row injection: (0,1)←0x111 and (1,1)←0x222");
        @(negedge clk);
        west_din_flat[0*FLIT_W +: FLIT_W] = make_flit(2'd0, 2'd1, 13'h111);
        west_din_flat[1*FLIT_W +: FLIT_W] = make_flit(2'd1, 2'd1, 13'h222);
        west_vin_flat = 2'b11;
        @(posedge clk); #1;
        @(negedge clk);
        west_vin_flat = 2'b00;
        west_din_flat = 0;

        begin : wait_t4
            integer i;
            integer both_seen;
            both_seen = 0;
            for (i = 0; i < 8; i = i + 1) begin
                @(posedge clk); #1;
                if (r01_loc_v && r11_loc_v) begin
                    both_seen = 1;
                    i = 8;
                end
            end
        end

        // Sample one more cycle if needed
        if (!r01_loc_v || !r11_loc_v) begin
            @(posedge clk); #1;
        end

        if (r01_loc_v && r01_loc_d[12:0] === 13'h111) begin
            $display("  PASS: tile(0,1) received 0x%03X", r01_loc_d[12:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: tile(0,1) loc_v=%0b data=0x%03X (expect 1, 0x111)",
                     r01_loc_v, r01_loc_d[12:0]);
            fail_count = fail_count + 1;
        end

        if (r11_loc_v && dut.GEN_ROW[1].GEN_COL[1].loc_d[12:0] === 13'h222) begin
            $display("  PASS: tile(1,1) received 0x%03X",
                     dut.GEN_ROW[1].GEN_COL[1].loc_d[12:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: tile(1,1) loc_v=%0b data=0x%03X (expect 1, 0x222)",
                     r11_loc_v, dut.GEN_ROW[1].GEN_COL[1].loc_d[12:0]);
            fail_count = fail_count + 1;
        end

        repeat (4) @(posedge clk); #1;

        // =====================================================================
        // Final report
        // =====================================================================
        $display("\n============================================");
        $display("  horus_mesh_top 2×2 testbench complete");
        $display("  PASS: %0d   FAIL: %0d", pass_count, fail_count);
        $display("============================================");
        if (fail_count == 0)
            $display("  ALL TESTS PASSED  —  mesh routing verified");
        else
            $display("  *** %0d FAILURE(S) DETECTED ***", fail_count);
        $finish;
    end

endmodule
