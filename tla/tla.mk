# Shared TLA+ rules for model directories, patterned after spin.mk. A
# directory Makefile sets its knobs, pulls this in, then builds its
# targets from the canned pieces:
#
#     APALACHE := apalache-mc       # optional; every knob has a default
#     HELP_TITLE := die-hard models
#     include tla.mk
#
#     all: check
#     check: ...
#     	$(call check_violation,<label>,<check args>,<model>,<meaning>[,<state>])
#     	$(call check_deadlock,<label>,<check args>,<model>,<meaning>)
#     	$(call check_clean,<label>,<check args>,<model>)
#     	$(call check_clean_short,<label>,<check args>,<model>,<why executions end>)
#     	$(call check_inductive,<label>,<check args>,<model>,<invariant>)
#     	$(call tlc_violation,<label>,<config>,<model>,<meaning>)
#     	$(call tlc_deadlock,<label>,<config>,<model>,<meaning>)
#     	$(call tlc_clean,<label>,<config>,<model>)
#     	$(call tlc_covered,<label>,<config>,<model>)
#
# Macro arguments must not contain commas (make's $(call) splits on them)
# or single quotes (recipes echo them inside single quotes). So
# `--inv=A,B` cannot appear in a macro argument: conjoin the invariants
# in the module (Inv == A /\ B) or make two calls.
#
# Apalache 0.62 gotchas the macros encode:
#   - global options (--out-dir) go BEFORE the `check` subcommand, and
#     command options (--inv, --length) go BEFORE the file, or Apalache
#     fails with "Too many arguments".
#   - `check` is bounded: the default --length is 10 Next steps, and a
#     NoError verdict means "no error within the bound", nothing more.
#     check_clean prints the bound it verified so the PASS line cannot
#     overclaim; an unbounded verdict needs check_inductive or TLC.
#   - a parse or type error exits nonzero too (255 or 120), so a
#     recipe of the form `! apalache-mc ...` passes on a typo. Every
#     macro asserts the specific outcome line, never just the exit code.
#   - `The outcome is: ExecutionsTooShort` exits 0. It means every
#     execution ended (deadlocked, or the spec has no stuttering step)
#     before the bound, and with --temporal it means the property was
#     never really checked: temporal counterexamples are lassos, and a
#     finite execution has no loop. check_clean rejects it; a spec
#     that terminates by design uses check_clean_short with the reason.

APALACHE ?= apalache-mc
OUT ?= .apalache-out
HELP_TITLE ?= $(notdir $(CURDIR)) TLA+ models

# TLC ships inside the Apalache jar (tlc2.TLC), so one install serves
# both checkers. Resolve the jar through the apalache-mc symlink; set
# TLC outright to use a separate tla2tools.jar.
APALACHE_JAR ?= $(dir $(shell readlink -f $(shell which $(APALACHE))))../lib/apalache.jar
TLC ?= java -cp $(APALACHE_JAR) tlc2.TLC
# -metadir keeps TLC's states/ scratch out of the tree; -noGenerateSpecTE
# stops it dropping <Model>_TTrace_*.tla next to the model on a violation.
TLC_FLAGS ?= -cleanup -noGenerateSpecTE -metadir $(OUT)/tlc -workers auto

# This file defines the first targets make sees, so pin the default goal;
# every directory provides an `all`.
.DEFAULT_GOAL := all

.PHONY: help

# ---- Apalache check macros: assert one documented verdict each ----

apalache_check = mkdir -p $(OUT) && $(APALACHE) --out-dir=$(OUT) check $(2) $(3) 2>&1

