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
.PHONY: all
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
	      sim_fidelity sim_boundary horus_sim
	rm -f *.vcd fidelity_benchmark.csv fidelity_plot.png fidelity_error_plot.png
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
	@echo "  make clean        Remove build artifacts"
	@echo ""
