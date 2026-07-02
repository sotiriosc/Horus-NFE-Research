# =============================================================================
# Horus NFE — Simulation Makefile
# =============================================================================
#
# Run from this directory:  cd sim && make test
#
# Requirements: Icarus Verilog >= 11  (iverilog / vvp)
#               GCC or Clang          (C-model)
#               Python 3.8+           (analysis scripts; matplotlib for fidelity)
#
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
CC       ?= gcc
PYTHON   ?= python3

RTL      := ../rtl
TB       := ../tb
IVFLAGS  := -Wall -g2012
CFLAGS   := -O2

# -----------------------------------------------------------------------------
# RTL source groups
# -----------------------------------------------------------------------------
SRC_CORE     := $(RTL)/horus_nfe.v $(RTL)/horus_pgate_ctrl.v $(RTL)/horus_system.v
SRC_MESH     := $(RTL)/horus_router.v $(RTL)/horus_mesh_top.v
SRC_WRAPPER  := $(RTL)/horus_nfe_wrapper.v
SRC_SYSTOLIC := $(RTL)/horus_systolic_array.v $(RTL)/horus_controller.v \
                $(RTL)/horus_input_buffer.v $(RTL)/horus_top.v

# =============================================================================
.PHONY: all hbs11 hbs12 hbs13 hbs14 hbs_c2 hbs_c5 hbs_c6 hbs_c7
all: sim_mesh
	@echo ""
	@echo "Running Horus Mesh Testbench (7/7 tests expected)..."
	@echo "-----------------------------------------------------"
	$(VVP) sim_mesh
	@echo ""
	@echo "Done. Check output above for PASS/FAIL counts."

# =============================================================================
# SIMULATION TARGETS
# =============================================================================

sim_mesh: $(TB)/tb_horus_mesh_top.v $(SRC_CORE) $(SRC_MESH)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_nfe: $(TB)/tb_horus_nfe.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_pgate: $(TB)/tb_horus_pgate_ctrl.v $(RTL)/horus_pgate_ctrl.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_router: $(TB)/tb_horus_router.v $(RTL)/horus_router.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_wrapper: $(TB)/tb_horus_nfe_wrapper.v $(SRC_WRAPPER) $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_system: $(TB)/tb_horus_system.v $(RTL)/horus_nfe.v $(SRC_SYSTOLIC) $(RTL)/horus_input_buffer.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_boundary: $(TB)/tb_boundary_stress.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_fidelity: $(TB)/tb_fidelity_benchmark.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_hbs: $(TB)/tb_hbs_core_stability.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: hbs_stability
hbs_stability: sim_hbs
	@echo ""
	@echo "Running HBS Core Stability Suite (failure mapping)..."
	$(VVP) sim_hbs
	@echo ""
	@echo "Logs: HBS_CORE_MASTER_INDEX.log + HBS_CORE_TEST_01..06_*.log"

sim_hfd: $(TB)/tb_horus_failure_domain.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_cancel: $(TB)/tb_horus_cancel_analysis.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_comp: $(TB)/tb_horus_composition_analysis.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# HBS-11 policy validation: horus_system + horus_controller only
sim_hbs11: $(TB)/tb_hbs11_policy_validation.v $(SRC_CORE) $(RTL)/horus_controller.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: hbs11
hbs11: sim_hbs11
	@echo ""
	@echo "Running HBS-11 Execution Policy Validation Suite..."
	$(VVP) sim_hbs11
	@echo ""
	$(PYTHON) analyze_hbs11.py
	@echo ""
	@echo "Output: HBS11_POLICY_VALIDATION.csv + HBS11_POLICY_SUMMARY.log"

# HBS-12 arithmetic boundary mapping: horus_system only (mode_tag=000)
sim_hbs12: $(TB)/tb_hbs12_arithmetic_boundary.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: hbs12
hbs12: sim_hbs12
	@echo ""
	@echo "Running HBS-12 Arithmetic Boundary Mapping Suite..."
	$(VVP) sim_hbs12
	@echo ""
	$(PYTHON) analyze_hbs12.py
	@echo ""
	@echo "Output: HBS12_ARITHMETIC_BOUNDARY.csv + HBS12_SUMMARY.log"

