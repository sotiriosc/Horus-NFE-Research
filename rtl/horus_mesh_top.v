// SPDX-License-Identifier: CERN-OHL-S-2.0
// =============================================================================
// Module   : horus_mesh_top
// Project  : Horus NFE — 2-D Mesh Multi-Tile System
// Version  : 1.0
// =============================================================================
//
// OVERVIEW
// --------
// Tiles MESH_SIZE × MESH_SIZE instances of (horus_router + horus_system) into
// a 2-D mesh using nested generate blocks.  All inter-router wiring is handled
// by 2-D wire arrays; the generate loops index into those arrays using the
// standard neighbour arithmetic below.
//
// TOPOLOGY  (MESH_SIZE=4 example, West injection, row-major flow)
// ────────────────────────────────────────────────────────────────
//
//   West bdry    col 0          col 1          col 2          col 3
//    row 0 ──→ [Rtr|Sys](0,0) ───── [Rtr|Sys](0,1) ───── [Rtr|Sys](0,2) ───── [Rtr|Sys](0,3) → East bdry
//                   │                     │                     │                     │
//    row 1 ──→ [Rtr|Sys](1,0) ───── [Rtr|Sys](1,1) ─────  ...
//                   │
//    row 2 ──→ ...
//    row 3 ──→ ...
//
// FLIT FORMAT  (FLIT_W=17, MESH_DIM=2)
// ──────────────────────────────────────
//   [16:15] = dest_y (row,    0-based, 2 bits → 4-row max)
//   [14:13] = dest_x (column, 0-based, 2 bits → 4-col max)
//   [12:0]  = 13-bit NFE word (op_a payload)
//
// HORIZONTAL LINK ARRAYS  he_*, hw_*  [row][between-col]
// ─────────────────────────────────────────────────────────
//   Dimension 0 : row   0..MESH_SIZE-1
//   Dimension 1 : between-col  0..MESH_SIZE
//     index 0          = West boundary  (left  of column 0)
//     index j          = between column j-1 and column j
//     index MESH_SIZE  = East boundary  (right of column MESH_SIZE-1)
//
//   he_* : East-going  (col j-1 → col j)
//   hw_* : West-going  (col j   → col j-1)
//
// VERTICAL LINK ARRAYS  vs_*, vn_*  [between-row][col]
// ──────────────────────────────────────────────────────
//   Dimension 0 : between-row  0..MESH_SIZE
//     index 0          = North boundary (above row 0)
//     index i          = between row i-1 and row i
//     index MESH_SIZE  = South boundary (below row MESH_SIZE-1)
//   Dimension 1 : col  0..MESH_SIZE-1
//
//   vs_* : South-going (row i-1 → row i)
//   vn_* : North-going (row i   → row i-1)
//
// TILE (i,j) PORT ASSIGNMENTS
// ────────────────────────────
//   North port → vlink  [i  ][j]   South-going arrives, North-going departs
//   South port → vlink  [i+1][j]   North-going arrives, South-going departs
//   West  port → hlink  [i  ][j]   East-going  arrives, West-going  departs
//   East  port → hlink  [i  ][j+1] West-going  arrives, East-going  departs
//
// DATA FLOW (systolic / weight-stationary mode)
// ───────────────────────────────────────────────
//   1. Host injects flits from the West boundary with dest_x/dest_y headers.
//   2. Each router performs XY routing.  When a flit reaches its destination
//      tile, the router fires its local port: l_vout=1, l_dout[12:0]=op_a.
//   3. horus_system.accum_en is gated by l_vout so accumulation only fires
//      on actual flit deliveries, not every clock cycle.
//   4. horus_system.op_b is supplied directly from weight_flat (host-driven
//      weight bus), bypassing the mesh router.
//   5. Computed results are exposed on result_flat / accum_flat.
//
// =============================================================================