define check_violation
	@$(apalache_check) > $(OUT)/$(subst /,_,$(1)).log; \
		grep -a -q 'The outcome is: Error' $(OUT)/$(subst /,_,$(1)).log \
		$(if $(5),&& grep -a -q 'State $(5): state invariant' $(OUT)/$(subst /,_,$(1)).log,) \
		&& echo "PASS $(1): $(4)$(if $(5), (violated at state $(5)),)" \
		|| { echo "FAIL $(1): expected 'The outcome is: Error'$(if $(5), at State $(5),) from apalache-mc check $(2) $(3)"; \
		     grep -a -E 'outcome|State [0-9]+:|E@' $(OUT)/$(subst /,_,$(1)).log; exit 1; }
endef

define check_deadlock
	@$(apalache_check) \
		| grep -q 'The outcome is: Deadlock' \
		&& echo "PASS $(1): $(4)" \
		|| { echo "FAIL $(1): expected 'The outcome is: Deadlock' from apalache-mc check $(2) $(3)"; exit 1; }
endef

# The PASS line carries the bound Apalache actually verified.
define check_clean
	@$(apalache_check) > $(OUT)/$(subst /,_,$(1)).log; \
		grep -q 'The outcome is: NoError' $(OUT)/$(subst /,_,$(1)).log \
		&& echo "PASS $(1): clean $$(grep -a -o 'up to computation length [0-9]*' $(OUT)/$(subst /,_,$(1)).log)" \
		|| { echo "FAIL $(1): expected 'The outcome is: NoError' from apalache-mc check $(2) $(3)"; \
		     grep -a -E 'outcome|E@' $(OUT)/$(subst /,_,$(1)).log; exit 1; }
endef

define check_clean_short
	@$(apalache_check) \
		| grep -q 'The outcome is: ExecutionsTooShort' \
		&& echo "PASS $(1): clean, all executions end before the bound ($(4))" \
		|| { echo "FAIL $(1): expected 'The outcome is: ExecutionsTooShort' from apalache-mc check $(2) $(3)"; exit 1; }
endef

# An inductive invariant gives an unbounded verdict from two bounded
# checks: Init satisfies it (length 0), and one Next step from any
# state satisfying it lands in a state satisfying it (start from the
# invariant, length 1). Extra check args (--cinit, --next) pass through.
define check_inductive
	@$(APALACHE) --out-dir=$(OUT) check $(2) --inv=$(4) --length=0 $(3) 2>&1 \
		| grep -q 'The outcome is: NoError' \
		|| { echo "FAIL $(1): Init does not satisfy $(4)"; exit 1; }
	@$(APALACHE) --out-dir=$(OUT) check $(2) --init=$(4) --inv=$(4) --length=1 $(3) 2>&1 \
		| grep -q 'The outcome is: NoError' \
		&& echo "PASS $(1): $(4) is inductive (holds in every reachable state)" \
		|| { echo "FAIL $(1): $(4) is not preserved by one Next step"; exit 1; }
endef

# ---- TLC macros: exhaustive, unbounded, needs a .cfg ----
#
# TLC exit codes: 0 clean, 11 deadlock, 12 invariant, 13 temporal
# property. The macros assert on the message line, as above.

tlc_run = mkdir -p $(OUT) && $(TLC) $(TLC_FLAGS) -config $(2) $(3) 2>&1

define tlc_violation
	@$(tlc_run) \
		| grep -qE '^Error: (Invariant .* is|Temporal property .* was) violated' \
		&& echo "PASS $(1): $(4)" \
		|| { echo "FAIL $(1): expected TLC to report a violated invariant or property with $(2)"; exit 1; }
endef

define tlc_deadlock
	@$(tlc_run) \
		| grep -q '^Error: Deadlock reached' \
		&& echo "PASS $(1): $(4)" \
		|| { echo "FAIL $(1): expected TLC to report a deadlock with $(2)"; exit 1; }
endef