# HBS-13 boundary gap characterization: horus_system only (mode_tag=000)
sim_hbs13: $(TB)/tb_hbs13_boundary_gap.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: hbs13
hbs13: sim_hbs13
	@echo ""
	@echo "Running HBS-13 Boundary Gap Characterization Suite..."
	$(VVP) sim_hbs13
	@echo ""
	$(PYTHON) analyze_hbs13.py
	@echo ""
	@echo "Output: HBS13_BOUNDARY_GAP.csv + HBS13_SUMMARY.log"

.PHONY: failure_domain cancel_analysis composition_analysis
failure_domain: sim_hfd
	@echo ""
	@echo "Running HORUS Failure-Domain Analysis..."
	$(VVP) sim_hfd
	@echo ""
	@echo "Output: HORUS_WEAKNESS_MAP.log + HFD_TEST_01..06_*.log"

cancel_analysis: sim_cancel
	@echo ""
	@echo "Running TEST 9 cancellation structure study..."
	$(VVP) sim_cancel
	@echo ""
	$(PYTHON) analyze_cancellation.py
	@echo ""
	@echo "Output: cancel_analysis.csv + TEST_09_SUMMARY.log"

composition_analysis: sim_comp
	@echo ""
	@echo "Running TEST 10 composition stress study..."
	$(VVP) sim_comp
	@echo ""
	$(PYTHON) analyze_composition.py
	@echo ""
	@echo "Output: composition_analysis.csv + TEST_10_SUMMARY.log"

# =============================================================================
.PHONY: test
test: sim_nfe sim_pgate sim_router sim_wrapper sim_mesh
	@echo ""
	@echo "======================================================"
	@echo "  Horus NFE — Full Simulation Suite"
	@echo "======================================================"
	@echo ""
	@echo "[1/5] NFE arithmetic core (4/4 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_nfe
	@echo ""
	@echo "[2/5] Power-gate controller (3/3 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_pgate
	@echo ""
	@echo "[3/5] XY Router (8/8 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_router
	@echo ""
	@echo "[4/5] Tile-depth wrapper (4/4 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_wrapper
	@echo ""
	@echo "[5/5] 2-D Mesh top (7/7 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_mesh
	@echo ""
	@echo "======================================================"
	@echo "  26 tests expected total. Review output above."
	@echo "======================================================"

# =============================================================================
.PHONY: sim_c
sim_c: horus_sim
	@echo ""
	@echo "Running C-model (10M iterations per operation)..."
	./horus_sim

horus_sim: horus_sim.c
	$(CC) $(CFLAGS) -o $@ $< -lm

.PHONY: fidelity
fidelity: sim_fidelity
	@echo ""
	@echo "Running 1024-cycle fidelity benchmark..."
	$(VVP) sim_fidelity
	@echo ""
	$(PYTHON) analyze_fidelity.py

.PHONY: analysis
analysis:
	@echo "Running NFE precision analysis..."
	$(PYTHON) horus_nfe_analysis.py

# =============================================================================
.PHONY: wave_mesh wave_router wave_nfe
wave_mesh: sim_mesh
	$(VVP) sim_mesh
	gtkwave tb_horus_mesh_top.vcd &

wave_router: sim_router
	$(VVP) sim_router
	gtkwave tb_horus_router.vcd &

wave_nfe: sim_nfe
	$(VVP) sim_nfe
	gtkwave dump.vcd &

