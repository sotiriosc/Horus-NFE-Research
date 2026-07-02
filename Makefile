# Horus NFE — root convenience wrapper (source of truth: sim/Makefile)
.PHONY: all test fidelity sim_c analysis clean help hbs_stability failure_domain cancel_analysis composition_analysis hbs11 hbs12 hbs13 hbs14 hbs_c2 hbs_c5 hbs_c6
all test fidelity sim_c analysis clean help hbs_stability failure_domain cancel_analysis composition_analysis hbs11 hbs12 hbs13 hbs_c2:
	$(MAKE) -C sim $@

hbs14:
	$(MAKE) -C sim $@

hbs_c5:
	$(MAKE) -C sim $@

hbs_c6:
	$(MAKE) -C sim $@
