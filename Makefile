# Horus NFE — root convenience wrapper (source of truth: sim/Makefile)
.PHONY: all test fidelity sim_c analysis clean help hbs_stability failure_domain cancel_analysis composition_analysis hbs11 hbs12 hbs13 hbs14
all test fidelity sim_c analysis clean help hbs_stability failure_domain cancel_analysis composition_analysis hbs11 hbs12 hbs13 hbs14:
	$(MAKE) -C sim $@
