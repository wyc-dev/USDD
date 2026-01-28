// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title Divine ICO
 * @notice A sophisticated Initial Coin Offering (ICO) mechanism for the DIVINE ERC20 token.
 * This contract implements a proportional token sale with an ascending price curve determined by remaining supply,
 * providing 10% immediate liquidity and linear vesting of the remaining 90% over approximately 10 years.
 * A two-tier referral incentive structure distributes rewards in ETH to qualified referrers,
 * with proceeds (net of referral rewards) directed to an immutable vault address.
 * Designed for capital efficiency, transparency, and long-term token holder alignment.
 * @custom:security-contact hopeallgood.unadvised619@passinbox.com
 */
contract DivineICO is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    /* The DIVINE ERC20 token contract being offered in the sale */
    IERC20 public immutable DIVINE;

    /* Immutable recipient address for net ETH proceeds after referral distributions */
    address public immutable VAULT;

    /* Maximum ETH contribution permitted per transaction (10 ETH) */
    uint256 public constant MAX_ETH_PER_TX = 10 ether;

    /* Percentage of purchased tokens released immediately (10%) */
    uint256 public constant IMMEDIATE_PERCENT = 10;

    /* Linear vesting duration, approximately 10 years (accounting for leap years) */
    uint256 public constant VEST_PERIOD = 10 * 365.25 days;

    /* Direct referral reward expressed in basis points (initially 1000 bps = 10%, adjustable up to 10000 bps) */
    uint256 public REFERRAL_BPS = 1000;

    /* Minimum DIVINE token balance required for referral eligibility (initially 0, owner-adjustable) */
    uint256 public MIN_HOLD_FOR_REFERRAL = 0 * 10**18;

    /* Vested token balance (90% portion) for each participant */
    mapping(address account => uint256 amount) public vestedBalance;

    /* Timestamp marking the commencement of vesting for each participant */
    mapping(address account => uint256 timestamp) public vestStartTime;

    /* Cumulative tokens already released to each participant */
    mapping(address account => uint256 amount) public released;

    /* Permanent mapping of each participant to their bound direct referrer (set on first qualified referral) */
    mapping(address account => address referrer) public map_referrer;

    // Custom errors for gas-efficient reversion with clear semantics
    error ZeroAmount();
    error MaxPerTxExceeded();
    error SoldOut();
    error InsufficientRemaining();
    error NoVested();
    error InvalidReferralBps();
    error ETHTransferFailed(address recipient);

    /**
     * @dev Emitted upon successful token purchase
     * @param buyer Purchaser address
     * @param ethPaid ETH amount contributed
     * @param tokensReceived Total DIVINE tokens allocated (immediate + vested)
     * @param directReferrer Qualified direct referrer address (address(0) if none)
     * @param grandReferrer Qualified grand-referrer address (address(0) if none)
     * @param directReward ETH reward distributed to direct referrer
     * @param grandReward ETH reward distributed to grand-referrer
     */
    event Bought(
        address indexed buyer,
        uint256 ethPaid,
        uint256 tokensReceived,
        address indexed directReferrer,
        address indexed grandReferrer,
        uint256 directReward,
        uint256 grandReward
    );

    /**
     * @dev Emitted when vested tokens are claimed
     * @param user Claiming address
     * @param amount Tokens released in this claim
     */
    event Claimed(address indexed user, uint256 amount);

    /**
     * @dev Emitted when the direct referral reward rate is updated
     * @param newBps Updated basis points value
     */
    event ReferralBpsUpdated(uint256 indexed newBps);

    /**
     * @dev Emitted when the minimum holding requirement for referral eligibility is updated
     * @param newMinHold Updated minimum balance requirement
     */
    event MinHoldForReferralUpdated(uint256 indexed newMinHold);

    /**
     * @notice Deploys the ICO contract with immutable token and vault references
     * @param _divine Address of the DIVINE ERC20 token contract
     * @param _vault Address of the treasury vault receiving net proceeds
     */
    constructor(address _divine, address _vault) Ownable(_msgSender()) {
        DIVINE = IERC20(_divine);
        VAULT = _vault;
    }

    /**
     * @notice Pauses all token purchases in the DivineICO contract.
     * @dev Can only be called by the contract owner (initially deployer, later expected to be transitioned
     *      to Divine DAO governance). When paused:
     *      - New purchases via `buy()` are blocked (reverts with Pausable: paused)
     *      - Claiming vested tokens remains fully functional (users can always access already committed funds)
     *
     * This emergency control is designed to protect the protocol and participants during critical situations,
     * such as:
     * - Detected exploit attempts or abnormal activity patterns
     * - Major bugs discovered in referral logic or price calculation
     * - Temporary halts needed during governance migration or treasury reconfiguration
     *
     * Once governance is live, this function should be callable only through a DAO proposal
     * (via ownership transfer or timelock proxy), ensuring decentralized control over emergency actions.
     *
     * @custom:security Only callable by owner — intended as a temporary safeguard, not a centralization vector
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resumes token purchases in the DivineICO contract after being paused.
     * @dev Can only be called by the contract owner.
     * Unpausing restores the ability to call `buy()` and participate in the ICO.
     *
     * This function should be used only after the underlying issue has been resolved and verified,
     * maintaining the protocol's credibility and participant trust.
     *
     * In a mature governance state, unpausing should require DAO consensus to prevent unilateral reactivation.
     *
     * @custom:security Reverts if not currently paused or caller is not owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Updates the direct referral reward rate (owner only)
     * @dev Reverts if exceeding 10000 basis points (100%)
     * @param newBps New reward rate in basis points
     */
    function setReferralBps(uint256 newBps) external onlyOwner {
        if (newBps > 10_000) revert InvalidReferralBps();
        REFERRAL_BPS = newBps;
        emit ReferralBpsUpdated(newBps);
    }

    /**
     * @notice Updates the minimum DIVINE holding required for referral qualification (owner only)
     * @param newMinHold New minimum token balance
     */
    function setMinHoldForReferral(uint256 newMinHold) external onlyOwner {
        MIN_HOLD_FOR_REFERRAL = newMinHold;
        emit MinHoldForReferralUpdated(newMinHold);
    }

    /**
     * @notice Allows users to purchase $DIVINE tokens with ETH.
     * @dev Implements Dutch-auction style ascending price via proportional allocation.
     *      - 10% tokens unlocked immediately
     *      - 90% tokens subject to ~10-year linear vesting
     *      - Two-layer referral rewards paid instantly in ETH (if referrer qualifies)
     *      - Referrer permanently bound on first qualified purchase
     * @param referrer Address of the direct referrer (address(0) = no referral)
     */
    function buy(address referrer) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value > MAX_ETH_PER_TX) revert MaxPerTxExceeded();

        uint256 remaining = DIVINE.balanceOf(address(this));
        if (remaining == 0) revert SoldOut();

        // Proportional allocation: tokens = remaining * msg.value / (100 ether)
        // Multiplication ordered before division to maximise precision
        uint256 tokensOut = remaining * msg.value / (100 * 1e18);
        if (tokensOut == 0) revert InsufficientRemaining();
        if (tokensOut > remaining) tokensOut = remaining;

        uint256 immediate = tokensOut * IMMEDIATE_PERCENT / 100;
        uint256 toVest = tokensOut - immediate;

        DIVINE.safeTransfer(_msgSender(), immediate);

        if (toVest > 0) {
            address buyer = _msgSender();
            if (vestStartTime[buyer] == 0) {
                vestStartTime[buyer] = block.timestamp;
            }
            vestedBalance[buyer] += toVest;
        }

        // Two-tier referral incentive processing
        address directReferrer = address(0);
        address grandReferrer = address(0);
        uint256 directReward = 0;
        uint256 grandReward = 0;

        bool referrerQualified = (
            referrer != address(0) &&
            referrer != _msgSender() &&
            DIVINE.balanceOf(referrer) >= MIN_HOLD_FOR_REFERRAL
        );

        if (referrerQualified) {
            directReferrer = referrer;
            directReward = msg.value * REFERRAL_BPS / 10_000;

            if (directReward > 0) {
                (bool success, ) = payable(directReferrer).call{value: directReward}("");
                if (!success) revert ETHTransferFailed(directReferrer);
            }

            if (map_referrer[_msgSender()] == address(0)) {
                map_referrer[_msgSender()] = directReferrer;
            }

            grandReferrer = map_referrer[directReferrer];
            if (
                grandReferrer != address(0) &&
                grandReferrer != _msgSender() &&
                DIVINE.balanceOf(grandReferrer) >= MIN_HOLD_FOR_REFERRAL
            ) {
                grandReward = msg.value * REFERRAL_BPS / 100_000;
                if (grandReward > 0) {
                    (bool success, ) = payable(grandReferrer).call{value: grandReward}("");
                    if (!success) revert ETHTransferFailed(grandReferrer);
                }
            }
        }

        uint256 toVault = msg.value - directReward - grandReward;
        if (toVault > 0) {
            (bool success, ) = payable(VAULT).call{value: toVault}("");
            if (!success) revert ETHTransferFailed(VAULT);
        }

        emit Bought(_msgSender(), msg.value, tokensOut, directReferrer, grandReferrer, directReward, grandReward);
    }

    /**
     * @notice Claims all currently vested (unlocked) $DIVINE tokens for the caller.
     * @dev Linear release based on time elapsed since first purchase.
     *      Claiming is always allowed (even when contract is paused).
     */
    function claim() external nonReentrant {
        address user = _msgSender();
        uint256 start = vestStartTime[user];
        if (start == 0) revert NoVested();

        uint256 elapsed = block.timestamp - start;
        if (elapsed > VEST_PERIOD) elapsed = VEST_PERIOD;

        uint256 totalUnlockable = vestedBalance[user] * elapsed / VEST_PERIOD;
        uint256 toClaim = totalUnlockable - released[user];

        if (toClaim > 0) {
            released[user] = totalUnlockable;
            DIVINE.safeTransfer(user, toClaim);
            emit Claimed(user, toClaim);
        }
    }

    /**
     * @notice View function returning the currently claimable vested token amount for a given address
     * @param user Address to query
     * @return Claimable token amount
     */
    function pendingClaim(address user) external view returns (uint256) {
        uint256 start = vestStartTime[user];
        if (start == 0) return 0;

        uint256 elapsed = block.timestamp - start;
        if (elapsed > VEST_PERIOD) elapsed = VEST_PERIOD;

        uint256 totalUnlockable = vestedBalance[user] * elapsed / VEST_PERIOD;
        return totalUnlockable - released[user];
    }

    /* Fallback function permitting direct ETH transfers (e.g., accidental sends); funds are non-recoverable */
    receive() external payable {
        (bool success, ) = VAULT.call{value: msg.value}("");
        require(success, "ETH forwarding failed");
    }
}
