# Horus NFE — FPGA Synthesis Guide

> **Status:** This guide describes the synthesis flow for Horus NFE RTL.
> The RTL implementation is currently in internal development. This document
> defines the exact methodology, constraint files, and resource targets for
> the public FPGA release. All tool commands and constraint content are ready
> to execute once the RTL is published.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Supported Devices & Tools](#2-supported-devices--tools)
3. [File Inventory](#3-file-inventory)
4. [Xilinx Vivado Flow](#4-xilinx-vivado-flow)
5. [Intel Quartus Prime Flow](#5-intel-quartus-prime-flow)
6. [Constraint Files](#6-constraint-files)
7. [Resource Estimates](#7-resource-estimates)
8. [Timing Closure Notes](#8-timing-closure-notes)
9. [Known Issues & Workarounds](#9-known-issues--workarounds)
10. [Simulation Before Synthesis](#10-simulation-before-synthesis)

---

## 1. Overview

The Horus NFE is a synthesizable RTL design written in Verilog-2001 with no
vendor-specific primitives, no IP cores, and no encrypted netlists. It is
designed to be **tool-agnostic**: the same source files compile under Yosys,
Vivado, Quartus Prime, and Synopsys Design Compiler without modification.

**Target clock frequency:** 250 MHz (4 ns period)

This target is realistic for a 1,523-cell datapath on:
- Xilinx Ultrascale+ (–2 speed grade): achievable, no retiming required
- Xilinx 7-Series (–2 speed grade): achievable with pipeline stages in place
- Intel Agilex (speed grade 2): achievable
- Intel Stratix 10 (–2 speed grade): achievable

The Guard-B 2-cycle pipeline (6 DFFs across the barrel-shift cloud) was
specifically dimensioned to allow 250 MHz closure. The critical path at
250 MHz is the MUL 14-bit product tree, not the barrel shifter.

---

## 2. Supported Devices & Tools

### 2.1 Recommended targets

| Vendor | Device Family | Speed Grade | Tool | Min. Tested Version |
|--------|--------------|:-----------:|------|:-------------------:|
| Xilinx / AMD | Ultrascale+ (e.g., XCKU5P) | –2 | Vivado | 2023.1 |
| Xilinx / AMD | 7-Series (e.g., XC7A200T) | –2 | Vivado | 2023.1 |
| Intel | Agilex 7 (AGIB027R29A1E2V) | 2 | Quartus Prime Pro | 23.1 |
| Intel | Stratix 10 GX | –2 | Quartus Prime Pro | 22.3 |
| Intel | Cyclone V (low-cost eval) | C6 | Quartus Prime Standard | 21.1 |

### 2.2 Open-source flow

| Tool | Version | Use |
|------|---------|-----|
| Yosys | ≥ 0.35 | Synthesis + gate count (any target) |
| nextpnr-xilinx | ≥ 2024 | Place-and-route for Xilinx (community) |
| nextpnr-ecp5 | ≥ 2024 | Lattice ECP5 target |
| Icarus Verilog | ≥ 11.0 | Pre-synthesis simulation |

---

## 3. File Inventory

All RTL files required for a complete system synthesis:

```
Core arithmetic (required for any configuration)
├── horus_nfe.v               Core 13-bit MAC — 1,523 cells
├── horus_pgate_ctrl.v        Power-proportional accumulator gate
└── horus_system.v            NFE + gate integration wrapper

2-D mesh (required for multi-tile)
├── horus_router.v            5-port XY router (N/S/E/W/Local)
└── horus_mesh_top.v          N×N mesh; instantiates router + system

Systolic array path (alternative to mesh)
├── horus_systolic_array.v    4×4 Output-Stationary array
├── horus_controller.v        One-Hot FSM controller
├── horus_input_buffer.v      4-channel skew buffer
├── horus_top.v               Systolic top integration
└── horus_axi_bridge.v        AXI4-Stream wrapper

Synthesis scripts (Yosys)
├── synth_script.ys           horus_nfe.v only
└── synthesize_system.ys      Full system

Constraint files (created in this guide)
├── horus_nfe_250mhz.xdc      Xilinx XDC — 250 MHz clock + I/O
└── horus_nfe_250mhz.sdc      Intel SDC — 250 MHz clock + I/O
```

**Do not include testbenches** (`tb_*.v`) in synthesis builds. They contain
`$dumpfile`, `$finish`, and other simulation-only constructs.

---

## 4. Xilinx Vivado Flow

### 4.1 Project creation (GUI)

1. Open Vivado → **Create Project** → RTL Project.
2. **Add Sources** — select all `.v` files from the inventory above (no `tb_`
   prefix files). Confirm language = Verilog 2001 (not SystemVerilog).
3. **Add Constraints** — add `horus_nfe_250mhz.xdc` (see §6.1).
4. **Select Part** — target device (e.g., `xcku5p-ffvb676-2-e` for Ultrascale+).

### 4.2 Project creation (Tcl script — recommended)

Save as `vivado_build.tcl` in the project root:

```tcl
# ============================================================
# vivado_build.tcl — Horus NFE Vivado build script
# Usage: vivado -mode batch -source vivado_build.tcl
# ============================================================

set project_name  "horus_nfe"
set device_part   "xcku5p-ffvb676-2-e"        ;# Ultrascale+, change as needed
set top_module    "horus_mesh_top"             ;# or horus_top for systolic path

create_project $project_name ./vivado_project -part $device_part -force
set_property target_language Verilog [current_project]

# Add RTL sources
add_files {
    horus_nfe.v
    horus_pgate_ctrl.v
    horus_system.v
    horus_router.v
    horus_mesh_top.v
}

# Alternative: systolic array path (comment out mesh files above and use these)
# add_files {
#     horus_nfe.v
#     horus_pgate_ctrl.v
#     horus_system.v
#     horus_systolic_array.v
#     horus_controller.v
#     horus_input_buffer.v
#     horus_top.v
#     horus_axi_bridge.v
# }

# Add constraints
add_files -fileset constrs_1 horus_nfe_250mhz.xdc

# Set top module
set_property top $top_module [current_fileset]

# Synthesis
launch_runs synth_1 -jobs 4
wait_on_run synth_1

# Implementation (place and route)
launch_runs impl_1 -jobs 4
wait_on_run impl_1

# Generate timing report
open_run impl_1
report_timing_summary -file timing_summary.rpt
report_utilization    -file utilization.rpt
report_power          -file power.rpt
```

**Run:**

```bash
vivado -mode batch -source vivado_build.tcl
```

### 4.3 Expected Vivado output

After successful synthesis and implementation:

```
Timing summary: WNS = +0.2 ns or better (250 MHz met)
LUT usage:      ~650–900 LUTs (horus_nfe core, Ultrascale+)
FF usage:       ~200–280 FFs
DSP usage:      0 DSPs (all arithmetic in LUTs by default)
BRAM usage:     0
```

*Note: these are estimates based on internal Yosys cell count (1,523 cells)
extrapolated to Xilinx LUT4/FF primitives. Vivado's cell mapping may differ.*

To force DSP48 usage for the 14-bit MUL product tree:

```tcl
set_property USE_DSP yes [get_cells */u_nfe/scale_reg*]
```

This reduces LUT count but adds DSP48 latency; verify timing closure after
enabling.

---

## 5. Intel Quartus Prime Flow

### 5.1 Project file (`.qsf`)

Save as `horus_nfe.qsf`:

```tcl
# ============================================================
# horus_nfe.qsf — Intel Quartus Prime settings file
# Tested: Quartus Prime Pro 23.1
# Target: Agilex 7 — change DEVICE as needed
# ============================================================

set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name MIN_CORE_JUNCTION_TEMP 0
set_global_assignment -name MAX_CORE_JUNCTION_TEMP 100
set_global_assignment -name DEVICE AGIB027R29A1E2VR2    # Agilex 7; change as needed
set_global_assignment -name FAMILY "Agilex 7"
set_global_assignment -name TOP_LEVEL_ENTITY horus_mesh_top

# RTL sources
set_global_assignment -name VERILOG_FILE horus_nfe.v
set_global_assignment -name VERILOG_FILE horus_pgate_ctrl.v
set_global_assignment -name VERILOG_FILE horus_system.v
set_global_assignment -name VERILOG_FILE horus_router.v
set_global_assignment -name VERILOG_FILE horus_mesh_top.v

# Constraint file
set_global_assignment -name SDC_FILE horus_nfe_250mhz.sdc

# Synthesis settings
set_global_assignment -name VERILOG_INPUT_VERSION VERILOG_2001
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
set_global_assignment -name PHYSICAL_SYNTHESIS_EFFORT NORMAL
set_global_assignment -name FITTER_EFFORT STANDARD_FIT
```

**Compile:**

```bash
quartus_sh --flow compile horus_nfe
```

**Generate reports:**

```bash
quartus_sta horus_nfe --do_report_timing
```

### 5.2 Expected Quartus output

```
Timing Analyzer: Slack = +0.1 ns or better at 250 MHz
ALM usage:  ~400–550 ALMs (Agilex 7)
FF usage:   ~200–280 registers
DSP usage:  0 (optional, see §8)
M20K usage: 0
```

---

## 6. Constraint Files

### 6.1 Xilinx XDC — `horus_nfe_250mhz.xdc`

```tcl
# ============================================================
# horus_nfe_250mhz.xdc — Xilinx Vivado constraint file
# Target frequency: 250 MHz (4.000 ns period)
# Applies to: horus_mesh_top, horus_top, or horus_nfe standalone
#
# FPGA pin assignments below are placeholders using Xilinx
# Ultrascale+ (xcku5p-ffvb676-2-e) as reference.
# Update LOC constraints to match your physical board pinout.
# ============================================================

# ── Primary clock ─────────────────────────────────────────────────────────────
# Connect FPGA oscillator or PLL output to clk port.
# 250 MHz = 4.000 ns period.
create_clock -period 4.000 -name sys_clk [get_ports clk]

# ── Input timing (clk domain) ─────────────────────────────────────────────────
# All inputs arrive synchronous to sys_clk.
# Assume 1.5 ns board propagation + setup time margin.
set_input_delay  -clock sys_clk -max 1.500 [get_ports {rst_n op_sel* accum_en \
    accum_clr host_tile_depth* weight_flat* west_din_flat* west_vin_flat*}]
set_input_delay  -clock sys_clk -min 0.500 [get_ports {rst_n op_sel* accum_en \
    accum_clr host_tile_depth* weight_flat* west_din_flat* west_vin_flat*}]

# ── Output timing (clk domain) ────────────────────────────────────────────────
# Downstream logic must meet 1.5 ns hold + 1.5 ns setup at receiver.
set_output_delay -clock sys_clk -max 1.500 [get_ports {west_rin_flat* \
    result_flat* accum_flat*}]
set_output_delay -clock sys_clk -min 0.500 [get_ports {west_rin_flat* \
    result_flat* accum_flat*}]

# ── False paths ───────────────────────────────────────────────────────────────
# rst_n is asynchronous; no multi-cycle path constraint needed.
set_false_path -from [get_ports rst_n]

# ── Physical placement hints (Ultrascale+ XCKU5P FFVB676) ─────────────────────
# Update with actual board-level pin assignments.
# set_property PACKAGE_PIN <PIN_ID>   [get_ports clk]
# set_property IOSTANDARD  LVCMOS18   [get_ports clk]
# set_property PACKAGE_PIN <PIN_ID>   [get_ports rst_n]
# set_property IOSTANDARD  LVCMOS18   [get_ports rst_n]
#
# For wide buses (weight_flat, result_flat), use an IOB region or
# OLOGIC/IOLOGIC primitives for timing closure at 250 MHz.

# ── Pblock suggestion (optional, improves timing) ─────────────────────────────
# Confine mesh tiles to a rectangular region to reduce routing congestion
# for the 2-D inter-tile link arrays.
#
# create_pblock pblock_mesh
# add_cells_to_pblock pblock_mesh [get_cells -hierarchical -filter {NAME =~ */GEN_ROW*}]
# resize_pblock pblock_mesh -add SLICE_X0Y0:SLICE_X49Y99
```

### 6.2 Intel SDC — `horus_nfe_250mhz.sdc`

```tcl
# ============================================================
# horus_nfe_250mhz.sdc — Intel Quartus Prime SDC constraint
# Target frequency: 250 MHz (4.000 ns period)
# Compatible: Quartus Prime Standard 21.x, Pro 22.x/23.x
# ============================================================

# ── Primary clock ─────────────────────────────────────────────────────────────
create_clock -name sys_clk -period 4.000 [get_ports clk]

# ── Input timing ──────────────────────────────────────────────────────────────
set_input_delay -clock sys_clk -max 1.500 [get_ports {rst_n}]
set_input_delay -clock sys_clk -min 0.500 [get_ports {rst_n}]

set_input_delay -clock sys_clk -max 1.500 \
    [get_ports {op_sel[*] accum_en accum_clr host_tile_depth[*]}]
set_input_delay -clock sys_clk -min 0.500 \
    [get_ports {op_sel[*] accum_en accum_clr host_tile_depth[*]}]

set_input_delay -clock sys_clk -max 1.500 \
    [get_ports {weight_flat[*] west_din_flat[*] west_vin_flat[*]}]
set_input_delay -clock sys_clk -min 0.500 \
    [get_ports {weight_flat[*] west_din_flat[*] west_vin_flat[*]}]

# ── Output timing ─────────────────────────────────────────────────────────────
set_output_delay -clock sys_clk -max 1.500 \
    [get_ports {west_rin_flat[*] result_flat[*] accum_flat[*]}]
set_output_delay -clock sys_clk -min 0.500 \
    [get_ports {west_rin_flat[*] result_flat[*] accum_flat[*]}]

# ── False paths ───────────────────────────────────────────────────────────────
set_false_path -from [get_ports rst_n]

# ── Timing exceptions for Guard-B 2-cycle path ────────────────────────────────
# The Guard-B SUB pipeline is intentionally 2 cycles.
# If the tool infers a multi-cycle path violation, declare it explicitly:
#
# set_multicycle_path -setup 2 -from [get_registers *sub_p1_*] \
#                               -to   [get_registers *result*]
# set_multicycle_path -hold  1 -from [get_registers *sub_p1_*] \
#                               -to   [get_registers *result*]
```

---

## 7. Resource Estimates

*Based on internal Yosys synthesis (1,523 cells for horus_nfe core).
Vendor LUT mapping varies by optimizer and target architecture.*

### 7.1 NFE core only (`horus_nfe.v` standalone)

| Resource | Yosys cells | Xilinx LUT6 (est.) | Xilinx FF (est.) | Intel ALM (est.) |
|----------|:-----------:|:------------------:|:----------------:|:----------------:|
| Combinational (MUL, ADD, SUB) | ~1,100 | ~550 | 0 | ~350 |
| Registers (result, accum, pipeline) | ~423 | 0 | ~210 | 0 |
| **Total** | **~1,523** | **~550** | **~210** | **~350** |
| DSPs (optional, MUL tree) | 0 | 0 (1 DSP48 if forced) | 0 | 0 (1 DSP if forced) |
| BRAMs / M20Ks | 0 | 0 | 0 | 0 |

### 7.2 Full mesh system (4×4 = 16 tiles)

| Component | Instances | Multiplier | Xilinx LUT6 (est.) | Xilinx FF (est.) |
|-----------|:---------:|:----------:|:------------------:|:----------------:|
| `horus_nfe` | 16 | 16× | ~8,800 | ~3,360 |
| `horus_pgate_ctrl` | 16 | 16× | ~80 | 0 |
| `horus_system` (wrapper logic) | 16 | 16× | ~160 | ~80 |
| `horus_router` | 16 | 16× | ~800 | ~320 |
| **Total (4×4 mesh)** | — | — | **~9,840** | **~3,760** |

This footprint fits comfortably within:
- Xilinx Artix-7 XC7A200T (134K LUTs, 269K FFs) — **7.3% LUT utilization**
- Xilinx Kintex Ultrascale+ XCKU5P (523K LUTs) — **1.9% LUT utilization**
- Intel Cyclone V 5CGXFC9 (56K ALMs) — ~17.5% (tight, use as minimum target)

---

## 8. Timing Closure Notes

### 8.1 Critical paths at 250 MHz

The three paths most likely to limit timing closure, in order of concern:

| Path | Location | Depth (gates) | Mitigation |
|------|----------|:-------------:|------------|
| MUL 14-bit product tree | `horus_nfe` — `scale_reg` | ~18 LUT levels | Enable DSP48/DSP inference |
| Guard-B barrel-shift cloud | `horus_nfe` — `sub_p1_*` Stage 1 | ~12 LUT levels | Already pipelined (2 cycles) |
| Accumulator adder (`accum_reg + computed`) | `horus_nfe` — ADD/MUL path | ~14 LUT levels | Retiming if needed |

### 8.2 DSP inference for MUL

The `scale_reg = {1'b1, m_a} * {1'b1, m_b}` expression is a 7×7 multiplier
producing a 14-bit result. Most synthesis tools will infer a DSP primitive
for this. To control inference explicitly:

**Vivado:**
```tcl
# Force DSP48 inference
set_property USE_DSP yes [get_cells -hierarchical -filter {NAME =~ *scale_reg*}]

# Prevent DSP48 (all LUT)
set_property USE_DSP no  [get_cells -hierarchical -filter {NAME =~ *scale_reg*}]
```

**Quartus:**
```tcl
# In .qsf or as synthesis attribute in RTL:
# (* multstyle = "dsp" *) reg [19:0] scale_reg;   -- in horus_nfe.v
```

*Recommendation:* Use DSP inference when targeting speed-critical builds.
Use LUT-only when DSPs are needed elsewhere or for the smallest-area build.

### 8.3 Reset strategy

`horus_nfe` uses `negedge rst_n` in its sensitivity list (asynchronous
assert, synchronous release). Ensure the reset tree meets the following:

- Reset tree maximum fanout: < 128 registers (Vivado BUFG for wider)
- For large meshes (16+ tiles): insert a reset synchronizer per tile clock
  domain if using multiple clock regions.

### 8.4 Wide output buses

`weight_flat` and `result_flat` are `MESH_SIZE² × 13`-bit flat buses. For
a 4×4 mesh these are 208-bit buses. At 250 MHz these will require:

- **Vivado:** Place output registers in IOBs or add a register-retiming
  attribute: `set_property IOB TRUE [get_cells -hierarchical *result_flat*]`
- **Quartus:** Enable register packing to IOEs in Fitter settings.

---

## 9. Known Issues & Workarounds

| Issue | Symptom | Workaround |
|-------|---------|------------|
| `generate` block hierarchy references in simulation only | `GEN_ROW[i].GEN_COL[j].loc_v` signals not visible in synthesis netlist | Expected — these are simulation-only hierarchical probes. Use ILA/SignalTap in hardware |
| Vivado infers `RAMB18` for large `weight_flat` | LUT RAM inference on wide buses | Set `RAM_STYLE = "distributed"` attribute or use `keep_hierarchy` |
| Quartus: `always @(posedge clk or negedge rst_n)` warning | "Reset should use synchronous reset" warning | Intentional. Asynchronous assert is by design; suppress in `.qsf` with `set_global_assignment -name MESSAGE_DISABLE 10240` |
| Blocking assignments in always block | Synthesis warning on `scale_reg = ...` | Intentional (combinational intermediate within clocked block). Suppress if clean |
| `/* unused */` port connections | Not valid Verilog syntax in some tools | Ports use `.port()` empty-connection syntax; should parse correctly |

---

## 10. Simulation Before Synthesis

**Always simulate before synthesizing.** The simulation harness for the
complete system is self-contained and must produce 26/26 passing tests before
any synthesis attempt is considered valid:

```bash
# Step 1: Core arithmetic verification
iverilog -Wall -o sim_nfe horus_nfe.v tb_horus_nfe.v && vvp sim_nfe

# Step 2: Power-gate corner cases
iverilog -Wall -o sim_pgate \
    horus_pgate_ctrl.v tb_horus_pgate_ctrl.v && vvp sim_pgate

# Step 3: Router verification (8/8)
iverilog -Wall -o sim_rtr \
    horus_router.v tb_horus_router.v && vvp sim_rtr

# Step 4: Mesh integration (7/7) — the gate-level equivalent of the GEMM tile
iverilog -Wall -o sim_mesh \
    tb_horus_mesh_top.v horus_mesh_top.v horus_router.v \
    horus_system.v horus_nfe.v horus_pgate_ctrl.v && vvp sim_mesh

# All 26 tests must print PASS before proceeding to synthesis.
```

**Post-synthesis simulation (recommended):**

After Vivado synthesis, export the synthesized netlist and re-simulate using
the vendor simulation model:

```bash
# Vivado: export post-synthesis netlist
write_verilog -mode funcsim horus_nfe_synth.v

# Re-simulate with gate-level model
iverilog -Wall horus_nfe_synth.v tb_horus_nfe.v \
    -y $XILINX_VIVADO/data/verilog/src/unisims/
vvp sim_synth
```

---

*Horus NFE FPGA Guide · 250 MHz target · Verilog-2001 · Tool-agnostic RTL ·
Vivado + Quartus Prime · Constraint files included*
