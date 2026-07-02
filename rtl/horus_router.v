// SPDX-License-Identifier: CERN-OHL-S-2.0
// =============================================================================
// Module   : horus_router
// Project  : Horus Native Fractional Engine — 2-D Mesh Interconnect
// Author   : Horus-NFE Architecture Team
// Version  : 1.0
// =============================================================================
//
// PURPOSE
// -------
// Connects horus_system tiles in a 2-D mesh using deterministic XY routing.
// XY routing eliminates routing cycles → guaranteed deadlock-free.
//
// PACKET FORMAT (FLIT_W bits, MSB-first)
// ----------------------------------------
//   [FLIT_W-1 : FLIT_W-MESH_DIM]           = dest_y  (row, 0-based)
//   [FLIT_W-MESH_DIM-1 : FLIT_W-2*MESH_DIM] = dest_x  (column, 0-based)
//   [FLIT_W-2*MESH_DIM-1 : 0]               = payload (NFE data word)
//
// Example with FLIT_W=16, MESH_DIM=2 (4×4 mesh):
//   [15:14] = dest_y   (2-bit row  0-3)
//   [13:12] = dest_x   (2-bit col  0-3)
//   [11:0]  = payload  (12-bit, or use FLIT_W=17 for full 13-bit NFE word + 4-bit header)
//
// XY ROUTING ALGORITHM
// ----------------------
//   Step 1: Route in X-dimension first.
//     if dest_x > my_x  → output EAST
//     if dest_x < my_x  → output WEST
//   Step 2: Arrived at correct column, route in Y-dimension.
//     if dest_y > my_y  → output SOUTH
//     if dest_y < my_y  → output NORTH
//   Step 3: dest_x==my_x && dest_y==my_y → output LOCAL (deliver to horus_system)
//
// PIPELINE / TIMING
// ------------------
//   Input  side: 1-cycle registered buffer per port (breaks long-wire setup paths)
//   Output side: 1-cycle registered stage per port  (breaks long-wire hold  paths)
//   Net hop latency: 2 cycles  (input_buf → combinational route → output_reg)
//   This keeps each router's internal combinational path to one logic level.
//
// FLOW CONTROL
// -------------
//   Valid/ready handshake on all ports.
//   - ready_out (n_rin…l_rin): asserted when input buffer is empty OR being consumed
//   - ready_in  (n_rout…l_rout): downstream's readiness (credit signal)
//   A transfer occurs on the cycle both valid and ready are high.
//
// OUTPUT ARBITRATION (fixed priority, per output port)
// ------------------------------------------------------
//   EAST  output: W  > L  > N  > S  > E(loop)
//   WEST  output: E  > L  > N  > S  > W(loop)
//   NORTH output: S  > L  > W  > E  > N(loop)
//   SOUTH output: N  > L  > W  > E  > S(loop)
//   LOCAL output: W  > N  > S  > E  > L(loop)
//
//   Priority reflects dominant flow directions (W→E for row traversal,
//   N→S for column traversal), minimising contention stalls.
//
// NON-BLOCKING GUARANTEE
// -----------------------
//   With XY routing, at most one input can be routed to any given output at a
//   time in steady-state traffic. Contention (two inputs competing for the same
//   output simultaneously) is possible only during simultaneous injection; it
//   causes at most one extra cycle of stall for the lower-priority input. The
//   output crossbar fabric itself is non-blocking: no head-of-line blocking.
//
// LOCAL PORT INTEGRATION WITH horus_system
// ------------------------------------------
//   l_dout[FLIT_W-2*MESH_DIM-1:0]  →  horus_system operand input (strip header)
//   l_din[FLIT_W-1:0]              ←  horus_system result injected with built header
//   The system wrapper is responsible for appending/stripping the routing header.
//
// =============================================================================

