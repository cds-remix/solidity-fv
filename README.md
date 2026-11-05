# Vault: a Solidity contract modeled in TLA+

`sol/Vault.sol` holds two versions of one vault contract: `Vault`, whose
`withdraw()` writes the ledger after its external call, and `VaultFixed`,
which writes the ledger first (checks, effects, interactions).
`tla/Vault.tla` models both; the constant `ChecksEffectsInteractions`
picks the variant.

Layout:

```
sol/   Vault.sol, Vault_test.sol      the contract and its Remix tests
tla/   Vault.tla, Makefile, *.cfg     the model and its checker setup
       model.md                       a reader's walkthrough of the model
```

## Where this sits

The defect modeled here is reentrancy, entry SC05 ("Reentrancy Attacks") in
the OWASP Smart Contract Top 10, 2025 edition (see `references.md`). The
project structure, one mechanism carried from a Solidity contract through a
TLA+ model to a Remix test, is meant to generalize: each further entry in
that list (access control SC01, logic errors SC03, and the rest) can become
its own `sol/` contract, `tla/` model, and test, built the same way.

## Run

- `cd tla && make` asserts every verdict in the table below (Apalache and
  TLC, one JVM at a time).
- `make help` lists the targets; `make clean` removes `.apalache-out/`.
- Requires `apalache-mc` on the path (0.62.2 was used); TLC runs from the
  jar inside the Apalache install.
- `solc sol/Vault.sol --bin` compiles the contract (solc 0.8.38 was used).

## State

| variable | meaning |
|---|---|
| `vaultEth` | ether the vault contract holds |
| `balances` | the ledger, `Str -> Int`, over `{"honest", "attacker"}` |
| `attackerEth` | ether the attacker's contract holds |
| `depth` | number of `withdraw()` frames on the call stack |
| `amount` | each frame's local `amount`, indexed by stack slot |
| `pc` | the next statement of the top frame: `Idle`, `Check`, `Call`, `Fallback`, `Effect`, `Return` |

Constants: `HonestDeposit` 2, `AttackerDeposit` 1, `MaxDepth` 3 (the call
depth standing in for the gas limit) in both `--cinit` operators and all
`.cfg` files, except `Defective_NoReentry.cfg`, which sets `MaxDepth` 1.

## Properties

| property | formula | read |
|---|---|---|
| `TypeOk` | every variable in its range | the vault never attempts a payout it cannot fund (an unfunded `Call` would push `vaultEth` below 0) |
| `Conservation` | `vaultEth + attackerEth = Total` | ether is neither minted nor burned |
| `Solvent` | `pc = "Idle" => vaultEth >= Σ balances` | between transactions the vault can honor its whole ledger |
| `NoTheft` | `attackerEth <= AttackerDeposit` | the attacker never holds more than they deposited |
| `IndInv` | `TypeOk ∧ Conservation ∧ (pc = "Idle" ⇔ depth = 0)` | the inductive strengthening that gives `TypeOk` an unbounded verdict |

## Verdicts

| variant | property | checker | verdict |
|---|---|---|---|
| Defective | `NoTheft` | Apalache | violated at state 6; TLC at its state 7 (TLC counts the initial state as 1) |
| Defective | `Solvent` | Apalache `--length=14` | violated at state 11, past the default bound of 10; TLC at its state 12 |
| Defective | `TypeOk ∧ Conservation` | TLC | clean, 28 distinct states |
| Defective, `MaxDepth` 1 | all four | TLC | clean, 8 distinct states: with no room to reenter, the ordering alone does no harm |
| Fixed | all four | Apalache `--length=14` | clean to the bound |
| Fixed | all four | TLC | clean, 9 distinct states, every action fires |
| both | `IndInv` | Apalache, two runs | inductive, so `TypeOk` and `Conservation` hold in every reachable state, unbounded |

## Concessions

- Deposits happen once, in `Init`; the honest depositor never acts. A
  withdrawal by the honest account would add states without changing any
  verdict, since `Solvent` already says what they would find.
- `receive()` makes at most one reentrant call per activation; a loop
  inside it drains the vault the same way, one frame deeper.
- A frame whose `require(amount > 0)` fails reverts and is popped
  (`CheckFail`); the attacker's `try/catch` swallows the revert, so the
  caller frame continues as if its call returned normally.
- `Call` is enabled only when the vault can fund it. No reachable state
  needs the condition (`TypeOk` and TLC's deadlock check both say so);
  it stands in for the EVM refusing an unfunded call.
- `Pop` clears the vacated slot so a stale local cannot split states.

## Remark on compiler version

The effect here is `balances[msg.sender] = 0`. With `-= amount` instead,
Solidity 0.8's checked arithmetic reverts the outer frame when the inner
frames have already zeroed the entry, and the whole transaction unwinds;
the assignment form is the one that stays exploitable on 0.8.

## Demo on Remix

`sol/Vault_test.sol` turns each refuted property into a Solidity unit test
that runs in the Remix "Solidity Unit Testing" plugin. A passing test on the
defective `Vault` means the exploit the TLA+ model predicted actually runs.

Steps:

1. Open `Vault.sol` and `Vault_test.sol` from `sol/` in the Remix workspace
   (same folder, so the `import "./Vault.sol"` resolves).
2. Open the "Solidity Unit Testing" plugin from the left sidebar.
3. Point it at `Vault_test.sol` and press "Run".

The four tests, each funded with 3 ether by its `#value` annotation:

| test | contract | shows |
|---|---|---|
| `theftOnDefectiveVault` | `Vault` | attacker ends holding 3 ether on a 1 ether deposit (NoTheft fails) |
| `insolvencyOnDefectiveVault` | `Vault` | at rest the vault holds 0 against a 2 ether ledger (Solvent fails) |
| `fixPreventsTheft` | `VaultFixed` | attacker recovers exactly their 1 ether (NoTheft holds) |
| `fixStaysSolvent` | `VaultFixed` | at rest the vault holds its full 2 ether ledger (Solvent holds) |

Numbers confirmed against the EVM (the attacker drains to 3 ether, the vault
to 0; the fixed vault leaves the attacker with 1 ether and the vault with 2).