.PHONY: clean
clean:
	rm -f sim_nfe sim_pgate sim_router sim_wrapper sim_mesh sim_system \
	      sim_fidelity sim_boundary sim_hbs sim_hfd sim_cancel sim_comp horus_sim
	rm -f *.vcd fidelity_benchmark.csv fidelity_plot.png fidelity_error_plot.png
	rm -f HBS_CORE_*.log HFD_TEST_*.log HORUS_WEAKNESS_MAP.log
	rm -f HBS11_POLICY_VALIDATION.csv HBS11_POLICY_SUMMARY.log sim_hbs11
	rm -f HBS12_ARITHMETIC_BOUNDARY.csv HBS12_SUMMARY.log sim_hbs12
	rm -f HBS13_BOUNDARY_GAP.csv HBS13_SUMMARY.log sim_hbs13
	rm -f HBS14_SYSTEM_INTEGRATION.csv HBS14_SUMMARY.log sim_hbs14
	rm -f HBS_C2_LIVE_SIM.csv HBS_C2_LIVE_SUMMARY.log sim_hbs_c2 \
	      hbs_c2_state_space_ascii.txt hbs_c2_e_density.png \
	      hbs_c2_uf_ovf_timeline.png hbs_c2_accum_drift.png hbs_c2_mode_region_hm.png
	rm -f HBS_C5_KERNEL_STRESS.csv HBS_C5_KERNEL_SUMMARY.log sim_hbs_c5 \
	      hbs_c5_mode_surface_classA.png hbs_c5_mode_surface_classB.png \
	      hbs_c5_mode_surface_classC.png hbs_c5_mode_surface_classD.png \
	      hbs_c5_mode_surface_all.png hbs_c5_action_manifold.png
	rm -f HBS_C6_REAL_WORLD.csv HBS_C6_SUMMARY.log sim_hbs_c6 \
	      hbs_c6_workload_heatmap.png hbs_c6_collapse_exposure.png \
	      hbs_c6_cancellation_drift.png hbs_c6_deepchain_degradation.png
	rm -f HBS_C7_FAILURE_DOMAIN.csv HBS_C7_SUMMARY.log sim_hbs_c7 \
	      hbs_c7_failure_heatmap.png hbs_c7_r2_exponent_drift.png \
	      hbs_c7_r1_residual_growth.png hbs_c7_recovery_comparison.png
	@echo "Cleaned generated binaries and artifacts."

.PHONY: help
help:
	@echo ""
	@echo "Horus NFE — Simulation targets (run from sim/)"
	@echo "----------------------------------------------"
	@echo "  make              Mesh testbench (7/7, default)"
	@echo "  make test         Full suite (26/26)"
	@echo "  make fidelity     1024-cycle fidelity benchmark + plots"
	@echo "  make sim_c        C-model 10M-iteration proof"
	@echo "  make analysis     Python precision analysis"
	@echo "  make sim_boundary Boundary-stress testbench"
	@echo "  make failure_domain HORUS failure-domain analysis (6 tests)"
	@echo "  make hbs_stability  HBS core failure-mapping suite (6 tests)"
	@echo "  make cancel_analysis  TEST 9 cancellation residual study"
	@echo "  make composition_analysis TEST 10 composition stress study"
	@echo "  make hbs11            HBS-11 execution policy validation suite"
	@echo "  make hbs12            HBS-12 arithmetic boundary mapping suite"
	@echo "  make hbs13            HBS-13 boundary gap characterization suite"
	@echo "  make hbs14            HBS-14 end-to-end system consistency suite"
	@echo "  make hbs_c2           HBS-C2 live system observation harness"
	@echo "  make hbs_c5           HBS-C5 C4 kernel decision surface stress-test"
	@echo "  make hbs_c6           HBS-C6 adversarial real-world workload stress-test"
	@echo "  make hbs_c7           HBS-C7 failure-domain isolation suite"

# HBS-14 end-to-end system consistency: horus_system + horus_systolic_array
sim_hbs14: $(TB)/tb_hbs14_system_integration.v $(SRC_CORE) $(RTL)/horus_systolic_array.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs14: sim_hbs14
	@echo ""
	@echo "Running HBS-14 End-to-End System Consistency Suite..."
	$(VVP) sim_hbs14
	@echo ""
	$(PYTHON) analyze_hbs14.py
	@echo ""
	@echo "Output: HBS14_SYSTEM_INTEGRATION.csv + HBS14_SUMMARY.log"
	@echo ""

