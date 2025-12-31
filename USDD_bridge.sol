// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @title USDT Bridge Deposit Manager

/// @notice This contract manages deposits of TRC20 USDT on the TRON network as part of a centralized cross-chain bridge mechanism.

/// Users deposit USDT, associating each deposit with a unique EVM-compatible address on the Base chain via an on-chain mapping.

/// Deposits are transferred directly to the owner address for liquidity management, while the contract emits events for off-chain relayer processing.

/// The design prioritizes operational efficiency, security best practices, and prevention of dust attacks through configurable minimum deposit thresholds.

/// @dev Intended for use in a trust-minimized relayer model where the owner (or multisig) controls fund collection and cross-chain fulfillment.

/// All amounts are expressed in USDT's native 6-decimal precision.

interface ITRC20 {

    function transfer(address recipient, uint256 amount) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

}

contract USDT_bridge_USDD {

    

    /// @notice Owner of the bridge contract, responsible for settlement and configuration.

    /// Receives all deposited USDT directly for centralized liquidity management.

    address public owner;

    /// @notice Immutable reference to the official TRC20 USDT contract on TRON mainnet.

    /// Hardcoded with EIP-55 checksummed address for Solidity compiler compliance.

    ITRC20 public constant usdt = ITRC20(0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C);

    /// @notice Mapping of EVM-compatible recipient addresses (stored as strings) to deposited USDT amounts.

    /// Ensures one-time deposit per destination address to prevent duplicates.

    mapping(string => uint256) public deposits;

    /// @notice Configurable minimum deposit amount in USDT (6 decimals) to mitigate dust attacks and operational overhead.

    /// Initial value set to 1 USDT; adjustable by owner.

    uint256 public minDeposit = 1000000;

    // Reentrancy guard status

    uint256 private constant _NOT_ENTERED = 1;

    uint256 private constant _ENTERED = 2;

    uint256 private _status = _NOT_ENTERED;

    /// @dev Modifier to prevent reentrancy attacks during deposit processing.

    modifier nonReentrant() {

        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        _status = _ENTERED;

        _;

        _status = _NOT_ENTERED;

    }

    /// @notice Emitted when a user successfully deposits USDT.

    /// @param evmAddress The destination EVM address on Base chain (as string).

    /// @param amount Deposited amount in USDT (6 decimals).

    /// @param tronSender TRON address of the depositor.

    event Deposited(string indexed evmAddress, uint256 amount, address indexed tronSender);

    /// @notice Emitted when the owner settles a deposit, clearing the on-chain record.

    /// Serves as public proof of processing for transparency and auditability.

    /// @param evmAddress The settled EVM address.

    /// @param amount Settled amount in USDT (6 decimals).

    event Settled(string indexed evmAddress, uint256 amount);

    /// @notice Emitted when the minimum deposit threshold is updated.

    /// @param newMinDeposit The new minimum deposit amount (6 decimals).

    event MinDepositUpdated(uint256 newMinDeposit);

    /// @notice Contract constructor. Sets deployer as initial owner.

    constructor() {

        owner = msg.sender;

    }

    /// @dev Restricts access to the owner only.

    modifier onlyOwner() {

        require(msg.sender == owner, "Not owner");

        _;

    }

    /// @notice Allows users to deposit TRC20 USDT, associating it with a Base chain EVM address.

    /// Requires prior approval of USDT to the contract. Deposit is transferred directly to owner.

    /// Enforces minimum deposit, unique EVM address, and valid address formatting.

    /// @dev Follows Checks-Effects-Interactions pattern and includes reentrancy protection.

    /// @param amount The amount of USDT to deposit (6 decimals).

    /// @param evmAddress The recipient EVM address on Base as a string (must be checksummed or lowercase 0x-prefixed).

    function deposit(uint256 amount, string memory evmAddress) external nonReentrant {

        require(amount > 0, "Amount must be > 0");

        require(amount >= minDeposit, "Amount below minimum deposit threshold");

        // Strict validation of EVM address format

        bytes memory addrBytes = bytes(evmAddress);

        require(addrBytes.length == 42, "Invalid EVM address length");

        require(addrBytes[0] == '0' && (addrBytes[1] == 'x' || addrBytes[1] == 'X'), "EVM address must start with 0x");

        for (uint i = 2; i < 42; i++) {

            bytes1 b = addrBytes[i];

            require(

                (b >= 0x30 && b <= 0x39) || // 0-9

                (b >= 0x61 && b <= 0x66) || // a-f

                (b >= 0x41 && b <= 0x46),   // A-F

                "Invalid hexadecimal character in EVM address"

            );

        }

        require(deposits[evmAddress] == 0, "EVM address already has an active deposit");

        // Effects: record deposit before external call

        deposits[evmAddress] = amount;

        // Interactions: transfer USDT to owner

        require(usdt.transferFrom(msg.sender, owner, amount), "USDT transferFrom failed");

        emit Deposited(evmAddress, amount, msg.sender);

    }

    /// @notice Allows owner to settle a recorded deposit, clearing the mapping entry.

    /// Emits event for off-chain transparency; actual USDT is already held by owner.

    /// @param evmAddress The EVM address whose deposit to settle.

    function settle(string memory evmAddress) external onlyOwner {

        uint256 amount = deposits[evmAddress];

        require(amount > 0, "No active deposit for specified EVM address");

        delete deposits[evmAddress];

        emit Settled(evmAddress, amount);

    }

    /// @notice Transfers ownership of the contract to a new address.

    /// @dev Recommended to transfer to a multisig for enhanced security.

    /// @param newOwner The new owner address.

    function transferOwnership(address newOwner) external onlyOwner {

        require(newOwner != address(0), "New owner cannot be zero address");

        owner = newOwner;

    }

    /// @notice Updates the minimum deposit threshold.

    /// @dev Useful for adjusting to network conditions or operational costs.

    /// @param newMin The new minimum deposit amount in USDT (6 decimals).

    function setMinDeposit(uint256 newMin) external onlyOwner {

        require(newMin > 0, "Minimum deposit must be greater than zero");

        minDeposit = newMin;

        emit MinDepositUpdated(newMin);

    }

}