`timescale 1ns / 1ps

module horus_router #(
    parameter TILE_X    = 0,   // This tile's X coordinate (column), 0-based
    parameter TILE_Y    = 0,   // This tile's Y coordinate (row),    0-based
    parameter FLIT_W    = 16,  // Total flit width including routing header
    parameter MESH_DIM  = 2    // Bits per routing dimension: 2 → 4×4 max mesh
) (
    input  wire clk,
    input  wire rst_n,

    // ------------------------------------------------------------------
    // North port  (data travelling between this tile and the tile above)
    // ------------------------------------------------------------------
    input  wire [FLIT_W-1:0] n_din,    // flit received from North
    input  wire              n_vin,    // valid: North tile is sending
    output wire              n_rin,    // ready: this router can accept from North
    output reg  [FLIT_W-1:0] n_dout,   // flit being sent to North
    output reg               n_vout,   // valid: this router is sending North
    input  wire              n_rout,   // ready: North tile can accept

    // ------------------------------------------------------------------
    // South port
    // ------------------------------------------------------------------
    input  wire [FLIT_W-1:0] s_din,
    input  wire              s_vin,
    output wire              s_rin,
    output reg  [FLIT_W-1:0] s_dout,
    output reg               s_vout,
    input  wire              s_rout,

    // ------------------------------------------------------------------
    // East port  (primary row-traversal direction)
    // ------------------------------------------------------------------
    input  wire [FLIT_W-1:0] e_din,
    input  wire              e_vin,
    output wire              e_rin,
    output reg  [FLIT_W-1:0] e_dout,
    output reg               e_vout,
    input  wire              e_rout,

    // ------------------------------------------------------------------
    // West port  (injection point for most mesh flows)
    // ------------------------------------------------------------------
    input  wire [FLIT_W-1:0] w_din,
    input  wire              w_vin,
    output wire              w_rin,
    output reg  [FLIT_W-1:0] w_dout,
    output reg               w_vout,
    input  wire              w_rout,

    // ------------------------------------------------------------------
    // Local port  (connects to horus_system core)
    // Strip header on l_dout to get NFE payload;
    // append header to l_din before injecting into the mesh.
    // ------------------------------------------------------------------
    input  wire [FLIT_W-1:0] l_din,
    input  wire              l_vin,
    output wire              l_rin,
    output reg  [FLIT_W-1:0] l_dout,
    output reg               l_vout,
    input  wire              l_rout
);

    // =========================================================================
    // Routing direction encoding
    // =========================================================================
    localparam [2:0] DIR_N = 3'd0;
    localparam [2:0] DIR_S = 3'd1;
    localparam [2:0] DIR_E = 3'd2;
    localparam [2:0] DIR_W = 3'd3;
    localparam [2:0] DIR_L = 3'd4;

    // Cast this tile's coordinates to MESH_DIM-bit constants for clean comparison
    localparam [MESH_DIM-1:0] MY_X = TILE_X[MESH_DIM-1:0];
    localparam [MESH_DIM-1:0] MY_Y = TILE_Y[MESH_DIM-1:0];

    // Header field MSB/LSB positions inside a FLIT_W-bit word
    localparam HDR_Y_HI = FLIT_W - 1;
    localparam HDR_Y_LO = FLIT_W - MESH_DIM;
    localparam HDR_X_HI = FLIT_W - MESH_DIM - 1;
    localparam HDR_X_LO = FLIT_W - 2*MESH_DIM;

    // =========================================================================
    // ── STAGE 1: 1-cycle input pipeline registers ─────────────────────────────
    // Each port's incoming flit is latched on arrival.
    // The buffer is replaced only when it is empty or when the current flit
    // has been forwarded to its output port this cycle (consumed).
    // =========================================================================
    reg [FLIT_W-1:0] n_buf_d, s_buf_d, e_buf_d, w_buf_d, l_buf_d;
    reg              n_buf_v, s_buf_v, e_buf_v, w_buf_v, l_buf_v;

    // Forward-declared: consumed combinationally from output arbitration below
    wire n_buf_cons, s_buf_cons, e_buf_cons, w_buf_cons, l_buf_cons;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) n_buf_v <= 1'b0;
        else if (!n_buf_v || n_buf_cons) begin
            n_buf_d <= n_din;
            n_buf_v <= n_vin;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s_buf_v <= 1'b0;
        else if (!s_buf_v || s_buf_cons) begin
            s_buf_d <= s_din;
            s_buf_v <= s_vin;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) e_buf_v <= 1'b0;
        else if (!e_buf_v || e_buf_cons) begin
            e_buf_d <= e_din;
            e_buf_v <= e_vin;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) w_buf_v <= 1'b0;
        else if (!w_buf_v || w_buf_cons) begin
            w_buf_d <= w_din;
            w_buf_v <= w_vin;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) l_buf_v <= 1'b0;
        else if (!l_buf_v || l_buf_cons) begin
            l_buf_d <= l_din;
            l_buf_v <= l_vin;
        end
    end

    // =========================================================================
    // ── STAGE 1 (cont.): Header extraction ────────────────────────────────────
    // =========================================================================
    wire [MESH_DIM-1:0] n_bdy = n_buf_d[HDR_Y_HI:HDR_Y_LO];
    wire [MESH_DIM-1:0] n_bdx = n_buf_d[HDR_X_HI:HDR_X_LO];
    wire [MESH_DIM-1:0] s_bdy = s_buf_d[HDR_Y_HI:HDR_Y_LO];
    wire [MESH_DIM-1:0] s_bdx = s_buf_d[HDR_X_HI:HDR_X_LO];
    wire [MESH_DIM-1:0] e_bdy = e_buf_d[HDR_Y_HI:HDR_Y_LO];
    wire [MESH_DIM-1:0] e_bdx = e_buf_d[HDR_X_HI:HDR_X_LO];
    wire [MESH_DIM-1:0] w_bdy = w_buf_d[HDR_Y_HI:HDR_Y_LO];
    wire [MESH_DIM-1:0] w_bdx = w_buf_d[HDR_X_HI:HDR_X_LO];
    wire [MESH_DIM-1:0] l_bdy = l_buf_d[HDR_Y_HI:HDR_Y_LO];
    wire [MESH_DIM-1:0] l_bdx = l_buf_d[HDR_X_HI:HDR_X_LO];

    // =========================================================================
    // ── STAGE 1 (cont.): XY routing decision (combinational) ──────────────────
    // Outputs 3-bit DIR_* for each buffered flit.
    // =========================================================================

    // Inline XY route function — expanded per buffer to avoid macro name clashes
    // Priority: X-dimension first, then Y-dimension.
    wire [2:0] n_route =
        (n_bdx == MY_X && n_bdy == MY_Y) ? DIR_L :
        (n_bdx  > MY_X)                   ? DIR_E :
        (n_bdx  < MY_X)                   ? DIR_W :
        (n_bdy  > MY_Y)                   ? DIR_S :
                                            DIR_N; // loopback (unusual)

    wire [2:0] s_route =
        (s_bdx == MY_X && s_bdy == MY_Y) ? DIR_L :
        (s_bdx  > MY_X)                   ? DIR_E :
        (s_bdx  < MY_X)                   ? DIR_W :
        (s_bdy  > MY_Y)                   ? DIR_S : // loopback
                                            DIR_N;

    wire [2:0] e_route =
        (e_bdx == MY_X && e_bdy == MY_Y) ? DIR_L :
        (e_bdx  > MY_X)                   ? DIR_E : // loopback
        (e_bdx  < MY_X)                   ? DIR_W :
        (e_bdy  > MY_Y)                   ? DIR_S :
                                            DIR_N;

    wire [2:0] w_route =
        (w_bdx == MY_X && w_bdy == MY_Y) ? DIR_L :
        (w_bdx  > MY_X)                   ? DIR_E :
        (w_bdx  < MY_X)                   ? DIR_W : // loopback
        (w_bdy  > MY_Y)                   ? DIR_S :
                                            DIR_N;

    wire [2:0] l_route =
        (l_bdx == MY_X && l_bdy == MY_Y) ? DIR_L : // local loopback
        (l_bdx  > MY_X)                   ? DIR_E :
        (l_bdx  < MY_X)                   ? DIR_W :
        (l_bdy  > MY_Y)                   ? DIR_S :
                                            DIR_N;

    // =========================================================================
    // ── STAGE 2: Output acceptance ─────────────────────────────────────────────
    // An output register can accept a new flit when it is empty or
    // when it is handing off its current flit to the downstream this cycle.
    // =========================================================================
    wire n_accept = !n_vout || n_rout;
    wire s_accept = !s_vout || s_rout;
    wire e_accept = !e_vout || e_rout;
    wire w_accept = !w_vout || w_rout;
    wire l_accept = !l_vout || l_rout;

    // =========================================================================
    // ── STAGE 2: "Want" signals ────────────────────────────────────────────────
    // Does a given input buffer's flit want a given output port?
    // =========================================================================
    // — wants NORTH output
    wire n_wn = n_buf_v && (n_route == DIR_N);   // north-buf → north (loopback)
    wire s_wn = s_buf_v && (s_route == DIR_N);
    wire e_wn = e_buf_v && (e_route == DIR_N);
    wire w_wn = w_buf_v && (w_route == DIR_N);
    wire l_wn = l_buf_v && (l_route == DIR_N);

    // — wants SOUTH output
    wire n_ws = n_buf_v && (n_route == DIR_S);
    wire s_ws = s_buf_v && (s_route == DIR_S);   // south-buf → south (loopback)
    wire e_ws = e_buf_v && (e_route == DIR_S);
    wire w_ws = w_buf_v && (w_route == DIR_S);
    wire l_ws = l_buf_v && (l_route == DIR_S);

    // — wants EAST output
    wire n_we = n_buf_v && (n_route == DIR_E);
    wire s_we = s_buf_v && (s_route == DIR_E);
    wire e_we = e_buf_v && (e_route == DIR_E);   // east-buf → east (loopback)
    wire w_we = w_buf_v && (w_route == DIR_E);
    wire l_we = l_buf_v && (l_route == DIR_E);

    // — wants WEST output
    wire n_ww = n_buf_v && (n_route == DIR_W);
    wire s_ww = s_buf_v && (s_route == DIR_W);
    wire e_ww = e_buf_v && (e_route == DIR_W);
    wire w_ww = w_buf_v && (w_route == DIR_W);   // west-buf → west (loopback)
    wire l_ww = l_buf_v && (l_route == DIR_W);

    // — wants LOCAL output
    wire n_wl = n_buf_v && (n_route == DIR_L);
    wire s_wl = s_buf_v && (s_route == DIR_L);
    wire e_wl = e_buf_v && (e_route == DIR_L);
    wire w_wl = w_buf_v && (w_route == DIR_L);
    wire l_wl = l_buf_v && (l_route == DIR_L);   // local-buf → local (loopback)

    // =========================================================================
    // ── STAGE 2: Priority arbitration ─────────────────────────────────────────
    // For each output, a fixed-priority encoder selects the winning input flit.
    // Winner data is registered in STAGE 2 output registers below.
    //
    //   EAST  : W > L > N > S > E(loop)
    //   WEST  : E > L > N > S > W(loop)
    //   NORTH : S > L > W > E > N(loop)
    //   SOUTH : N > L > W > E > S(loop)
    //   LOCAL : W > N > S > E > L(loop)
    // =========================================================================

    // EAST output
    wire e_win_v = w_we || l_we || n_we || s_we || e_we;
    wire [FLIT_W-1:0] e_win_d =
        w_we ? w_buf_d :
        l_we ? l_buf_d :
        n_we ? n_buf_d :
        s_we ? s_buf_d :
               e_buf_d;

    // WEST output
    wire w_win_v = e_ww || l_ww || n_ww || s_ww || w_ww;
    wire [FLIT_W-1:0] w_win_d =
        e_ww ? e_buf_d :
        l_ww ? l_buf_d :
        n_ww ? n_buf_d :
        s_ww ? s_buf_d :
               w_buf_d;

    // NORTH output
    wire n_win_v = s_wn || l_wn || w_wn || e_wn || n_wn;
    wire [FLIT_W-1:0] n_win_d =
        s_wn ? s_buf_d :
        l_wn ? l_buf_d :
        w_wn ? w_buf_d :
        e_wn ? e_buf_d :
               n_buf_d;

    // SOUTH output
    wire s_win_v = n_ws || l_ws || w_ws || e_ws || s_ws;
    wire [FLIT_W-1:0] s_win_d =
        n_ws ? n_buf_d :
        l_ws ? l_buf_d :
        w_ws ? w_buf_d :
        e_ws ? e_buf_d :
               s_buf_d;

    // LOCAL output
    wire l_win_v = w_wl || n_wl || s_wl || e_wl || l_wl;
    wire [FLIT_W-1:0] l_win_d =
        w_wl ? w_buf_d :
        n_wl ? n_buf_d :
        s_wl ? s_buf_d :
        e_wl ? e_buf_d :
               l_buf_d;

    // =========================================================================
    // ── STAGE 2: Output registers ─────────────────────────────────────────────
    // The winner flit is captured on the next clock edge when the output port
    // can accept (port is empty, or downstream is consuming the current flit).
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin n_vout <= 1'b0; n_dout <= {FLIT_W{1'b0}}; end
        else if (n_accept) begin n_vout <= n_win_v; n_dout <= n_win_d; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s_vout <= 1'b0; s_dout <= {FLIT_W{1'b0}}; end
        else if (s_accept) begin s_vout <= s_win_v; s_dout <= s_win_d; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin e_vout <= 1'b0; e_dout <= {FLIT_W{1'b0}}; end
        else if (e_accept) begin e_vout <= e_win_v; e_dout <= e_win_d; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin w_vout <= 1'b0; w_dout <= {FLIT_W{1'b0}}; end
        else if (w_accept) begin w_vout <= w_win_v; w_dout <= w_win_d; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin l_vout <= 1'b0; l_dout <= {FLIT_W{1'b0}}; end
        else if (l_accept) begin l_vout <= l_win_v; l_dout <= l_win_d; end
    end

    // =========================================================================
    // ── Fires: output fires this cycle (consumed by downstream) ───────────────
    // "Fires" means: the output register will be refilled at the next posedge,
    // and the winning input buffer's flit has been forwarded.
    // =========================================================================
    wire n_fires = n_win_v && n_accept;
    wire s_fires = s_win_v && s_accept;
    wire e_fires = e_win_v && e_accept;
    wire w_fires = w_win_v && w_accept;
    wire l_fires = l_win_v && l_accept;

    // =========================================================================
    // ── Buffer consumed signals ────────────────────────────────────────────────
    // A buffer is consumed when it wins arbitration for its target output AND
    // that output fires this cycle.  This frees the buffer for the next flit.
    //
    // Each "wins" expression encodes: this buffer is the winning contestant for
    // the given output port, considering the fixed priority above.
    //
    // Notation: "n_buf wins east" = w_we is false (W has higher priority) AND
    //           l_we is false AND n_we is true AND east fires.
    // =========================================================================

    // ─── North buffer consumed ─────────────────────────────────────────────────
    assign n_buf_cons =
        // → NORTH (loopback; lowest priority for N-out: S>L>W>E>N)
        (n_wn && !s_wn && !l_wn && !w_wn && !e_wn && n_fires) ||
        // → SOUTH (N has highest priority for S-out: N>L>W>E>S)
        (n_ws && s_fires) ||
        // → EAST  (N is 3rd for E-out: W>L>N>S>E)
        (n_we && !w_we && !l_we && e_fires) ||
        // → WEST  (N is 3rd for W-out: E>L>N>S>W)
        (n_ww && !e_ww && !l_ww && w_fires) ||
        // → LOCAL (N is 2nd for L-out: W>N>S>E>L)
        (n_wl && !w_wl && l_fires);

    // ─── South buffer consumed ─────────────────────────────────────────────────
    assign s_buf_cons =
        // → NORTH (S has highest priority for N-out: S>L>W>E>N)
        (s_wn && n_fires) ||
        // → SOUTH (loopback; lowest: N>L>W>E>S)
        (s_ws && !n_ws && !l_ws && !w_ws && !e_ws && s_fires) ||
        // → EAST  (S is 4th for E-out: W>L>N>S>E)
        (s_we && !w_we && !l_we && !n_we && e_fires) ||
        // → WEST  (S is 4th for W-out: E>L>N>S>W)
        (s_ww && !e_ww && !l_ww && !n_ww && w_fires) ||
        // → LOCAL (S is 3rd for L-out: W>N>S>E>L)
        (s_wl && !w_wl && !n_wl && l_fires);

    // ─── East buffer consumed ──────────────────────────────────────────────────
    assign e_buf_cons =
        // → NORTH (E is 4th for N-out: S>L>W>E>N)
        (e_wn && !s_wn && !l_wn && !w_wn && n_fires) ||
        // → SOUTH (E is 4th for S-out: N>L>W>E>S)
        (e_ws && !n_ws && !l_ws && !w_ws && s_fires) ||
        // → EAST  (loopback; lowest: W>L>N>S>E)
        (e_we && !w_we && !l_we && !n_we && !s_we && e_fires) ||
        // → WEST  (E has highest priority for W-out: E>L>N>S>W)
        (e_ww && w_fires) ||
        // → LOCAL (E is 4th for L-out: W>N>S>E>L)
        (e_wl && !w_wl && !n_wl && !s_wl && l_fires);

    // ─── West buffer consumed ──────────────────────────────────────────────────
    assign w_buf_cons =
        // → NORTH (W is 3rd for N-out: S>L>W>E>N)
        (w_wn && !s_wn && !l_wn && n_fires) ||
        // → SOUTH (W is 3rd for S-out: N>L>W>E>S)
        (w_ws && !n_ws && !l_ws && s_fires) ||
        // → EAST  (W has highest priority for E-out: W>L>N>S>E)
        (w_we && e_fires) ||
        // → WEST  (loopback; lowest: E>L>N>S>W)
        (w_ww && !e_ww && !l_ww && !n_ww && !s_ww && w_fires) ||
        // → LOCAL (W has highest priority for L-out: W>N>S>E>L)
        (w_wl && l_fires);

    // ─── Local buffer consumed ─────────────────────────────────────────────────
    assign l_buf_cons =
        // → NORTH (L is 2nd for N-out: S>L>W>E>N)
        (l_wn && !s_wn && n_fires) ||
        // → SOUTH (L is 2nd for S-out: N>L>W>E>S)
        (l_ws && !n_ws && s_fires) ||
        // → EAST  (L is 2nd for E-out: W>L>N>S>E)
        (l_we && !w_we && e_fires) ||
        // → WEST  (L is 2nd for W-out: E>L>N>S>W)
        (l_ww && !e_ww && w_fires) ||
        // → LOCAL (loopback; lowest: W>N>S>E>L)
        (l_wl && !w_wl && !n_wl && !s_wl && !e_wl && l_fires);

    // =========================================================================
    // ── Input ready signals ────────────────────────────────────────────────────
    // Ready = input buffer is free to accept a new flit from upstream.
    // The buffer is free when it is empty (!buf_v) or when it will be consumed
    // this cycle, i.e., it wins an output that fires (buf_cons is asserted).
    // =========================================================================
    assign n_rin = !n_buf_v || n_buf_cons;
    assign s_rin = !s_buf_v || s_buf_cons;
    assign e_rin = !e_buf_v || e_buf_cons;
    assign w_rin = !w_buf_v || w_buf_cons;
    assign l_rin = !l_buf_v || l_buf_cons;

endmodule