# ── HBS-C2: Live System Observation Harness ──────────────────────────────────
sim_hbs_c2: $(TB)/tb_hbs_c2_live_sim.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c2: sim_hbs_c2
	@echo ""
	@echo "Running HBS-C2 Live System Observation Harness..."
	$(VVP) sim_hbs_c2
	@echo ""
	$(PYTHON) analyze_hbs_c2_live.py
	@echo ""
	@echo "Outputs: HBS_C2_LIVE_SIM.csv  HBS_C2_LIVE_SUMMARY.log"
	@echo "         hbs_c2_e_density.png  hbs_c2_uf_ovf_timeline.png"
	@echo "         hbs_c2_accum_drift.png  hbs_c2_mode_region_hm.png"
	@echo ""

# ── HBS-C5: C4 Kernel Decision Surface Exhaustive Stress-Test ────────────────
# Pure combinational testbench — no RTL DUT, no horus_system import.
# Tests all 4 × 64 × 32 = 8,192 kernel input combinations.
sim_hbs_c5: $(TB)/tb_hbs_c5_kernel_stress.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c5: sim_hbs_c5
	@echo ""
	@echo "Running HBS-C5 C4 Kernel Decision Surface Stress-Test..."
	$(VVP) sim_hbs_c5
	@echo ""
	$(PYTHON) analyze_hbs_c5_kernel_stress.py
	@echo ""
	@echo "Outputs: HBS_C5_KERNEL_STRESS.csv  HBS_C5_KERNEL_SUMMARY.log"
	@echo "         hbs_c5_mode_surface_classA/B/C/D.png"
	@echo "         hbs_c5_mode_surface_all.png  hbs_c5_action_manifold.png"
	@echo ""

# ── HBS-C6: Adversarial Real-World Workload Stress-Test ──────────────────────
# Tests horus_system DUT with 5 adversarial workloads × 500 cycles = 2500 cycles.
sim_hbs_c6: $(TB)/tb_hbs_c6_real_world_stress.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c6: sim_hbs_c6
	@echo ""
	@echo "Running HBS-C6 Adversarial Real-World Workload Stress-Test..."
	$(VVP) sim_hbs_c6
	@echo ""
	$(PYTHON) analyze_hbs_c6_real_world.py
	@echo ""
	@echo "Outputs: HBS_C6_REAL_WORLD.csv  HBS_C6_SUMMARY.log"
	@echo "         docs/HBS_C6_RESULTS.md"
	@echo "         hbs_c6_workload_heatmap.png  hbs_c6_collapse_exposure.png"
	@echo "         hbs_c6_cancellation_drift.png  hbs_c6_deepchain_degradation.png"
	@echo ""

# ── HBS-C7: Failure-Domain Isolation Suite ───────────────────────────────────
# Tests horus_system DUT with 4 adversarial regimes × 275 cycles = 1100 cycles.
sim_hbs_c7: $(TB)/tb_hbs_c7_failure_domain.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c7: sim_hbs_c7
	@echo ""
	@echo "Running HBS-C7 Failure-Domain Isolation Suite..."
	$(VVP) sim_hbs_c7
	@echo ""
	$(PYTHON) analyze_hbs_c7_failure_domain.py
	@echo ""
	@echo "Outputs: HBS_C7_FAILURE_DOMAIN.csv  HBS_C7_SUMMARY.log"
	@echo "         docs/HBS_C7_RESULTS.md  docs/HORUS_FAILURE_DOMAIN_MAP.md"
	@echo "         hbs_c7_failure_heatmap.png  hbs_c7_r2_exponent_drift.png"
	@echo "         hbs_c7_r1_residual_growth.png  hbs_c7_recovery_comparison.png"
	@echo ""
