# Horus NFE — root convenience wrapper (source of truth: sim/Makefile)
.PHONY: all test fidelity sim_c analysis clean help
all test fidelity sim_c analysis clean help:
	$(MAKE) -C sim $@
