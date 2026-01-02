// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title USDD on Pantha Capital
 * @notice USDD is a yield-bearing stablecoin representing tokenized real-world assets (RWA) managed by Pantha Capital.
 * Users can deposit USDC to mint USDD 1:1, stake for linear APY-based rewards, request redemption (with manual fulfillment by owner or operation managers),
 * and benefit from referral rewards on large deposits. Early unstake (non-VIP) and small-amount operations incur fees.
 * @dev All USDC deposits are immediately forwarded to the vault address (initially the deployer). Redemption fulfillment pulls USDC from the caller's address
 * (owner or authorized operation manager), allowing separate fund management.
 * The yield backing the protocol is generated off-chain by Pantha Capital, deploying the vault-held USDC into low-risk DeFi strategies,
 * primarily stablecoin liquidity provision on Uniswap V3 / V4 and select other venues.
 * These positions are managed to prioritize capital preservation and consistent yield generation.
 * The resulting real-world yield funds the APY rewards (distributed via on-chain minting) and ensures liquidity for manual redemptions.
 *
 * Staking mechanics:
 * - Full-amount staking only (stake/unstake entire free balance at once).
 * - Reward accrual is linear and time-proportional, delivering proportional share of the annual APY based on holding duration.
 * - Early unstake (< 365 days, non-VIP) incurs a linearly decreasing fee on principal (max at unstakeFEE).
 * - A configurable minimum lock period enforces a hard lock: unstake is completely blocked until the lock period has elapsed.
 * - Small stakes/redemptions (< boundaryAmount) incur a punitive fee equal to the current APY rate.
 * - This design incentivizes long-term holding and larger positions while keeping calculations simple and predictable.
 *
 * Gas optimizations include: direct transfers to vault, immutable constants where possible, unchecked arithmetic in safe calculations,
 * and minimized storage reads/writes.
 * @custom:security-contact hopeallgood.unadvised619@passinbox.com
 */
