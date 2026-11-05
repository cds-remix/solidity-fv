// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Vault.sol";

/// One-click reentrancy demo for Remix.
///
/// This is the factory: it holds the subject (a freshly deployed vault) and
/// deploys the attack contract, so the whole scenario stands up in a single
/// deployment and runs on a single button.
///
/// How to run it in Remix (Deploy & Run panel):
///   1. Set the "Value" field to 3 ether (3000000000000000000 wei).
///   2. In the constructor field, pass `false` to attack the defective
///      `Vault`, or `true` to point the same attack at `VaultFixed`.
///   3. Deploy. The constructor seeds a vault with 2 ether of honest money
///      (this factory plays the honest depositor) and deploys an Attacker
///      staked with 1 ether.
///   4. Call `report` to see the starting balances, press `attack`, then
///      call `report` again to see the outcome.
///
/// What `report` shows:
///   before attack:                 vault 3, attacker 0, owed 3
///   after attack on Vault:         vault 0, attacker 3, owed 2  (honest 2 ether gone)
///   after attack on VaultFixed:    vault 2, attacker 1, owed 2  (nothing stolen)
contract ReentrancyDemo {
    IVault public immutable target;      // the subject under attack
    Attacker public immutable attacker;  // the attack contract this factory deploys
    address public immutable honest;     // the depositor whose money is at stake (this factory)

    uint256 public constant HONEST_DEPOSIT = 2 ether;
    uint256 public constant ATTACKER_STAKE = 1 ether;

    constructor(bool useFixedVault) payable {
        require(
            msg.value >= HONEST_DEPOSIT + ATTACKER_STAKE,
            "deploy with Value set to 3 ether"
        );
        honest = address(this);
        target = useFixedVault
            ? IVault(address(new VaultFixed()))
            : IVault(address(new Vault()));
        target.deposit{value: HONEST_DEPOSIT}();                 // honest liquidity, there to be stolen
        attacker = new Attacker{value: ATTACKER_STAKE}(target);  // deploy and stake the attack contract
    }

    /// The one button: run the reentrant withdrawal through the attacker.
    function attack() external {
        attacker.attack();
    }

    /// Read the live outcome. `ledgerOwed` is what the vault's own ledger
    /// still says it owes the two depositors; compare it to `vaultEther`.
    function report()
        external
        view
        returns (uint256 vaultEther, uint256 attackerEther, uint256 ledgerOwed)
    {
        vaultEther = address(target).balance;
        attackerEther = address(attacker).balance;
        ledgerOwed = target.balances(honest) + target.balances(address(attacker));
    }

    /// Accept the honest deposit's refund path and any stray value.
    receive() external payable {}
}
