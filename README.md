# Horus NFE

**A Deterministic, Quantized Event Accumulation Engine**

Horus NFE is an open-hardware inference substrate built around a 13-bit Native
Fractional Engine (NFE), a systolic MAC mesh, and per-tile Quantized Feature
Event Counters. It targets **high-throughput, stable, saturating inference**
for edge AI workloads — not IEEE-754 scientific arithmetic.

**License:** [CERN-OHL-S-2.0](LICENSE)

---

## Status

| Layer | Status |
|-------|--------|
| **Core MAC/NFE** | Verified — ADD/SUB/MUL unit tests, C-model vs FP64, Bias-32 hidden-bit encoding |
| **Accumulation stability** | Verified — floor, saturate, mixed tiny/large propagate (`tb_boundary_stress`) |
| **Scaling (16-tile)** | In-Development — 4×4 systolic + 2×2 mesh sim-verified; 16-tile mesh in progress |

RTL simulation: **26/26 tests pass** (`make test`). Synthesis constraints target
250 MHz on Xilinx Ultrascale+ / Intel Agilex (timing not closed on silicon).

---

## Repository Layout

```
horus_engine/
├── README.md           ← this file
├── LICENSE
├── Makefile            → delegates to sim/
├── rtl/                ← synthesizable Verilog (horus_nfe, mesh, systolic)
├── tb/                 ← Icarus Verilog testbenches
├── sim/                ← Makefile, C-model, analysis scripts, build artifacts
└── docs/               ← architecture, numerics, benchmarks, FPGA guide
```

---

## Quick Start

```bash
# Full RTL regression (26/26)
make test

# 1024-cycle deep-chain fidelity benchmark + plots
make fidelity

# C-model statistical proof (10M iterations)
make sim_c

# Python encoding / adversarial analysis
make analysis
```

All simulation targets run from `sim/`; the root `Makefile` forwards to it.

**Requirements:** Icarus Verilog ≥ 11, GCC, Python 3.8+ (matplotlib for fidelity plots).

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/ARCHITECTURE_PHILOSOPHY.md](docs/ARCHITECTURE_PHILOSOPHY.md) | Digital Physics paradigm; QEA identity; IEEE-754 contrast |
| [docs/DESIGN_LIMITATIONS.md](docs/DESIGN_LIMITATIONS.md) | Architectural trade-offs; fidelity vs dynamic range; v4 roadmap |
| [docs/NUMERICS.md](docs/NUMERICS.md) | Bias-32 encoding reference and canonical constants |
| [docs/DATASHEET.md](docs/DATASHEET.md) | Port lists, timing, and module integration |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | Benchmark methodology and measured results |
| [docs/FPGA_GUIDE.md](docs/FPGA_GUIDE.md) | Vivado/Quartus constraints and bring-up |
| [docs/NOTICE.md](docs/NOTICE.md) | Attribution and third-party notices |

---

## Fidelity Analysis

A 1024-cycle **deep-chain accumulation** stress test (`tb/tb_fidelity_benchmark.v`)
injects small random fractional deltas (ADD_FRAC) with feedback re-quantization
and compares the hardware running state against an ideal FP64 golden model.

| Milestone | Cycle | Behavior |
|-----------|------:|----------|
| **1% divergence** | **278** | Hardware running state departs >1% from FP64 ideal |
| **Saturation plateau** | **384** | Horus output clamps (~4.26×10⁹); FP64 golden continues growing |

Mean relative error over the full chain: **~3.94%**. This curve is the
efficiency-vs-fidelity trade-off: single-cycle MAC, bounded 13-bit dynamic range,
and saturating arithmetic vs unbounded FP64 precision.

Reproduce:

```bash
make fidelity
# → sim/fidelity_benchmark.csv
# → sim/fidelity_plot.png
# → sim/fidelity_error_plot.png
```

See [docs/DESIGN_LIMITATIONS.md §2](docs/DESIGN_LIMITATIONS.md#2-fidelity-analysis-vs-dynamic-range)
for architectural interpretation.

---

## RTL Overview

| Module | Role |
|--------|------|
| `horus_nfe` | 13-bit MAC core — ADD/SUB/MUL, Thoth Rollover, Guard-B SUB pipeline |
| `horus_system` | NFE + power-gate tile wrapper |
| `horus_systolic_array` | 4×4 output-stationary PE grid |
| `horus_mesh_top` | 2×2 tile mesh with XY router |
| `horus_top` | AXI4-Stream host interface + controller |

Format: **13-bit NFE v3** — 1 sign + 6 biased exponent (Bias-32) + 6 fraction
with implicit leading bit. See [docs/NUMERICS.md](docs/NUMERICS.md).

---

## Citation

```bibtex
@misc{horus_nfe_2026,
  title        = {Horus NFE: A Deterministic, Quantized Event Accumulation Engine},
  author       = {Horus (Native Fractional Engine project)},
  year         = {2026},
  howpublished = {Open Hardware, CERN-OHL-S-2.0},
  note         = {RTL, C-model, and documentation publicly available}
}
```

---

*Horus NFE · Quantized Event Accumulation Engine · v3 (Bias-32)*
