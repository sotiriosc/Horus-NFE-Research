`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_axi_bridge
// Project  : Horus Engine
// File     : horus_axi_bridge.v
//
// Purpose
//   AXI4-Stream wrapper that integrates horus_input_buffer (×2) and horus_top
//   into a streaming accelerator IP core.  Upstream masters stream NFE vectors
//   in as AXI4-Stream packets; the bridge automatically pre-fills the systolic
//   array pipeline, executes the computation window, and presents the four
//   accumulated row results as a single 128-bit AXI4-Stream result packet.
//
// ─────────────────────────────────────────────────────────────────────────────
// Interface Summary
// ─────────────────────────────────────────────────────────────────────────────
//
//   SLAVE  (s_axis_*)  —  52-bit inbound vector stream
//     s_axis_tdata[51:0]   Packed NFE bus {ch3[12:0], ch2[12:0], ch1[12:0], ch0[12:0]}
//     s_axis_tvalid        Upstream master has valid data on the bus
//     s_axis_tready        Bridge is ready to accept (backpressure output)
//     s_axis_tlast         Last beat of the packet → arms start_compute
//
//   MASTER (m_axis_*)  —  128-bit outbound result stream
//     m_axis_tdata[127:0]  Packed results {row_out_3, row_out_2, row_out_1, row_out_0}
//     m_axis_tvalid        Results are valid (directly follows internal data_valid)
//     m_axis_tready        Downstream consumer is ready to accept results
//     m_axis_tlast         Always asserted with tvalid (single-beat result packet)
//
// ─────────────────────────────────────────────────────────────────────────────
// Data Routing Architecture
// ─────────────────────────────────────────────────────────────────────────────
//
//   The 52-bit slave data bus is routed identically to BOTH input buffers:
//     u_act_buf.data_in = s_axis_tdata  →  row_act_0..3 (left boundary)
//     u_wt_buf.data_in  = s_axis_tdata  →  col_wt_0..3  (top boundary)
//
//   Each beat of the incoming stream is therefore used as both the activation
//   vector AND the weight vector for one pipeline step.  The systolic array
//   computes the correlation matrix:
//
//     row_out[r] = Σ_c  act_skewed[r,c]  ×  wt_skewed[r,c]
//                = Σ_c  input[c - skew_r]  ×  input[c - skew_c]
//
//   This topology is optimal for applications such as neural-network energy
//   computations, autocorrelation, and self-attention dot products where the
//   same vector is projected against itself.  For full A×B multiply, extend
//   with a second 52-bit slave port and separate routing.
//
// ─────────────────────────────────────────────────────────────────────────────
// Internal Sub-Module Hierarchy
// ─────────────────────────────────────────────────────────────────────────────
//
//   horus_axi_bridge
//   ├── u_act_buf   horus_input_buffer  (row activation skew buffer, 0/1/2/3 cy)
//   ├── u_wt_buf    horus_input_buffer  (column weight skew buffer,  0/1/2/3 cy)
//   └── u_top       horus_top
//                   ├── u_ctrl   horus_controller   (one-hot Moore FSM)
//                   └── u_array  horus_systolic_array #(ROWS=4, COLS=4)
//                                └── GEN_ROW[0..3].GEN_COL[0..3].pe_inst  ×16
//
// ─────────────────────────────────────────────────────────────────────────────
// Bridge Control State Machine (single `computing` register)
// ─────────────────────────────────────────────────────────────────────────────
//
//       s_axis_tvalid & tready & tlast
//               │
//  tready=1     ▼           tready=0
//  ┌──────────────────┐     ┌────────────────────────────────────────────────┐
//  │ computing = 0    │────►│  computing = 1                                  │
//  │ (Accepting data) │     │  (FSM running: IDLE→SETUP→STREAM→READY)         │
//  └──────────────────┘     └────────────────────────────────────────────────┘
//         ▲                              │ m_axis_tvalid & m_axis_tready
//         └──────────────────────────────┘  (result consumed → result_ack)
//
//  The `computing` register is the ONLY internal state in this bridge.
//  All FSM sequencing is handled by horus_controller inside horus_top.
//
// ─────────────────────────────────────────────────────────────────────────────
// Cycle-Accurate Timing Model  (steady-state, m_axis_tready always high)
// ─────────────────────────────────────────────────────────────────────────────
//
//  Cycle    Event
//  ──────   ──────────────────────────────────────────────────────────────────
//   0..N-2  s_axis beats accepted (tvalid=tready=1, tlast=0)
//              Bridge drives input_valid=1, feeding both skew buffers.
//              horus_systolic_array act_reg / wt_reg fill in the background.
//   N-1     Last data beat: s_axis_tvalid=tready=tlast=1 — handshake
//   N       computing←1; start_compute←1 (registered pulse fires)
//              s_axis_tready←0 (backpressure asserted)
//              horus_controller: IDLE→SETUP (accum_clr=1)
//   N+1     start_compute←0; FSM: SETUP→STREAM (accum_en=1; cycle_cnt=0)
//   N+2..N+8 FSM: STREAM (accum_en=1, cycle_cnt 0→6; 7 accumulation cycles)
//   N+9     FSM: STREAM→READY; data_valid=1
//              m_axis_tvalid←1, m_axis_tdata←{row_out_3..row_out_0}
//              result_ack fires if m_axis_tready=1
//   N+10    computing←0; FSM: READY→IDLE
//              s_axis_tready←1 (bridge accepts next packet)
//
//  The upstream AXI master must send ≥7 beats (fill latency + pipeline depth)
//  before asserting tlast to guarantee all 16 PEs accumulate valid products.
//  Sending fewer beats pre-fills only a subset of PEs; results are still
//  architecturally correct but partial (only pre-filled PEs contribute).
//
// ─────────────────────────────────────────────────────────────────────────────
// AXI4-Stream Compliance Notes
// ─────────────────────────────────────────────────────────────────────────────
//   • tvalid may deassert mid-packet without tlast; the skew buffers HOLD
//     their last value (input_valid=0) and resume correctly when tvalid returns.
//   • tready follows tvalid combinationally (no registered tready delay);
//     this satisfies the AXI4-Stream rule that tready may depend on tvalid.
//   • m_axis_tdata remains stable from data_valid through result_ack.
//   • m_axis_tlast is asserted with every tvalid beat (single-beat packet).
//   • The bridge does NOT assert s_axis_tready when computing=1, providing
//     clean backpressure during the entire SETUP+STREAM+READY window.
//   • aresetn is asynchronous-active-low, matching the AXI4 specification.
// ============================================================================

module horus_axi_bridge (
    // ── AXI4 global signals ───────────────────────────────────────────────────
    input  wire        aclk,     // AXI clock (drives all internal sub-modules)
    input  wire        aresetn,  // AXI active-low reset (asynchronous assert)
                                 // Note: horus_top.rst = ~aresetn (inverted here)

    // ── AXI4-Stream Slave  (52-bit inbound vector) ────────────────────────────
    // Each beat carries four 13-bit NFE words packed LSB-first:
    //   tdata[12:0]  = channel 0  (lowest skew: feeds row/col index 0)
    //   tdata[25:13] = channel 1
    //   tdata[38:26] = channel 2
    //   tdata[51:39] = channel 3  (highest skew: feeds row/col index 3)
    input  wire [51:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,  // Low while computing; high when idle
    input  wire        s_axis_tlast,   // Packet end → arms start_compute

    // ── AXI4-Stream Master  (128-bit outbound result) ─────────────────────────
    // Result word layout (LSB-first, matches s_axis channel order convention):
    //   tdata[31:0]   = row_out_0   (row 0 accumulated dot product)
    //   tdata[63:32]  = row_out_1
    //   tdata[95:64]  = row_out_2
    //   tdata[127:96] = row_out_3   (row 3 accumulated dot product)
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,  // Exactly follows internal data_valid
    input  wire         m_axis_tready,  // Downstream consumer ready
    output wire         m_axis_tlast    // Always 1 with tvalid (single-beat packet)
);

    // =========================================================================
    // Internal wire declarations
    // =========================================================================

    // ── Skew-buffer → systolic array boundary wires ───────────────────────────
    wire [12:0] row_act_0, row_act_1, row_act_2, row_act_3;
    wire [12:0] col_wt_0,  col_wt_1,  col_wt_2,  col_wt_3;

    // ── horus_top result wires ─────────────────────────────────────────────────
    wire [31:0] row_out_0, row_out_1, row_out_2, row_out_3;
    wire        data_valid;

    // ── Bridge control wires ──────────────────────────────────────────────────
    wire        input_valid;   // Qualified AXI handshake → enables both buffers
    reg         start_compute; // 1-cycle registered pulse after tlast
    wire        result_ack;    // Combinational: m_axis_tvalid & m_axis_tready

    // =========================================================================
    // `computing` register — the bridge's sole internal state
    // ─────────────────────────────────────────────────────────────────────────
    // SET   on the cycle after s_axis_tlast fires (tlast handshake detected).
    // CLEAR on the cycle after result_ack (downstream consumed the result).
    //
    // Priority: result_ack clear takes precedence so that back-to-back windows
    // where a result is consumed in the same cycle a new packet ends are handled
    // correctly — the bridge immediately unblocks for the next packet.
    // =========================================================================
    reg computing;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            computing <= 1'b0;
        end else begin
            if (result_ack)
                // Downstream has consumed the result — clear the execution lock.
                computing <= 1'b0;
            else if (s_axis_tvalid & s_axis_tready & s_axis_tlast)
                // Last data beat handshake — lock slave until computation ends.
                computing <= 1'b1;
        end
    end

    // =========================================================================
    // start_compute — registered 1-cycle pulse
    // ─────────────────────────────────────────────────────────────────────────
    // Captures the tlast handshake and presents it as a clean 1-cycle pulse to
    // horus_controller on the FOLLOWING clock edge.  This guarantees that:
    //   (a) start_compute arrives one cycle after the last data beat is accepted
    //   (b) computing=1 is already set when start_compute fires, so the FSM
    //       can never be erroneously re-triggered by a stale handshake signal
    // =========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)
            start_compute <= 1'b0;
        else
            start_compute <= s_axis_tvalid & s_axis_tready & s_axis_tlast;
    end

    // =========================================================================
    // Slave backpressure: tready follows computing combinationally
    // ─────────────────────────────────────────────────────────────────────────
    // When computing=1 the bridge asserts backpressure by deasserting tready.
    // This stalls the upstream master for the full SETUP+STREAM+READY window
    // (approximately 9 cycles from start_compute to result_ack at m_ready=1).
    // The AXI4-Stream specification permits tready to depend on tvalid.
    // =========================================================================
    assign s_axis_tready = ~computing;

    // =========================================================================
    // input_valid: qualified handshake drives both skew buffer clock enables
    // ─────────────────────────────────────────────────────────────────────────
    // Only qualified beats (tvalid=1 and tready=1) advance the shift registers
    // inside horus_input_buffer.  Mid-packet gaps (tvalid=0) cause the buffers
    // to HOLD their current values — the skewed pipeline state is preserved.
    // =========================================================================
    assign input_valid = s_axis_tvalid & s_axis_tready;

    // =========================================================================
    // result_ack: consumed handshake returns FSM to IDLE
    // ─────────────────────────────────────────────────────────────────────────
    // Fires combinationally whenever the downstream consumer accepts the result.
    // This signal feeds horus_top.result_ack, triggering the READY→IDLE arc
    // inside horus_controller on the next posedge.
    // =========================================================================
    assign result_ack = m_axis_tvalid & m_axis_tready;

    // =========================================================================
    // Master output assignments
    // ─────────────────────────────────────────────────────────────────────────
    // m_axis_tvalid   : directly follows horus_controller data_valid (Moore output)
    // m_axis_tdata    : four 32-bit row outputs packed into one 128-bit word
    // m_axis_tlast    : always 1 when tvalid (single-beat packet, one per window)
    // =========================================================================
    assign m_axis_tvalid = data_valid;
    assign m_axis_tdata  = {row_out_3, row_out_2, row_out_1, row_out_0};
    assign m_axis_tlast  = m_axis_tvalid;  // Single-beat result; every valid is last

    // =========================================================================
    // u_act_buf — Row Activation Skew Buffer
    // ─────────────────────────────────────────────────────────────────────────
    // Staggers the four 13-bit channels from s_axis_tdata across 0, 1, 2, 3
    // clock cycles so that activation token [r] arrives at the left boundary
    // of the systolic array r cycles after token [0], matching the diagonal
    // wavefront required for correct matrix accumulation.
    //
    // Port mapping:
    //   data_in[12: 0] = ch0 → out_ch0 (0 cycles) → row_act_0
    //   data_in[25:13] = ch1 → out_ch1 (1 cycle)  → row_act_1
    //   data_in[38:26] = ch2 → out_ch2 (2 cycles) → row_act_2
    //   data_in[51:39] = ch3 → out_ch3 (3 cycles) → row_act_3
    // =========================================================================
    horus_input_buffer u_act_buf (
        .clk         (aclk),
        .rst_n       (aresetn),       // aresetn is active-low — connects directly
        .input_valid (input_valid),   // Qualified AXI beat handshake
        .data_in     (s_axis_tdata),  // 52-bit packed NFE bus
        .out_ch0     (row_act_0),
        .out_ch1     (row_act_1),
        .out_ch2     (row_act_2),
        .out_ch3     (row_act_3)
    );

    // =========================================================================
    // u_wt_buf — Column Weight Skew Buffer
    // ─────────────────────────────────────────────────────────────────────────
    // Mirrors u_act_buf for the vertical weight lanes.  The same s_axis_tdata
    // bus feeds both buffers — see "Data Routing Architecture" at the top of
    // this file for the mathematical rationale.
    //
    // Port mapping:
    //   data_in[12: 0] = ch0 → out_ch0 (0 cycles) → col_wt_0
    //   data_in[25:13] = ch1 → out_ch1 (1 cycle)  → col_wt_1
    //   data_in[38:26] = ch2 → out_ch2 (2 cycles) → col_wt_2
    //   data_in[51:39] = ch3 → out_ch3 (3 cycles) → col_wt_3
    // =========================================================================
    horus_input_buffer u_wt_buf (
        .clk         (aclk),
        .rst_n       (aresetn),
        .input_valid (input_valid),
        .data_in     (s_axis_tdata),  // Same bus as u_act_buf (correlation mode)
        .out_ch0     (col_wt_0),
        .out_ch1     (col_wt_1),
        .out_ch2     (col_wt_2),
        .out_ch3     (col_wt_3)
    );

    // =========================================================================
    // u_top — Horus Engine Top-Level
    // ─────────────────────────────────────────────────────────────────────────
    // horus_top.rst is active-HIGH; aresetn is active-LOW.
    // The combinational inversion (~aresetn) maps the AXI global reset polarity
    // to the top-level module's convention without any additional logic cells.
    //
    // Handshake connections:
    //   start_compute ← bridge registered pulse (1 cycle after s_axis_tlast)
    //   result_ack    ← m_axis_tvalid & m_axis_tready (AXI master handshake)
    //   data_valid    → m_axis_tvalid (direct level-sensitive forward path)
    // =========================================================================
    horus_top u_top (
        .clk           (aclk),
        .rst           (~aresetn),    // Active-high reset for horus_top

        // ── FSM handshake ────────────────────────────────────────────────────
        .start_compute (start_compute),
        .result_ack    (result_ack),
        .data_valid    (data_valid),

        // ── Left-boundary row activation inputs (from u_act_buf) ─────────────
        .row_act_0     (row_act_0),
        .row_act_1     (row_act_1),
        .row_act_2     (row_act_2),
        .row_act_3     (row_act_3),

        // ── Top-boundary column weight inputs (from u_wt_buf) ─────────────────
        .col_wt_0      (col_wt_0),
        .col_wt_1      (col_wt_1),
        .col_wt_2      (col_wt_2),
        .col_wt_3      (col_wt_3),

        // ── Accumulated row dot-product outputs ───────────────────────────────
        .row_out_0     (row_out_0),
        .row_out_1     (row_out_1),
        .row_out_2     (row_out_2),
        .row_out_3     (row_out_3)
    );

endmodule
