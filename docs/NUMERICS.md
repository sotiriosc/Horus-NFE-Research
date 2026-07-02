# Horus NFE — Numeric Encoding Reference

**Document scope:** canonical encoding rules for the 13-bit Native Fractional
Engine (NFE) word as defined in `horus_nfe.v` v3 (Bias-32, Implicit Leading
Bit).  Use this document to resolve any discrepancy between a test vector
and the architectural specification.

---

## 1  NFE Word Layout

```
Bit  12       11..6          5..0
     ─────    ──────────     ──────────
     Sign S   Exponent E     Fraction f
              (6-bit, biased) (6-bit)
```

| Field | Width | Interpretation |
|---|---|---|
| `S` | 1 | 0 = positive, 1 = negative |
| `E` | 6 | **Stored** (biased) exponent. `actual_E = E − 32` |
| `f` | 6 | Fractional mantissa. Implicit leading 1: full mantissa = `1.f` = `64 + f` |

**Encoded value:** `V = (−1)^S × 2^(E−32) × (1 + f/64)`

---

## 2  Bias-32 Normalisation — Established Constants

The Bias-32 scheme was introduced in **horus_nfe v3** (commit `eee0e21`).
The following table lists canonical encodings for common constants.

| Real Value | stored_E | f | 13-bit word | Notes |
|---|---|---|---|---|
| 0.25 | 30 | 0 | `13'h780` | MUL(0.5, 0.5) result |
| 0.5 | 31 | 0 | **`13'h7C0`** | Canonical 0.5 |
| 1.0 | 32 | 0 | `13'h800` | "1.0 point" (actual_E = 0) |
| 1.5 | 32 | 32 | `13'h820` | |
| 2.0 | 33 | 0 | `13'h840` | |
| Maximum | 63 | 63 | `13'hFFF` | ≈ 4.26 × 10⁹ |
| Minimum | 0 | 0 | `13'h000` | ≈ 2.33 × 10⁻¹⁰ (Underflow Floor) |

---

## 3  Deprecated Test Vector

> **`13'h020` is deprecated.**  Do not use it to represent 0.5.

### Why it was wrong

`13'h020` decodes as:

```
bit[12]=0, bits[11:6]=000000, bits[5:0]=100000
→  S=0, stored_E=0, f=32
→  actual_E = 0 − 32 = −32
→  V = 1.0 × (1 + 32/64) × 2^(−32) ≈ 3.49 × 10^−10
```

This is **not** 0.5.  The confusion arose because `13'h020` was authored
against an earlier, pre-Bias iteration of the NFE where the exponent field
was zero-biased.  Under that scheme `E=0` meant `actual_E=0`, so f=32 gave
`1.5 × 2^0 × 0.5 = 0.5` — but that scheme was superseded by v3.

### Migration

Replace every occurrence of `13'h020` used to represent 0.5 with `13'h7C0`.

```verilog
// BEFORE (deprecated — pre-Bias-32 artifact)
localparam [12:0] HALF = 13'h020;

// AFTER (correct — Bias-32 v3)
localparam [12:0] HALF = 13'h7C0;  // stored_E=31, f=0 → 0.5
```

---

## 4  Multiplication Encoding Arithmetic

For a MUL of two values with exponents `E_a`, `E_b` and fractions `f_a`, `f_b`:

```
A = 64 + f_a           (full 7-bit mantissa of op_a)
B = 64 + f_b           (full 7-bit mantissa of op_b)
P = A × B              (14-bit product; range [4096, 16129])

if P[13] = 0:          f_result = P[11:6],  no extra E increment
if P[13] = 1:          f_result = P[12:7],  E += 1

stored_E_result = E_a + E_b − 32  [+ 1 if P[13] = 1]
```

**Double-bias correction:** adding two Bias-32 exponents introduces a bias
of 64; subtracting EXP\_BIAS=32 once corrects this back to a single-bias
result, preserving the invariant `actual_E = stored_E − 32`.

### Worked example: MUL(0.5, 0.5)

```
op_a = op_b = 13'h7C0  (stored_E=31, f=0)
A = B = 64
P = 4096  →  P[13]=0
f_result = P[11:6] = 0
stored_E_result = 31 + 31 − 32 = 30
result = 13'h780  (decodes to 0.25 ✓)
```

---

## 5  Accumulator Semantics

The 32-bit accumulator (`accum_out`) stores the **arithmetic sum of the
13-bit integer words**, zero-extended to 32 bits:

```verilog
accum_reg <= accum_reg + {{19{1'b0}}, result};
```

This means `accum_out` holds the sum of raw NFE words, not decoded float
values.  When computing expected values for testbenches:

```
EXPECTED = STREAM_CYCLES × result_word_integer × PEs_per_row
```

For the canonical system testbench (`tb_horus_system.v`):

```
result_word = 13'h780 = 1920
EXPECTED    = 7 × 1920 × 4 = 53760  (0x0000D200)
```

---

## 6  Changelog

| Version | Change |
|---|---|
| v3 (Bias-32) | Exponent bias of 32 established. `EXP_BIAS = 6'd32` in `horus_nfe.v`. |
| v2 (Hidden Bit) | Implicit leading-1 mantissa introduced. |
| v1 | Zero-biased exponent (deprecated; no public release). |

---

*This document is part of the Horus NFE public release.*
*License: CERN-OHL-S-2.0 — see LICENSE.*