# The optional fourth argument is the distinct-state count the header
# claims; given, the PASS also asserts it. Only a clean run counts the
# full graph: a violating run reports the states seen before TLC
# stopped, so a header's state count comes from a clean run (TypeOK on
# the same constants), never from the violation.
#
# The PASS text takes the last match because TLC prints the count twice
# and only the second is the whole graph: a Progress line carries the
# count so far with its digits grouped by commas, and the summary after
# it carries the final count ungrouped. Matching both put the last comma
# group of the progress count where the answer belongs ("clean,
# exhaustive (371 distinct states found" for a graph of 3657504).
define tlc_clean
	@$(tlc_run) > $(OUT)/$(subst /,_,$(1)).log; \
		grep -q 'No error has been found' $(OUT)/$(subst /,_,$(1)).log \
		&& grep -q ' $(if $(4),$(4),[0-9]*) distinct states found' $(OUT)/$(subst /,_,$(1)).log \
		&& echo "PASS $(1): clean, exhaustive ($$(grep -a -o '[0-9]* distinct states found' $(OUT)/$(subst /,_,$(1)).log | tail -1))" \
		|| { echo "FAIL $(1): expected TLC to find no error$(if $(4), with $(4) distinct states,) with $(2)"; \
		     grep -a -E '^Error|distinct states' $(OUT)/$(subst /,_,$(1)).log; exit 1; }
endef

# Statement coverage, the one verdict Spin's `check_clean` carried that the
# macros above do not: every action fires at least once on the clean run.
# TLC's `-coverage 1` prints one line per action, `<Name line ...>: taken:distinct`,
# and an action no reachable state enables prints `0:0`. Apply it to the
# configuration a model calls fixed, never to a defect variant, whose repair
# branch is unreachable by design.
define tlc_covered
	@$(TLC) $(TLC_FLAGS) -coverage 1 -config $(2) $(3) 2>&1 > $(OUT)/$(subst /,_,$(1)).log; \
		grep -a -q 'No error has been found' $(OUT)/$(subst /,_,$(1)).log \
		&& ! grep -a -q -E '^<[A-Za-z_][A-Za-z0-9_]* line .*>: 0:0$$' $(OUT)/$(subst /,_,$(1)).log \
		&& echo "PASS $(1): every action fires ($$(grep -a -c -E '^<[A-Za-z_][A-Za-z0-9_]* line .*>: [0-9]+:[0-9]+$$' $(OUT)/$(subst /,_,$(1)).log) actions)" \
		|| { echo "FAIL $(1): expected a clean run in which every action fires with $(2)"; \
		     grep -a -E '^Error|^<[A-Za-z_][A-Za-z0-9_]* line .*>: 0:0$$' $(OUT)/$(subst /,_,$(1)).log; exit 1; }
endef

# ---- self-documenting help, built from `##` annotations ----
#
# MAKEFILE_LIST holds this file and the directory Makefile; the
# directory Makefile is listed first so its rows lead. Two row shapes:
#   target: deps ## what happens            -> "make target | what happens"
#   ...     ## you type | what happens      -> both columns given outright
# The second form also works on a bare `## you type | what happens`
# comment line, for invocations that are not a single target.
HELP_FILES := $(firstword $(MAKEFILE_LIST)) $(filter-out $(firstword $(MAKEFILE_LIST)),$(MAKEFILE_LIST))

help: ## show this table
	@printf '\n\033[36m%s\033[0m   apalache: %s\n\n' '$(HELP_TITLE)' '$(APALACHE)'
	@printf '  \033[1m%-28s %s\033[0m\n' 'you type' 'what happens'
	@awk 'BEGIN { FS = ":.*##" } \
		function row(s,  i) { i = index(s, " | "); \
			printf "  \033[36m%-28s\033[0m %s\n", substr(s, 1, i - 1), substr(s, i + 3) } \
		FNR == 1 && NR > 1 { print "" } \
		/^## / { row(substr($$0, 4)); next } \
		/^[A-Za-z_$$(%)-][^:=]*:[^=].*##/ { d = $$2; sub(/^ +/, "", d); \
			if (d ~ / \| /) row(d); else row("make " $$1 " | " d) }' \
		$(HELP_FILES)
	@printf '\n'
