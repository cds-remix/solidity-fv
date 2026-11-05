# Vault.tla: a reader's walkthrough

This is the narration for `Vault.tla`: the story first, then the machinery,
then the verdicts and how they map to the Remix tests. The `.tla` file holds
the model; `../README.md` holds the run instructions and the quick tables. This
file is the one to read first.

## The contract

A vault keeps a ledger, `balances`, mapping each depositor to the amount the
vault owes them, and holds the pooled ether itself. Two accounts use it in
our scenario:

- an honest depositor who put in 2 ether, and
- an attacker who put in 1 ether.

So the vault holds 3 ether, and the ledger reads honest 2, attacker 1.

```
  honest  --deposit 2-->  +-----------------+
                          |  Vault          |
  attacker --deposit 1--> |  ether: 3       |
                          |  ledger:        |
                          |    honest   2   |
                          |    attacker 1   |
                          +-----------------+
```

`withdraw()` pays a depositor everything the ledger says they are owed. The
whole model turns on the order of its last three statements
(`../sol/Vault.sol:14-18`):

```solidity
uint256 amount = balances[msg.sender];                 // 1. check:       read the ledger into a local
require(amount > 0, "nothing to withdraw");
(bool sent, ) = msg.sender.call{value: amount}("");    // 2. interaction: send the ether out
require(sent, "transfer failed");
balances[msg.sender] = 0;                              // 3. effect:      write the ledger
```

## Time of check, time of use

A time-of-check-to-time-of-use (TOCTOU) defect is any situation where a
program reads a fact, then acts on that fact later, and something changes the
fact in the gap. Here the fact is "how much does the vault owe this account",
the read is statement 1, and the act is the payout justified by statement 2.
Between them sits the interaction.

Why is there a gap at all? On the Ethereum Virtual Machine (EVM), sending
ether to an account that is itself a contract runs that contract's `receive()`
code before `call` returns. So statement 2 hands the program counter to the
account being paid, and does not get it back until that account's code
finishes. During that window the ledger still reads 1 for the attacker,
because statement 3 (the write) has not run yet. The time of check and the
time of use are separated by code the attacker controls, and that is the
whole defect.

The attacker's `receive()` (`../sol/Vault.sol:56-60`) spends the window asking for
the same payout again:

```solidity
receive() external payable {
    if (address(vault).balance >= stake) {
        try vault.withdraw() {} catch {}
    }
}
```