contract USDD is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Custom errors for gas-efficient reverts
    error ZeroAmount();
    error NoStakedBalance();
    error NoPendingRedemption();
    error InvalidReferrer();
    error AlreadyHasReferrer();
    error Unauthorized();
    error InvalidAddress();
    error CannotWithdrawUSDD();
    error WithdrawFailed();
    error BelowMinimumRedemption();
    error LockPeriodNotElapsed();

    /**
     * @notice VIP status mapping - VIP addresses are exempt from early unstake fees
     */
    mapping(address user => bool isVip) public isVIP;

    /**
     * @notice Operation manager status mapping - authorized addresses can fulfill redemptions
     * @dev Operation managers act on behalf of the owner for redemption fulfillment using their own funds
     */
    mapping(address manager => bool isManager) public isOperationManager;

    /**
     * @notice Referrer address for each user, set once during first deposit
     * @dev Used for referral reward distribution
     */
    mapping(address user => address referrer) public referrerAddress;

    /**
     * @notice Pending redemption amount per user (after any small-amount fees)
     */
    mapping(address user => uint256 amount) public pendingRedemption;

    /**
     * @notice Total USDD currently queued for redemption across all users
     */
    uint256 public totalPendingRedemption;

    /**
     * @notice Staked USDD balance per user (full-amount staking only)
     */
    mapping(address user => uint256 balance) public stakedBalance;

    /**
     * @notice Timestamp when user staked their USDD
     * @dev Used for reward calculation and early unstake fee determination
     */
    mapping(address user => uint256 startTime) public stakeStartTime;

    /**
     * @notice Timestamp when the user's staked balance becomes unlockable for withdrawal
     * @dev Calculated as stake timestamp + current minLockPeriod at the time of staking.
     *      Existing stakes are unaffected by future changes to minLockPeriod.
     */
    mapping(address user => uint256 timestamp) public unlockTimestamp;

    /**
     * @notice Total USDD currently staked across all users
     */
    uint256 public totalStaked;

    /**
     * @notice Current staking APY in basis points (e.g., 1200 = 12.00%)
     */
    uint256 public stakingAPY = 1200;

    /**
     * @notice Maximum early unstake fee in basis points (e.g., 110 = 1.00%)
     * @dev Fee decreases linearly to 0 after 365 days; VIP addresses are exempt
     */
    uint256 public unstakeFEE = 100;

    /**
     * @notice Referral reward rate in basis points (initially set to 100 = 1.00%)
     * @dev Public variable allowing potential future governance updates if needed.
     *      Current value provides 1% referral reward on qualifying events.
     */
    uint256 public reReRate = 100;

    /**
     * @notice Threshold amount in USDD (including 6 decimals) for small-amount operations and referral eligibility
     * @dev Below this threshold: small-amount fee applies and referral reward on small redemption
     *      At or above: referral reward on large deposit
     */
    uint256 public boundaryAmount = 1000 * 10**6;

    /**
     * @notice Vault address that receives all deposited USDC
     * @dev Initially set to the contract deployer; can be updated by owner to a separate treasury
     */
    address public vault;

    /**
     * @notice Basis points denominator for percentage calculations
     * @dev Marked immutable for gas savings on reads
     */
    uint256 public immutable BPS_DENOMINATOR = 10_000;

    /**
     * @notice Seconds in a standard year for time-based calculations
     * @dev Marked immutable for gas savings on reads
     */
    uint256 public immutable SECONDS_PER_YEAR = 365 days;

    /**
    * @notice Minimum lock period in seconds that newly staked USDD must remain locked before unstaking is allowed
    * @dev 
    *   - Applied only to new stakes at the time of staking (existing stakes remain unaffected).
    *   - Default is 0 (no hard lock). The owner can update this to enforce a minimum holding period.
    *   - When a user stakes, their unlockTimestamp is set to stakeStartTime + current minLockPeriod.
    *   - This provides a hard lock (complete block on unstake) in addition to the soft early unstake fee.
    */
    uint256 public minLockPeriod = 0;

    /**
     * @notice USDC contract address on Base chain (fixed for security)
     * @dev Marked immutable for gas savings on reads
     */
    address public immutable USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Events

    /**
     * @notice Emitted when the staking APY is updated
     * @param newAPY The new APY in basis points
     */
    event StakingAPYUpdated(uint256 indexed newAPY);

    /**
     * @notice Emitted when the maximum early unstake fee is updated
     * @param newFEE The new maximum fee in basis points
     */
    event UnstakeFEEUpdated(uint256 indexed newFEE);

    /**
     * @notice Emitted when the referral reward rate is updated
     * @param newReward The new referral reward rate in basis points
     */
    event reReRateUpdated(uint256 indexed newReward);

    /**
     * @notice Emitted when the boundary amount threshold is updated
     * @param newAmount The new boundary amount
     */
    event BoundaryAmountUpdated(uint256 indexed newAmount);

    /**
     * @notice Emitted when the vault address is updated
     * @param newVault The new vault address
     */
    event VaultUpdated(address indexed newVault);

    /**
     * @notice Emitted when a user's VIP status is updated
     * @param user The user address
     * @param status The new VIP status
     */
    event VIPStatusUpdated(address indexed user, bool status);

    /**
     * @notice Emitted when an operation manager's status is updated
     * @param manager The manager's address
     * @param status The new manager status
     */
    event OperationManagerUpdated(address indexed manager, bool status);

    /**
     * @notice Emitted when a referrer is set for a user
     * @param user The user address
     * @param referrer The referrer address
     */
    event ReferrerSet(address indexed user, address indexed referrer);

    /**
     * @notice Emitted when a referral reward is minted
     * @param referrer The referrer receiving the reward
     * @param referee The user who triggered the reward
     * @param amount The reward amount minted
     * @param reason The context (e.g., "large_deposit", "unstake")
     */
    event ReferralRewardMinted(address indexed referrer, address indexed referee, uint256 amount, string reason);

    /**
     * @notice Emitted when USDC is deposited, and USDD is minted
     * @param user The depositor
     * @param amount The USDC amount deposited
     */
    event USDCDeposited(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a redemption is requested
     * @param user The user requesting redemption
     * @param amount The net USDD amount queued after fees
     * @param smallFeeAmount The small-amount fee deducted (if any)
     */
    event RedemptionRequested(address indexed user, uint256 amount, uint256 smallFeeAmount);

    /**
     * @notice Emitted when a pending redemption is fulfilled
     * @param investor The investor receiving USDC
     * @param amount The USDC amount transferred
     */
    event RedemptionFulfilled(address indexed investor, uint256 amount);

    /**
     * @notice Emitted when USDD is staked
     * @param user The user staking
     * @param amount The USDD amount staked
     */
    event Staked(address indexed user, uint256 amount);

    /**
     * @notice Emitted when pending rewards are accrued and compounded into the staked balance during an additional stake
     * @param user The user whose rewards were compounded
     * @param amount The reward amount minted and added to staked balance
     */
    event RewardsCompounded(address indexed user, uint256 amount);

    /**
     * @notice Emitted when USDD is unstaked
     * @param user The user unstaking
     * @param amount The original staked amount
     * @param earlyFeeAmount The early unstake fee
     * @param smallFeeAmount The small-amount fee
     */
    event Unstaked(address indexed user, uint256 amount, uint256 earlyFeeAmount, uint256 smallFeeAmount);

    /**
     * @notice Emitted when the owner withdraws assets
     * @param token The token address (address(0) for native ETH)
     * @param amount The amount withdrawn
     */
    event AssetsWithdrawn(address indexed token, uint256 amount);

    /**
     * @notice Timestamp when the user's staked balance becomes unlockable for withdrawal
     * @dev Calculated as stake timestamp + current minLockPeriod at the time of staking.
     *      Existing stakes are unaffected by future changes to minLockPeriod.
     */
    event MinLockPeriodUpdated(uint256 indexed newPeriod);

    /**
     * @notice Emitted when a private sale staking position is directly created by the owner
     * @param user The user receiving the staked position
     * @param amount The USDD amount staked
     * @param lockPeriod The custom lock period applied (in seconds)
     */
    event externalSaleStaked(address indexed user, uint256 amount, uint256 lockPeriod);

    /**
     * @notice Emitted when a investor's unlock timestamp is reset by the owner
     * @param investor The investor address
     * @param newUnlockTimestamp The new unlock timestamp
     */
    event StakingUnlockReset(address indexed investor, uint256 newUnlockTimestamp);

    /**
     * @notice Emitted when a pending redemption is reverted/cancelled by the owner
     * @param investor The investor address
     * @param amount The USDD amount returned to the investor
     */
    event RedemptionReverted(address indexed investor, uint256 amount);

    modifier onlyAuthorizedRedeemer() {
        if (_msgSender() != owner() && !isOperationManager[_msgSender()]) revert Unauthorized();
        _;
    }

    /**
     * @notice Contract constructor
     * @dev Sets the deployer as both initial owner and vault address
     * @param initialOwner Initial owner address
     */
    constructor(address initialOwner) ERC20("USDD", "USDD") Ownable(initialOwner) {
        vault = initialOwner;
        isOperationManager[initialOwner] = true;
    }

    /**
     * @notice Returns the number of decimals used by USDD (6 to match USDC 1:1)
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    /**
     * @notice Updates the staking APY, maximum early unstake fee, and referral reward rate in a single transaction
     * @dev Only callable by the contract owner. All values are in basis points.
     *      Example: 1200 = 12.00% APY, 600 = 6.00% max early fee, 100 = 1.00% referral reward.
     * @param _newAPY New staking APY in basis points
     * @param _newFEE New maximum early unstake fee in basis points
     * @param _newReferralReward New referral reward rate in basis points
     */
    function setAPYandFEE(uint256 _newAPY, uint256 _newFEE, uint256 _newReferralReward) external onlyOwner {
        stakingAPY = _newAPY;
        unstakeFEE = _newFEE;
        reReRate = _newReferralReward;

        emit StakingAPYUpdated(_newAPY);
        emit UnstakeFEEUpdated(_newFEE);
        emit reReRateUpdated(_newReferralReward);
    }

    /**
     * @notice Updates the boundary amount threshold used for small-amount fees and referral rewards
     * @dev Only callable by the contract owner
     * @param _newAmount New boundary amount in USDD (with 6 decimals)
     */
    function setBoundaryAmount(uint256 _newAmount) external onlyOwner {
        boundaryAmount = _newAmount;
        emit BoundaryAmountUpdated(_newAmount);
    }

    /**
     * @notice Updates the vault address that receives deposited USDC
     * @dev Only callable by the contract owner. Cannot be set to the zero address
     * @param _newVault Address of the new vault/treasury
     */
    function setVault(address _newVault) external onlyOwner {
        if (_newVault == address(0)) revert InvalidAddress();
        vault = _newVault;
        emit VaultUpdated(_newVault);
    }

    /**
     * @notice Sets or removes VIP status for a user
     * @dev VIP users are exempt from early unstake fees. Only callable by the contract owner
     * @param user Address of the user
     * @param status True to grant VIP status, false to revoke
     */
    function setVIP(address user, bool status) external onlyOwner {
        isVIP[user] = status;
        emit VIPStatusUpdated(user, status);
    }

    /**
    * @notice Updates the minimum lock period applied to new stakes
    * @dev Only callable by the contract owner. Changes do not retroactively affect existing stakes.
    * @param newPeriod The new minimum lock period in seconds (set to 0 to disable the hard lock)
    */
    function setMinLockPeriod(uint256 newPeriod) external onlyOwner {
        minLockPeriod = newPeriod;
        emit MinLockPeriodUpdated(newPeriod);
    }

    /**
     * @notice Grants or revokes operation manager privileges
     * @dev Operation managers can fulfill redemptions on behalf of the owner. Only callable by the contract owner
     * @param manager Address of the manager
     * @param status True to grant privileges, false to revoke
     */
    function setOperationManager(address manager, bool status) external onlyOwner {
        isOperationManager[manager] = status;
        emit OperationManagerUpdated(manager, status);
    }

    /**
     * @notice Deposits USDC to mint USDD 1:1
     * @dev USDC is immediately forwarded to the vault address. USDD is minted directly to the depositor.
     *      This function is a pure deposit mechanism with no referral logic. Referrals and associated rewards
     *      (including automatic VIP grants) are handled separately during staking for large positions.
     *      Gas optimized by direct transfer to vault without intermediate steps.
     * @param amount Amount of USDC to deposit (6 decimals)
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address investor = _msgSender();

        IERC20(USDC_BASE).safeTransferFrom(investor, vault, amount);

        _mint(investor, amount);

        emit USDCDeposited(investor, amount);
    }

    /**
     * @notice Requests redemption by burning USDD and queuing USDC for manual fulfillment
     * @dev Non-VIP users must redeem at least boundaryAmount. VIP users have no minimum.
     *      Small amounts (< boundaryAmount) that pass the minimum check still incur the small-amount fee.
     *      Gas optimized with unchecked arithmetic where overflow is impossible.
     * @param amount Amount of USDD to redeem (6 decimals)
     */
    function requestRedemption(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address investor = _msgSender();

        if (!isVIP[investor] && amount < boundaryAmount) revert BelowMinimumRedemption();

        IERC20(address(this)).safeTransferFrom(investor, address(this), amount);

        uint256 smallFeeAmount = 0;
        if (amount < boundaryAmount && stakingAPY > 0) {

            // Deliberately high penalty for small-amount redemptions: fee = current staking APY rate.
            // Intent: Make it unprofitable for small holders to earn meaningful yield or exit early,
            // effectively forcing them to deposit larger amounts (≥ boundaryAmount) to access full benefits
            // and avoid this punitive fee. This encourages capital consolidation and ecosystem growth.

            unchecked {
                smallFeeAmount = (amount * stakingAPY) / BPS_DENOMINATOR;
            }
            if (smallFeeAmount > 0) {
                IERC20(address(this)).safeTransfer(owner(), smallFeeAmount);
            }
            unchecked {
                amount -= smallFeeAmount;
            }
        }

        unchecked {
            pendingRedemption[investor] += amount;
            totalPendingRedemption += amount;
        }

        emit RedemptionRequested(investor, amount, smallFeeAmount);
    }

    /**
     * @notice Fulfills a pending redemption by transferring USDC from the caller to the investor
     * @dev Only callable by the owner or authorized operation managers. USDC is pulled from the caller's balance.
     *      Gas optimized by direct transfer and unchecked subtractions.
     * @param investor Address of the investor whose redemption to fulfill
     */
    function fulfillRedemption(address investor) external onlyAuthorizedRedeemer nonReentrant {
        uint256 amount = pendingRedemption[investor];
        if (amount == 0) revert NoPendingRedemption();

        IERC20(USDC_BASE).safeTransferFrom(_msgSender(), investor, amount);

        _burn(address(this), amount);

        pendingRedemption[investor] = 0;
        unchecked {
            totalPendingRedemption -= amount;
        }

        emit RedemptionFulfilled(investor, amount);
    }

    /**
     * @notice Allows the owner or authorized operation managers to revert/cancel a investor's pending redemption request
     * @dev Returns the full queued (net) USDD amount from the contract balance to the investor and clears the pending queue.
     *      Does not refund any small-amount fees already taken (those were transferred to owner).
     *      Useful for correcting mistaken redemptions or handling special cases.
     * @param investor The investor address whose redemption to revert
     */
    function revertRedemption(address investor) external onlyAuthorizedRedeemer nonReentrant {
        uint256 amount = pendingRedemption[investor];
        if (amount == 0) revert NoPendingRedemption();

        // Return the queued net amount to the investor
        IERC20(address(this)).safeTransfer(investor, amount);

        pendingRedemption[investor] = 0;

        unchecked {
            totalPendingRedemption -= amount;
        }

        emit RedemptionReverted(investor, amount);
    }

    /**
     * @notice Stakes a specified amount of the caller's free USDD balance, adding to any existing staked position
     *         with automatic compounding of pending rewards, and optionally setting a referrer to trigger
     *         referral rewards and VIP status on large staking actions
     * @dev Users maintain a single staked position that can be increased over time. When adding to an existing stake:
     *      - Pending rewards are calculated based on the current staked balance and time elapsed.
     *      - Rewards are minted directly to the contract and added to the user's staked balance (compounding).
     *      - The new amount is then added to the compounded staked balance.
     *      - stakeStartTime is reset to the current timestamp (restarting linear reward accrual on the new total principal).
     *      - unlockTimestamp is set to the maximum of the existing unlock timestamp and (current timestamp + minLockPeriod),
     *        ensuring that adding stake cannot shorten an existing lock period and that new additions respect the current minLockPeriod.
     *      
     *      Referral mechanics:
     *      - If a non-zero referrer address is provided and the caller has no existing referrer,
     *        it is set permanently (until cleared on unstake).
     *      - If the new staking amount >= boundaryAmount and the user has a referrer set, a referral reward is minted to the referrer
     *        at the configured reReRate.
     *      - Separately, if a referrer is explicitly provided in this transaction and the new staking amount >= 1000 * boundaryAmount,
     *        automatic VIP status is granted to the staker (if not already VIP) — incentivizing active use of referral links during
     *        very large staking actions.
     *      
     *      This design maintains simplicity (single position, linear time-based rewards) while enabling
     *      compounding and additional stakes. Gas optimized with direct transfers, unchecked arithmetic
     *      where safe, and minimal storage writes.
     * @param amount Amount of USDD to stake/add (6 decimals; must be > 0 and <= caller's free balance)
     * @param referrer Optional referrer address (address(0) if none; can only be set once until unstake)
     */
    function stakeUSDD(uint256 amount, address referrer) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address investor = _msgSender();

        // Handle referrer setting (only if provided and not already set)
        bool hasReferrer = referrer != address(0);

        if (hasReferrer) {
            if (referrer == investor) revert InvalidReferrer();
            if (referrerAddress[investor] != address(0)) revert AlreadyHasReferrer();

            referrerAddress[investor] = referrer;
            emit ReferrerSet(investor, referrer);
        }

        // Calculate and apply referral reward if new staking amount >= boundaryAmount
        uint256 referralReward = 0;
        if (amount >= boundaryAmount) {
            unchecked {
                referralReward = (amount * reReRate) / BPS_DENOMINATOR;
            }
            if (referralReward > 0 && referrerAddress[investor] != address(0)) {
                _mint(referrerAddress[investor], referralReward);
                emit ReferralRewardMinted(referrerAddress[investor], investor, referralReward, "referred_stake");
            }
        }

        // Auto-grant VIP status if a referrer was explicitly provided in this transaction and amount >= 10 * boundaryAmount
        if (hasReferrer && !isVIP[investor]) {
            unchecked {
                if (amount >= boundaryAmount * 1000) {
                    isVIP[investor] = true;
                    emit VIPStatusUpdated(investor, true);
                }
            }
        }

        // Transfer the new staking amount to the contract
        IERC20(address(this)).safeTransferFrom(investor, address(this), amount);

        // Load current staked state
        uint256 currentStaked = stakedBalance[investor];

        // If there is an existing stake, accrue and compound pending rewards
        uint256 pendingReward = 0;
        uint256 newUnlockTimestamp = block.timestamp + minLockPeriod;

        if (currentStaked > 0) {
            uint256 timeStaked = block.timestamp - stakeStartTime[investor];
            unchecked {
                pendingReward = (currentStaked * stakingAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
            }
            if (pendingReward > 0) {
                _mint(address(this), pendingReward);
                emit RewardsCompounded(investor, pendingReward); // New event recommended (see below)
            }
            unchecked {
                currentStaked += pendingReward;
                totalStaked += pendingReward;
            }
            
            // Preserve existing unlock timestamp if it is later (prevents lock shortening)
            if (unlockTimestamp[investor] > newUnlockTimestamp) {
                newUnlockTimestamp = unlockTimestamp[investor];
            }
        }

        // Add the new staking amount
        unchecked {
            currentStaked += amount;
            totalStaked += amount;
        }

        // Update storage with new compounded + added balance, reset start time, and updated unlock
        stakedBalance[investor] = currentStaked;
        stakeStartTime[investor] = block.timestamp;
        unlockTimestamp[investor] = newUnlockTimestamp;

        emit Staked(investor, amount);
    }

    /**
    * @notice Unstakes the caller's full staked balance, minting accrued rewards and applying fees if applicable
    * @dev Calculates and mints time-based yield rewards. Early unstake (within 365 days) incurs a linearly decreasing fee (VIP exempt).
    *      Small stakes incur an additional high punitive fee to discourage small positions.
    *      To prevent referral farming abuse (repeated stake/unstake cycles), the user's referrer is cleared to address(0) after unstake.
    *      This forces potential abusers to make a new deposit with a new referrer and hold for at least 1 year
    *      (to avoid early unstake penalties) before they can trigger another unstake referral reward.
    *      To encourage long-term commitment and prevent short-term cycling for rewards, VIP status is automatically revoked
    *      upon unstake. Users must qualify again (via large referred deposit) to regain VIP privileges on future stakes.
    *      Gas optimized with unchecked arithmetic in calculations where overflow is impossible.
    */
    function unstakeUSDD() external nonReentrant {
        address investor = _msgSender();

        uint256 amount = stakedBalance[investor];
        if (amount == 0) revert NoStakedBalance();
        if (block.timestamp < unlockTimestamp[investor]) revert LockPeriodNotElapsed();

        uint256 timeStaked = block.timestamp - stakeStartTime[investor];

        uint256 rewardToMint;
        unchecked {
            rewardToMint = (amount * stakingAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        }
        if (rewardToMint > 0) {
            _mint(investor, rewardToMint);
        }

        uint256 earlyFeeAmount = 0;
        if (!isVIP[investor] && unstakeFEE > 0 && timeStaked < SECONDS_PER_YEAR) {
            uint256 remainingRatio;
            unchecked {
                remainingRatio = (SECONDS_PER_YEAR - timeStaked) * BPS_DENOMINATOR / SECONDS_PER_YEAR;
            }
            uint256 feeRate;
            unchecked {
                feeRate = (unstakeFEE * remainingRatio) / BPS_DENOMINATOR;
            }
            unchecked {
                earlyFeeAmount = (amount * feeRate) / BPS_DENOMINATOR;
            }
        }

        uint256 smallFeeAmount = 0;
        if (amount < boundaryAmount && stakingAPY > 0) {

            // Deliberately high penalty for small stakes: fee = current staking APY rate.
            // Intent: Prevent small holders from profiting from yield, forcing them to consolidate
            // into larger positions (≥ boundaryAmount) to access fair APY without punitive deductions.
            // This design incentivizes larger, longer-term commitments to the protocol.

            unchecked {
                smallFeeAmount = (amount * stakingAPY) / BPS_DENOMINATOR;
            }
        }

        // Clear referrer after reward is issued to prevent referral farming loops
        // Users must make a fresh deposit with a new referrer to qualify for future unstake referrals

        if (referrerAddress[investor] != address(0)) {
            referrerAddress[investor] = address(0);
        }

        // Revoke VIP status on unstake to incentivize long-term holding
        // VIP privileges must be re-qualified through future large referred deposits

        if (isVIP[investor]) {
            isVIP[investor] = false;
            emit VIPStatusUpdated(investor, false);
        }

        uint256 totalFee;
        unchecked {
            totalFee = earlyFeeAmount + smallFeeAmount;
        }
        uint256 amountAfterFee;
        unchecked {
            amountAfterFee = amount - totalFee;
        }

        IERC20(address(this)).safeTransfer(investor, amountAfterFee);

        if (totalFee > 0) {
            IERC20(address(this)).safeTransfer(owner(), totalFee);
        }

        unchecked {
            totalStaked -= amount;
        }
        delete stakedBalance[investor];
        delete stakeStartTime[investor];
        delete unlockTimestamp[investor];

        emit Unstaked(investor, amount, earlyFeeAmount, smallFeeAmount);
    }

    /**
     * @notice View function to calculate pending staking reward for an account
     * @dev Gas optimized with unchecked arithmetic.
     * @param account Address to query
     * @return Pending reward in USDD (not yet minted)
     */
    function accrueRewardView(address account) external view returns (uint256) {
        uint256 bal = stakedBalance[account];
        if (bal == 0 || stakeStartTime[account] == 0) return 0;

        uint256 timeStaked = block.timestamp - stakeStartTime[account];
        unchecked {
            return (bal * stakingAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        }
    }

    /**
     * @notice View function to calculate early unstake fee for an account (VIP exempt)
     * @dev Gas optimized with unchecked arithmetic.
     * @param account Address to query
     * @return Early unstake fee amount in USDD if unstaked now
     */
    function accruePenaltyView(address account) external view returns (uint256) {
        uint256 bal = stakedBalance[account];
        if (bal == 0 || unstakeFEE == 0 || stakeStartTime[account] == 0) return 0;

        if (isVIP[account]) return 0;

        uint256 timeStaked = block.timestamp - stakeStartTime[account];
        if (timeStaked >= SECONDS_PER_YEAR) return 0;

        uint256 remainingRatio;
        unchecked {
            remainingRatio = (SECONDS_PER_YEAR - timeStaked) * BPS_DENOMINATOR / SECONDS_PER_YEAR;
        }
        uint256 feeRate;
        unchecked {
            feeRate = (unstakeFEE * remainingRatio) / BPS_DENOMINATOR;
        }
        unchecked {
            return (bal * feeRate) / BPS_DENOMINATOR;
        }
    }

    /**
     * @notice View function to query the remaining hard-lock time for a staked account
     * @dev Returns 0 if the account has no active stake or if the lock period has already elapsed.
     * @param account The user address to query
     * @return remainingSeconds Remaining seconds until the stake becomes unlockable (0 if already unlockable)
     */
    function remainingLockTime(address account) external view returns (uint256) {
        if (stakedBalance[account] == 0 || unlockTimestamp[account] <= block.timestamp) {
            return 0;
        }
        return unlockTimestamp[account] - block.timestamp;
    }

    /**
     * @notice Allows the owner to directly mint and stake/add USDD for an investor (e.g., private sale, bridging, off-chain allocations)
     * @dev Mints the specified USDD amount directly to the contract and adds it to the investor's staked position.
     *      This bypasses normal deposit flow and inflates supply without corresponding on-chain USDC backing —
     *      use only for fully backed private sales, cross-chain staking, or allocations where funds are handled off-chain.
     *      
     *      Supports adding to existing stakes with automatic reward compounding:
     *      - If the investor has an existing staked position, pending rewards are calculated, minted to the contract,
     *        and added to the staked balance (compounding).
     *      - The new minted amount is then added to the (compounded) staked balance.
     *      - stakeStartTime is reset to the current timestamp (restarting linear reward accrual on the new total principal).
     *      - unlockTimestamp is set to the maximum of the existing unlock timestamp and (current timestamp + provided timePeriod),
     *        ensuring that adding cannot shorten an existing lock period and that the new addition respects the custom timePeriod.
     *      
     *      Gas optimized with direct minting, unchecked arithmetic where safe, and minimal storage operations.
     * @param amount The USDD amount to mint and stake/add (6 decimals)
     * @param investor The investor address to stake/add for
     * @param timePeriod The custom lock period extension in seconds (applied to the new addition from now)
     */
    function externalSale(uint256 amount, address investor, uint256 timePeriod) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (investor == address(0)) revert InvalidAddress();

        // Mint the new amount directly to the contract
        _mint(address(this), amount);

        // Load current staked state
        uint256 currentStaked = stakedBalance[investor];

        // If there is an existing stake, accrue and compound pending rewards
        uint256 pendingReward = 0;
        uint256 newUnlockTimestamp = block.timestamp + timePeriod;

        if (currentStaked > 0) {
            uint256 timeStaked = block.timestamp - stakeStartTime[investor];

            unchecked {
                pendingReward = (currentStaked * stakingAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
            }

            if (pendingReward > 0) {
                _mint(address(this), pendingReward);
                emit RewardsCompounded(investor, pendingReward);
            }

            unchecked {
                currentStaked += pendingReward;
                totalStaked += pendingReward;
            }

            // Preserve existing unlock timestamp if it is later (prevents lock shortening)
            if (unlockTimestamp[investor] > newUnlockTimestamp) {
                newUnlockTimestamp = unlockTimestamp[investor];
            }
        }

        // Add the new minted amount
        unchecked {
            currentStaked += amount;
            totalStaked += amount;
        }

        // Update storage with new compounded + added balance, reset start time, and updated unlock
        stakedBalance[investor] = currentStaked;
        stakeStartTime[investor] = block.timestamp;
        unlockTimestamp[investor] = newUnlockTimestamp;

        emit Staked(investor, amount);
        emit externalSaleStaked(investor, amount, timePeriod);
    }

    /**
     * @notice Allows the owner to reset the unlock timestamp for an existing staked position
     * @dev Sets a new unlock timestamp based on the current block timestamp + provided timePeriod.
     *      Can be used to extend or shorten the lock period. Does not affect stakeStartTime or rewards accrual.
     *      Only affects the hard lock (unstake blockage); early unstake fee (if applicable) is calculated separately.
     * @param investor The address of the staked investor
     * @param timePeriod The new lock period duration in seconds (added to current timestamp)
     */
    function ResetInvestorUnlockTime(address investor, uint256 timePeriod) external onlyOwner {
        if (stakedBalance[investor] == 0) revert NoStakedBalance();

        uint256 newUnlock = block.timestamp + timePeriod;
        unlockTimestamp[investor] = newUnlock;

        emit StakingUnlockReset(investor, newUnlock);
    }

    /**
     * @notice Allows the owner to withdraw any ERC20 token or native ETH held by the contract
     * @dev Prevents withdrawal of USDD tokens to avoid interfering with protocol balances.
     *      Gas optimized by checking balance before transfer.
     * @param token Address of the token to withdraw (address(0) for native ETH)
     */
    function withdrawAssets(address token) external onlyOwner {
        if (token == address(this)) revert CannotWithdrawUSDD();

        if (token == address(0)) {
            uint256 ethBalance = address(this).balance;
            if (ethBalance > 0) {
                (bool success, ) = payable(owner()).call{value: ethBalance}("");
                if (!success) revert WithdrawFailed();
                emit AssetsWithdrawn(address(0), ethBalance);
            }
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(owner(), balance);
                emit AssetsWithdrawn(token, balance);
            }
        }
    }

    /**
     * @notice Fallback function to accept native ETH transfers (e.g., from failed withdrawals or airdrops)
     */
    receive() external payable {}
}
