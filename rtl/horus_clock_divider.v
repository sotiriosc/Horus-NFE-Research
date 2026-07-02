`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_clock_divider
// Project  : Horus Engine
// File     : horus_clock_divider.v
//
// Purpose
//   Divides the 100 MHz board master clock down to a 117 Hz acoustic-frequency
//   clock pulse to drive the Horus Engine systolic array compute windows.
//   Implements a symmetric toggle divider for a guaranteed 50% duty cycle.
//
// ─────────────────────────────────────────────────────────────────────────────
// Timing Derivation
// ─────────────────────────────────────────────────────────────────────────────
//
//   Master clock frequency   : f_in  = 100,000,000 Hz
//   Target output frequency  : f_out =         117 Hz
//
//   Full output period in master ticks:
//     T_full = f_in / f_out = 100,000,000 / 117 = 854,700.855 ticks (exact)
//
//   Half output period in master ticks (equal HIGH and LOW intervals):
//     T_half = T_full / 2 = 427,350.427 ticks (exact)
//
//   Chosen HALF_PERIOD localparam: 427,350 ticks
//     Rounding error : +0.427 ticks  (rounds DOWN — slightly high frequency)
//
//   Achieved output frequency:
//     f_achieved = f_in / (2 × HALF_PERIOD)
//                = 100,000,000 / 854,700
//                = 117.000117 Hz
//
//   Frequency error vs. target:
//     Δf   = +0.000117 Hz
//     ppm  = +1.000 ppm   (well within acoustic tolerance)
//
//   Full achieved period:
//     T_full_achieved = 8,547,000 ns  (8.547 ms)
//
// ─────────────────────────────────────────────────────────────────────────────
// Counter Design
// ─────────────────────────────────────────────────────────────────────────────
//
//   Counter width: 20 bits
//     Minimum bits required to hold (HALF_PERIOD − 1): ⌈log₂(427350)⌉ = 19 bits
//     20 bits chosen for one bit of headroom above the minimum.
//     Maximum representable value: 2²⁰ − 1 = 1,048,575
//     Headroom above max counter value: 1,048,575 − 427,349 = 621,226 counts
//
//   Counter range per phase: 0 to HALF_PERIOD − 1  (= 0 to 427,349 inclusive)
//     Tick count per phase: exactly 427,350 ticks → 50% duty cycle guaranteed
//
//   Toggle rule: when counter == (HALF_PERIOD − 1), reset counter to 0 and
//   invert clk_117Hz.  The one-line comparator hit fires once every 427,350
//   master clock cycles.
//
// ─────────────────────────────────────────────────────────────────────────────
// 50% Duty Cycle Proof
// ─────────────────────────────────────────────────────────────────────────────
//
//   HIGH phase: counter runs 0 → 427,349 while clk_117Hz = 1 → 427,350 ticks
//   LOW  phase: counter runs 0 → 427,349 while clk_117Hz = 0 → 427,350 ticks
//
//   Duty cycle = 427,350 / 854,700 = exactly 50.000%
//
// ─────────────────────────────────────────────────────────────────────────────
// Waveform Diagram (compressed, 4-tick half-period for illustration)
// ─────────────────────────────────────────────────────────────────────────────
//
//  clk_100MHz  ─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─
//               └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘
//  counter     [ 0 ][ 1 ][ 2 ][ 3 ][ 0 ][ 1 ][ 2 ][ 3 ]
//                                 ▲                   ▲
//                              MATCH               MATCH
//                            (toggle)            (toggle)
//  clk_117Hz   ─────────────────────┐ ┌─────────────────
//                                   └─┘
//              ◄──── HALF_PERIOD ticks ────►◄─── HALF_PERIOD ticks ───►
//
// ============================================================================

module horus_clock_divider (
    input  wire clk_100MHz,  // 100 MHz board master clock
    input  wire rst_n,       // Active-low synchronous reset
                             // (active-low to match horus_controller / horus_systolic_array
                             //  rst_n polarity — connect all three to the same reset bus)

    output reg  clk_117Hz    // 117 Hz output clock (50% duty cycle)
                             // Connect to horus_top clk input for acoustic-rate compute windows
);

    // =========================================================================
    // Timing constant
    // ─────────────────────────────────────────────────────────────────────────
    // HALF_PERIOD is the number of 100 MHz master-clock ticks per output
    // half-period.  Derived as:
    //
    //   HALF_PERIOD = round( f_master / (2 × f_target) )
    //               = round( 100,000,000 / 234 )
    //               = round( 427,350.427 )
    //               = 427,350
    //
    // Achieved output frequency:
    //   f_out = 100,000,000 / (2 × 427,350) = 117.000117 Hz  (+1.0 ppm)
    // =========================================================================
    localparam [19:0] HALF_PERIOD = 20'd427350;

    // =========================================================================
    // 20-bit accumulation counter
    // ─────────────────────────────────────────────────────────────────────────
    // Counts from 0 to (HALF_PERIOD − 1) inclusive — exactly HALF_PERIOD
    // master-clock ticks per phase.  20 bits wide to prevent overflow:
    //   Maximum counter value  : HALF_PERIOD − 1 = 427,349
    //   20-bit maximum         : 1,048,575
    //   Overflow-free headroom : 621,226 counts
    // =========================================================================
    reg [19:0] count;

    // =========================================================================
    // Synchronous divider — single always block
    // ─────────────────────────────────────────────────────────────────────────
    // On every rising edge of clk_100MHz:
    //   RESET branch : zero the counter and pull clk_117Hz low into a known state.
    //   MATCH branch : counter has reached the last tick of the current half-
    //                  period; reset it to 0 and invert the output in the same
    //                  clock edge — this is the toggle that produces the output
    //                  clock.  The comparator fires once per 427,350 ticks.
    //   DEFAULT      : advance the counter by 1.
    //
    // Non-blocking assignments ensure count and clk_117Hz update simultaneously
    // at the clock edge; there is no combinational feedback between them.
    // =========================================================================
    always @(posedge clk_100MHz or negedge rst_n) begin

        if (!rst_n) begin
            // ── Synchronous reset: known-state initialisation ─────────────────
            count     <= 20'd0;
            clk_117Hz <= 1'b0;

        end else if (count == HALF_PERIOD - 20'd1) begin
            // ── Comparator hit: half-period boundary reached ───────────────────
            // count == 427,349 means this is the 427,350th tick of the current
            // phase.  Reset the counter and toggle the output simultaneously.
            // The next rising edge begins a fresh half-period from count = 0.
            count     <= 20'd0;
            clk_117Hz <= ~clk_117Hz;   // Perfect 50% duty cycle toggle

        end else begin
            // ── Normal accumulation: advance the counter ──────────────────────
            count <= count + 20'd1;

        end
    end

endmodule