`timescale 1ns / 1ps

module horus_mesh_top #(
    parameter MESH_SIZE = 4,    // N×N grid — must be ≤ 2^MESH_DIM
    parameter FLIT_W    = 17,   // 4-bit routing header + 13-bit NFE payload
    parameter MESH_DIM  = 2     // bits per coordinate (2 → 4×4 max)
) (
    input  wire clk,
    input  wire rst_n,

    // ── Global control: broadcast to every PE ─────────────────────────────────
    input  wire [1:0] op_sel,           // 00=ADD  01=SUB  10=MUL  11=NOP
    input  wire       accum_en,         // host accumulation enable
    input  wire       accum_clr,        // synchronous accumulator clear
    input  wire [5:0] host_tile_depth,  // per-tile MAC budget (0 = unlimited)

    // ── Per-tile weight bus (direct, not mesh-routed) ─────────────────────────
    // weight_flat[(row*MESH_SIZE + col)*13 +: 13] = op_b for tile (row,col)
    input  wire [MESH_SIZE*MESH_SIZE*13-1:0] weight_flat,

    // ── West boundary injection (one port per row) ────────────────────────────
    // west_din_flat[row*FLIT_W +: FLIT_W] = flit to inject on row <row>
    input  wire [MESH_SIZE*FLIT_W-1:0] west_din_flat,
    input  wire [MESH_SIZE-1:0]        west_vin_flat,
    output wire [MESH_SIZE-1:0]        west_rin_flat,   // back-pressure to host

    // ── PE result outputs ──────────────────────────────────────────────────────
    // result_flat[(row*MESH_SIZE + col)*13 +: 13] = tile's 13-bit NFE result
    // accum_flat [(row*MESH_SIZE + col)*32 +: 32] = tile's 32-bit accumulator
    output wire [MESH_SIZE*MESH_SIZE*13-1:0] result_flat,
    output wire [MESH_SIZE*MESH_SIZE*32-1:0] accum_flat
);

    // =========================================================================
    // ── 2-D inter-router link wire arrays ─────────────────────────────────────
    // =========================================================================

    // Horizontal East-going  (cols j-1 → j)
    wire [FLIT_W-1:0] he_d [0:MESH_SIZE-1][0:MESH_SIZE];
    wire              he_v [0:MESH_SIZE-1][0:MESH_SIZE];
    wire              he_r [0:MESH_SIZE-1][0:MESH_SIZE]; // backpressure: West←

    // Horizontal West-going  (cols j → j-1)
    wire [FLIT_W-1:0] hw_d [0:MESH_SIZE-1][0:MESH_SIZE];
    wire              hw_v [0:MESH_SIZE-1][0:MESH_SIZE];
    wire              hw_r [0:MESH_SIZE-1][0:MESH_SIZE]; // backpressure: East←

    // Vertical South-going   (rows i-1 → i)
    wire [FLIT_W-1:0] vs_d [0:MESH_SIZE][0:MESH_SIZE-1];
    wire              vs_v [0:MESH_SIZE][0:MESH_SIZE-1];
    wire              vs_r [0:MESH_SIZE][0:MESH_SIZE-1]; // backpressure: North←

    // Vertical North-going   (rows i → i-1)
    wire [FLIT_W-1:0] vn_d [0:MESH_SIZE][0:MESH_SIZE-1];
    wire              vn_v [0:MESH_SIZE][0:MESH_SIZE-1];
    wire              vn_r [0:MESH_SIZE][0:MESH_SIZE-1]; // backpressure: South←

    // =========================================================================
    // ── Boundary assignments ──────────────────────────────────────────────────
    //
    // West  (between-col = 0)      : driven by top-level injection ports
    // East  (between-col = MESH_SIZE): East output always accepted; no West input
    // North (between-row = 0)      : no data above; North output always accepted
    // South (between-row = MESH_SIZE): no data below; South output always accepted
    //
    // One generate loop per boundary axis; both axes share the same loop variable.
    // =========================================================================
    generate
        genvar bnd;
        for (bnd = 0; bnd < MESH_SIZE; bnd = bnd + 1) begin : GEN_BOUNDS

            // ── West boundary ─────────────────────────────────────────────────
            // East-going input: host drives data in through he_d/he_v at col 0
            assign he_d[bnd][0]       = west_din_flat[bnd*FLIT_W +: FLIT_W];
            assign he_v[bnd][0]       = west_vin_flat[bnd];
            // he_r[bnd][0] is driven by tile(bnd,0).w_rin (router output wire)
            assign west_rin_flat[bnd] = he_r[bnd][0];

            // West-going output from col 0 exits mesh; tie its ready to 1
            assign hw_r[bnd][0] = 1'b1;

            // ── East boundary ─────────────────────────────────────────────────
            // No West-going traffic enters from the right
            assign hw_d[bnd][MESH_SIZE] = {FLIT_W{1'b0}};
            assign hw_v[bnd][MESH_SIZE] = 1'b0;
            // East-going output exits the mesh; tie its ready to 1
            assign he_r[bnd][MESH_SIZE] = 1'b1;

            // ── North boundary ────────────────────────────────────────────────
            assign vs_d[0][bnd] = {FLIT_W{1'b0}};
            assign vs_v[0][bnd] = 1'b0;
            // North-going output exits the mesh; always accepted
            assign vn_r[0][bnd] = 1'b1;

            // ── South boundary ────────────────────────────────────────────────
            assign vn_d[MESH_SIZE][bnd] = {FLIT_W{1'b0}};
            assign vn_v[MESH_SIZE][bnd] = 1'b0;
            // South-going output exits the mesh; always accepted
            assign vs_r[MESH_SIZE][bnd] = 1'b1;
        end
    endgenerate

    // =========================================================================
    // ── Tile array  ───────────────────────────────────────────────────────────
    //
    // For each tile (gi=row, gj=col):
    //   1. horus_router is connected to its 4 neighbours via the link arrays.
    //      N port uses vlink[gi  ][gj]   — South arrives, North departs
    //      S port uses vlink[gi+1][gj]   — North arrives, South departs
    //      W port uses hlink[gi  ][gj]   — East  arrives, West  departs
    //      E port uses hlink[gi  ][gj+1] — West  arrives, East  departs
    //
    //   2. Local port: router → horus_system (op_a delivery)
    //      l_din/l_vin tied to 0 — no result re-injection from PE into mesh.
    //      l_rout tied to 1      — horus_system always accepts.
    //      l_vout gates accum_en — only accumulate when router delivers a flit.
    //
    //   3. horus_system.op_b comes directly from weight_flat[tile_idx*13+:13].
    //
    //   4. Flat outputs collect tile results into top-level buses.
    //
    // Hierarchical debug paths (simulation only):
    //   GEN_ROW[i].GEN_COL[j].u_rtr       horus_router instance
    //   GEN_ROW[i].GEN_COL[j].u_sys       horus_system instance
    //   GEN_ROW[i].GEN_COL[j].loc_v       1 when router is delivering a flit
    //   GEN_ROW[i].GEN_COL[j].loc_d       the flit being delivered (17 bits)
    // =========================================================================
    generate
        genvar gi, gj;

        for (gi = 0; gi < MESH_SIZE; gi = gi + 1) begin : GEN_ROW
            for (gj = 0; gj < MESH_SIZE; gj = gj + 1) begin : GEN_COL

                // ── Router ↔ System local interface ───────────────────────
                wire [FLIT_W-1:0] loc_d;    // delivered flit  (router → system)
                wire              loc_v;    // delivery valid  (gates accum_en)
                wire              loc_r;    // always-accept   (system → router)

                // No-connect wires for unused router output
                wire              nc_l_rin;

                // No-connect wires for unused horus_system outputs
                wire              nc_rollover, nc_underflow, nc_expovf;
                wire              nc_accum_full;
                wire [15:0]       nc_op_count;

                // horus_system has no backpressure: always accept local delivery
                assign loc_r = 1'b1;

                // ── horus_router ───────────────────────────────────────────
                horus_router #(
                    .TILE_X   (gj),
                    .TILE_Y   (gi),
                    .FLIT_W   (FLIT_W),
                    .MESH_DIM (MESH_DIM)
                ) u_rtr (
                    .clk    (clk),
                    .rst_n  (rst_n),

                    // North port — vlink[gi][gj]
                    // South-going data arrives from above;  North-going departs upward
                    .n_din  (vs_d[gi  ][gj]),  .n_vin  (vs_v[gi  ][gj]),
                    .n_rin  (vs_r[gi  ][gj]),
                    .n_dout (vn_d[gi  ][gj]),  .n_vout (vn_v[gi  ][gj]),
                    .n_rout (vn_r[gi  ][gj]),

                    // South port — vlink[gi+1][gj]
                    // North-going data arrives from below;  South-going departs downward
                    .s_din  (vn_d[gi+1][gj]),  .s_vin  (vn_v[gi+1][gj]),
                    .s_rin  (vn_r[gi+1][gj]),
                    .s_dout (vs_d[gi+1][gj]),  .s_vout (vs_v[gi+1][gj]),
                    .s_rout (vs_r[gi+1][gj]),

                    // West port — hlink[gi][gj]
                    // East-going data arrives from left;  West-going departs leftward
                    .w_din  (he_d[gi][gj  ]),  .w_vin  (he_v[gi][gj  ]),
                    .w_rin  (he_r[gi][gj  ]),
                    .w_dout (hw_d[gi][gj  ]),  .w_vout (hw_v[gi][gj  ]),
                    .w_rout (hw_r[gi][gj  ]),

                    // East port — hlink[gi][gj+1]
                    // West-going data arrives from right; East-going departs rightward
                    .e_din  (hw_d[gi][gj+1]),  .e_vin  (hw_v[gi][gj+1]),
                    .e_rin  (hw_r[gi][gj+1]),
                    .e_dout (he_d[gi][gj+1]),  .e_vout (he_v[gi][gj+1]),
                    .e_rout (he_r[gi][gj+1]),

                    // Local port — NFE operand delivery to horus_system
                    .l_din  ({FLIT_W{1'b0}}),  // no result re-injection into mesh
                    .l_vin  (1'b0),
                    .l_rin  (nc_l_rin),        // unused: no local source
                    .l_dout (loc_d),            // 17-bit flit; [12:0] = op_a
                    .l_vout (loc_v),            // high when router delivers a flit
                    .l_rout (loc_r)             // always 1 — system always ready
                );

                // ── horus_system ──────────────────────────────────────────
                // op_a : the 13-bit NFE word embedded in the delivered flit
                // op_b : direct weight from host weight bus (not mesh-routed)
                // accum_en : gated by loc_v — accumulate only on flit delivery
                horus_system u_sys (
                    .clk            (clk),
                    .rst_n          (rst_n),

                    .op_a           (loc_d[12:0]),
                    .op_b           (weight_flat[(gi*MESH_SIZE + gj)*13 +: 13]),
                    .op_sel         (op_sel),

                    .accum_en       (accum_en & loc_v),
                    .accum_clr      (accum_clr),
                    .host_tile_depth(host_tile_depth),

                    .result         (result_flat[(gi*MESH_SIZE + gj)*13 +: 13]),
                    .accum_out      (accum_flat [(gi*MESH_SIZE + gj)*32 +: 32]),

                    .rollover_flag  (nc_rollover),
                    .underflow_flag (nc_underflow),
                    .exp_ovf_flag   (nc_expovf),
                    .op_count       (nc_op_count),
                    .accum_full     (nc_accum_full)
                );

            end // GEN_COL
        end // GEN_ROW
    endgenerate

endmodule
