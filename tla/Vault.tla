---------------------------- MODULE Vault ----------------------------
EXTENDS Integers

CONSTANTS
    \* @type: Bool;
    ChecksEffectsInteractions,
    \* @type: Int;
    HonestDeposit,
    \* @type: Int;
    AttackerDeposit,
    \* @type: Int;
    MaxDepth

VARIABLES
    \* @type: Int;
    vaultEth,
    \* @type: Str -> Int;
    balances,
    \* @type: Int;
    attackerEth,
    \* @type: Int;
    depth,
    \* @type: Int -> Int;
    amount,
    \* @type: Str;
    pc

Addr   ≜ {"honest", "attacker"}
Total  ≜ HonestDeposit + AttackerDeposit
Frames ≜ 1..MaxDepth
PCs    ≜ {"Idle", "Check", "Call", "Fallback", "Effect", "Return"}

\* The variant picks the order of withdraw()'s statements after the check.
AfterCheck  ≜ IF ChecksEffectsInteractions THEN "Effect" ELSE "Call"
AfterEffect ≜ IF ChecksEffectsInteractions THEN "Call"   ELSE "Return"
AfterCall   ≜ IF ChecksEffectsInteractions THEN "Return" ELSE "Effect"

Init ≜ ∧ vaultEth    = Total
       ∧ balances    = [a ∈ Addr ↦ IF a = "honest" THEN HonestDeposit ELSE AttackerDeposit]
       ∧ attackerEth = 0
       ∧ depth       = 0
       ∧ amount      = [f ∈ Frames ↦ 0]
       ∧ pc          = "Idle"

\* The local `amount` of the frame on top of the call stack.
Top ≜ amount[depth]

\* withdraw()'s first statement copies the ledger into a local, so a frame
\* is born holding whatever the ledger says at that instant.
Push ≜ ∧ depth'  = depth + 1
       ∧ amount' = [amount EXCEPT ![depth + 1] = balances["attacker"]]

\* The slot is cleared on the way out so a stale local cannot split states.
Pop  ≜ ∧ depth'  = depth - 1
       ∧ amount' = [amount EXCEPT ![depth] = 0]

\* Where control lands when the top frame leaves: back in the transaction
\* sender when the stack empties, otherwise in the caller frame, whose
\* external call has just returned.
Resume ≜ IF depth = 1 THEN "Idle" ELSE AfterCall

\* The attacker sends a transaction calling withdraw().
Submit ≜ ∧ pc = "Idle"
         ∧ Push
         ∧ pc' = "Check"
         ∧ UNCHANGED ⟨vaultEth, balances, attackerEth⟩

\* require(amount > 0) passes.
CheckPass ≜ ∧ pc = "Check"
            ∧ Top > 0
            ∧ pc' = AfterCheck
            ∧ UNCHANGED ⟨vaultEth, balances, attackerEth, depth, amount⟩

\* require(amount > 0) fails and the frame reverts. The attacker's
\* receive() wraps its reentry in try/catch, so the caller frame sees its
\* call return normally.
CheckFail ≜ ∧ pc = "Check"
            ∧ Top = 0
            ∧ Pop
            ∧ pc' = Resume
            ∧ UNCHANGED ⟨vaultEth, balances, attackerEth⟩

\* msg.sender.call{value: amount}(""): ether moves and control follows it.
\* The enabling condition stands in for the EVM refusing an unfunded call;
\* no reachable state needs it (see the header).
Call ≜ ∧ pc = "Call"
       ∧ vaultEth ≥ Top
       ∧ vaultEth'    = vaultEth - Top
       ∧ attackerEth' = attackerEth + Top
       ∧ pc' = "Fallback"
       ∧ UNCHANGED ⟨balances, depth, amount⟩

\* The attacker's receive() returns without reentering.
FallbackReturn ≜ ∧ pc = "Fallback"
                 ∧ pc' = AfterCall
                 ∧ UNCHANGED ⟨vaultEth, balances, attackerEth, depth, amount⟩

\* THE REENTRY: receive() calls withdraw() again while the outer withdraw()
\* is still parked at its external call. MaxDepth stands in for the gas limit.
FallbackReenter ≜ ∧ pc = "Fallback"
                  ∧ depth < MaxDepth
                  ∧ vaultEth ≥ AttackerDeposit
                  ∧ Push
                  ∧ pc' = "Check"
                  ∧ UNCHANGED ⟨vaultEth, balances, attackerEth⟩

\* balances[msg.sender] = 0.
Effect ≜ ∧ pc = "Effect"
         ∧ balances' = [balances EXCEPT !["attacker"] = 0]
         ∧ pc' = AfterEffect
         ∧ UNCHANGED ⟨vaultEth, attackerEth, depth, amount⟩

\* The frame finishes and control goes back to whoever called it.
Return ≜ ∧ pc = "Return"
         ∧ Pop
         ∧ pc' = Resume
         ∧ UNCHANGED ⟨vaultEth, balances, attackerEth⟩

Next ≜ ∨ Submit
       ∨ CheckPass
       ∨ CheckFail
       ∨ Call
       ∨ FallbackReturn
       ∨ FallbackReenter
       ∨ Effect
       ∨ Return

vars ≜ ⟨vaultEth, balances, attackerEth, depth, amount, pc⟩

Spec ≜ Init ∧ □[Next]_vars

----------------------------------------------------------------------

TypeOk ≜ ∧ vaultEth    ∈ 0..Total
         ∧ balances    ∈ [Addr → 0..Total]
         ∧ attackerEth ∈ 0..Total
         ∧ depth       ∈ 0..MaxDepth
         ∧ amount      ∈ [Frames → 0..Total]
         ∧ pc          ∈ PCs

\* Ether is neither minted nor burned: what left the vault is in the attacker's hands.
Conservation ≜ vaultEth + attackerEth = Total

\* Between transactions the vault holds enough ether to honor every balance on its ledger.
Solvent ≜ pc = "Idle" ⇒ vaultEth ≥ balances["honest"] + balances["attacker"]

\* The attacker never holds more ether than they deposited.
NoTheft ≜ attackerEth ≤ AttackerDeposit

Safe ≜ TypeOk ∧ Conservation ∧ Solvent ∧ NoTheft

\* The inductive strengthening of TypeOk: Conservation bounds attackerEth
\* from above, and the stack is empty exactly when no transaction runs.
IndInv ≜ ∧ TypeOk
         ∧ Conservation
         ∧ (pc = "Idle" ⇔ depth = 0)

----------------------------------------------------------------------

Defective ≜ ∧ ChecksEffectsInteractions = FALSE
            ∧ HonestDeposit   = 2
            ∧ AttackerDeposit = 1
            ∧ MaxDepth        = 3

Fixed ≜ ∧ ChecksEffectsInteractions = TRUE
        ∧ HonestDeposit   = 2
        ∧ AttackerDeposit = 1
        ∧ MaxDepth        = 3

=========================================================================
