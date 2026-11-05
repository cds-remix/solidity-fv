# A vault's withdraw() with the ledger write after the external call, as a
# TLA+ model with two variants selected by the ChecksEffectsInteractions
# constant. The Defective variant must violate NoTheft and Solvent; the
# Fixed variant must hold every property; both must keep IndInv inductive.
# Verdicts are asserted here; the machinery is shared from tla.mk.

HELP_TITLE := vault reentrancy models

# One worker and a pinned fingerprint so TLC's trace is reproducible.
TLC_FLAGS := -cleanup -noGenerateSpecTE -metadir .apalache-out/tlc -workers 1 -fp 1

include tla.mk

.PHONY: all check clean

## make | assert every documented verdict (the default goal)
all: check

check: ## assert the defective variant fails and the fixed one holds
	$(call check_violation,Vault/Defective/NoTheft,--cinit=Defective --inv=NoTheft,Vault.tla,the attacker is paid twice on one ledger entry,6)
	$(call check_violation,Vault/Defective/Solvent,--cinit=Defective --inv=Solvent --length=14,Vault.tla,at rest the vault holds less than its ledger owes,11)
	$(call check_clean,Vault/Fixed/Safe,--cinit=Fixed --inv=Safe --length=14,Vault.tla)
	$(call check_inductive,Vault/Defective/IndInv,--cinit=Defective,Vault.tla,IndInv)
	$(call check_inductive,Vault/Fixed/IndInv,--cinit=Fixed,Vault.tla,IndInv)
	$(call tlc_violation,Vault/Defective/NoTheft/tlc,Defective_NoTheft.cfg,Vault.tla,TLC finds the same double payout)
	$(call tlc_violation,Vault/Defective/Solvent/tlc,Defective_Solvent.cfg,Vault.tla,TLC finds the same insolvent rest state)
	$(call tlc_clean,Vault/Defective/TypeOk/tlc,Defective_TypeOk.cfg,Vault.tla,28)
	$(call tlc_clean,Vault/Defective/NoReentry/tlc,Defective_NoReentry.cfg,Vault.tla,8)
	$(call tlc_clean,Vault/Fixed/tlc,Fixed.cfg,Vault.tla,9)
	$(call tlc_covered,Vault/Fixed/coverage,Fixed.cfg,Vault.tla)
	@echo "all verdicts match"

clean: ## remove checker output
	@rm -rf $(OUT)