The fixed contract, `VaultFixed`, moves statement 3 above statement 2: it
writes the ledger before it sends the ether (the "checks, effects,
interactions" order). When the reentrant call reads the ledger, the entry is
already 0, its `require(amount > 0)` fails, and the reentrant frame reverts.

## Two orderings, side by side

The model tracks six things: the vault's ether, the ledger, the attacker's
ether, how deep the call stack is (`depth`), each stack frame's local `amount`,
and a program counter `pc` for the statement the top frame runs next.

First the ordering the author had in mind, where `receive()` simply returns.
`ledger[att]` is `balances["attacker"]`; `vault` and `att` are ether held.

| step | action           | depth | ledger[att] | vault | att | pc next   |
|------|------------------|-------|-------------|-------|-----|-----------|
| 0    | (at rest)        | 0     | 1           | 3     | 0   | Idle      |
| 1    | Submit           | 1     | 1           | 3     | 0   | Check     |
| 2    | CheckPass        | 1     | 1           | 3     | 0   | Call      |
| 3    | Call             | 1     | 1           | 2     | 1   | Fallback  |
| 4    | FallbackReturn   | 1     | 1           | 2     | 1   | Effect    |
| 5    | Effect           | 1     | 0           | 2     | 1   | Return    |
| 6    | Return           | 0     | 0           | 2     | 1   | Idle      |

At rest again: the attacker holds 1 ether (their deposit), the vault holds 2
(the honest depositor's), the ledger is settled. Nothing is wrong.

Now the failing ordering. The divergence is at step 4: instead of returning,
`receive()` reenters, pushing a second frame while the first is still parked at
its `call`.

| step | action           | depth | ledger[att] | vault | att | pc next   |
|------|------------------|-------|-------------|-------|-----|-----------|
| 0    | (at rest)        | 0     | 1           | 3     | 0   | Idle      |
| 1    | Submit           | 1     | 1           | 3     | 0   | Check     |
| 2    | CheckPass        | 1     | 1           | 3     | 0   | Call      |
| 3    | Call             | 1     | 1           | 2     | 1   | Fallback  |
| 4    | FallbackReenter  | 2     | 1           | 2     | 1   | Check     |  <- divergence
| 5    | CheckPass        | 2     | 1           | 2     | 1   | Call      |
| 6    | Call             | 2     | 1           | 1     | 2   | Fallback  |  <- NoTheft fails: att 2 > deposit 1
| 7    | FallbackReturn   | 2     | 1           | 1     | 2   | Effect    |
| 8    | Effect           | 2     | 0           | 1     | 2   | Return    |
| 9    | Return           | 1     | 0           | 1     | 2   | Effect    |
| 10   | Effect           | 1     | 0           | 1     | 2   | Return    |
| 11   | Return           | 0     | 0           | 1     | 2   | Idle      |  <- Solvent fails: vault 1 < owed 2

Two frames, frames 1 and 2, each read the ledger entry while it still said 1
(steps 1 and 4), so each pays itself 1 ether off the same credit. The attacker
leaves with 2 ether on a 1 ether deposit, and the vault, now at rest, holds 1
ether against a ledger that still owes the honest depositor 2. The honest
depositor's money is gone.

The model finds this two-round drain because two rounds already refute both
properties. On a live EVM the attacker's `receive()` keeps reentering while
the vault can still pay, so it drains all three rounds: attacker to 3 ether,
vault to 0. The Foundry run in `../README.md` confirms that full drain, and the
Remix tests assert it.

## How the model maps to the code

The model makes the call stack explicit, because the defect lives in what one
frame reads while another frame is suspended. The state:

| variable      | type         | meaning                                              |
|---------------|--------------|------------------------------------------------------|
| `vaultEth`    | `Int`        | ether the vault contract holds                        |
| `balances`    | `Str -> Int` | the ledger, over `{"honest", "attacker"}`             |
| `attackerEth` | `Int`        | ether the attacker's contract holds                   |
| `depth`       | `Int`        | number of `withdraw()` frames on the stack            |
| `amount`      | `Int -> Int` | each frame's local `amount`, indexed by stack slot    |
| `pc`          | `Str`        | the top frame's next statement                        |

The actions, in groups:

- **Entering**: `Submit` is the attacker's transaction calling `withdraw()`;
  it pushes the first frame. `Push` copies the ledger into the new frame's
  local `amount`, which is `withdraw()`'s first statement: a frame is born
  holding whatever the ledger said at that instant.
- **The check**: `CheckPass` is `require(amount > 0)` passing; `CheckFail` is
  it failing, which pops the frame. The attacker's `try/catch` swallows the
  revert, so the caller frame continues as if its call returned.
- **The interaction**: `Call` moves the ether and sets `pc` into the callee's
  `receive()`. `FallbackReturn` is `receive()` returning quietly;
  `FallbackReenter` is the reentry, which pushes another frame.
- **The effect and the exit**: `Effect` is `balances[msg.sender] = 0`;
  `Return` pops the frame and hands control back to its caller.

The variant constant `ChecksEffectsInteractions` picks the order. It sets
three operators, `AfterCheck`, `AfterEffect`, `AfterCall`, which decide where
`pc` goes after each statement. Defective: Check leads to Call leads to Effect.
Fixed: Check leads to Effect leads to Call. This one boolean is the only
difference between the vulnerable and the repaired contract.

## Properties

Each is a state predicate, with its reading:

- `TypeOk`: every variable stays in its declared range. Its real content is
  that the vault never attempts a payout it cannot fund (an unfunded `Call`
  would drive `vaultEth` below 0).
- `Conservation` is `vaultEth + attackerEth = Total`: ether is neither minted
  nor burned, so whatever left the vault is in the attacker's hands.
- `Solvent` is `pc = "Idle" => vaultEth >= balances["honest"] + balances["attacker"]`:
  between transactions the vault holds enough to honor its whole ledger.
- `NoTheft` is `attackerEth <= AttackerDeposit`: the attacker never holds more
  than they deposited.
- `Safe` is all four conjoined.
- `IndInv` is `TypeOk /\ Conservation /\ (pc = "Idle" <=> depth = 0)`: the
  inductive strengthening that lifts `TypeOk` and `Conservation` to an
  unbounded verdict. The extra clause says the stack is empty exactly when no
  transaction is running, which is what makes the two type bounds survive a
  single step from any state that satisfies them.

`NoTheft` and `Solvent` are the two the defective contract is meant to fail.
`Conservation` holds on both variants, by construction: `Call` is the only
action that moves ether, and it adds to `attackerEth` exactly what it takes
from `vaultEth`. It is in the model as a guard against a future edit that
breaks that balance, not as a finding about the defect.

## Variants and verdicts

Two `--cinit` operators set the constants: `Defective`
(`ChecksEffectsInteractions = FALSE`) and `Fixed` (`= TRUE`), both with honest
2, attacker 1, and `MaxDepth` 3. `MaxDepth` bounds the reentry, standing in
for the gas limit.

| variant                 | property            | checker                 | verdict                                              |
|-------------------------|---------------------|-------------------------|------------------------------------------------------|
| Defective               | `NoTheft`           | Apalache                | violated at state 6; TLC at its state 7              |
| Defective               | `Solvent`           | Apalache `--length=14`  | violated at state 11, past the default bound of 10; TLC at state 12 |
| Defective               | `TypeOk /\ Conservation` | TLC                | clean, 28 distinct states                            |
| Defective, `MaxDepth` 1 | all four            | TLC                     | clean, 8 states: with no room to reenter, the ordering alone does no harm |
| Fixed                   | `Safe`              | Apalache `--length=14`  | clean to the bound                                   |
| Fixed                   | all four            | TLC                     | clean, 9 states, every action fires                  |
| both                    | `IndInv`            | Apalache, two runs      | inductive, so `TypeOk` and `Conservation` hold unbounded |

The `Solvent` row is worth dwelling on. Its counterexample needs 11 steps, and
Apalache's default bound is 10, so a default run reports the defective vault
clean. A clean verdict is only ever "no violation within the bound"; this is a
model whose violation first appears one step past the default. The
`../README.md` verdict
table and the `Makefile` both state the bound outright for that reason.

The `MaxDepth` 1 row is the control inside the model: it holds the defective
ordering fixed and removes only the reentry. Everything passes. The ordering is
not the vulnerability by itself; the ordering plus a reentrant callee is.

## Concessions

Every place the model simplifies the code, named:

- Deposits happen once, in `Init`; the honest depositor never acts. A
  withdrawal by the honest account would add states without changing a verdict,
  since `Solvent` already describes what they would find at rest.
- `receive()` makes at most one reentrant call per activation. A loop inside it
  drains the vault the same way, one frame deeper.
- `Call` is enabled only when the vault can fund it. No reachable state needs
  that guard (`TypeOk` and TLC's deadlock check both confirm it); it stands in
  for the EVM refusing an unfunded call.
- `Pop` clears the vacated stack slot so a stale local cannot split otherwise
  equal states.

## The effect statement and the compiler version

The effect modeled is `balances[msg.sender] = 0`. The other common spelling,
`balances[msg.sender] -= amount`, behaves differently on Solidity 0.8 and
later: checked arithmetic reverts on underflow, so once the inner frames have
driven the entry to 0, the outer frame's `-= amount` reverts and the whole
transaction unwinds. The assignment form is the one that stays exploitable on
0.8, which is why the contract and the model use it.

## Relation to the Remix tests

`../sol/Vault_test.sol` turns the two refuted properties into live transactions for
the Remix Solidity Unit Testing plugin, with two positive controls on the
fixed contract:

| test                        | contract     | property this exercises |
|-----------------------------|--------------|-------------------------|
| `theftOnDefectiveVault`     | `Vault`      | `NoTheft` (fails)       |
| `insolvencyOnDefectiveVault`| `Vault`      | `Solvent` (fails)       |
| `fixPreventsTheft`          | `VaultFixed` | `NoTheft` (holds)       |
| `fixStaysSolvent`           | `VaultFixed` | `Solvent` (holds)       |

A passing test on `Vault` means the exploit the model predicted actually ran:
green is the alarm, not the all-clear. The checkers prove the property fails
for every interleaving within the bound; the Remix test shows one of those
interleavings executing on the EVM.
