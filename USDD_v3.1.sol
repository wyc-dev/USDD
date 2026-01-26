// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title USDD v3.1 on Pantha Capital
 * @notice USDD is a yield-bearing stablecoin representing tokenized real-world assets (RWA) managed by Pantha Capital.
 * Users can deposit USDC to mint USDD 1:1, stake for linear APY-based rewards, request redemption (with manual fulfillment by owner or operation managers),
 * and benefit from a two-layer time-based referral system on qualifying staking actions. Early unstake and small-amount operations incur fees.
 * @dev All USDC deposits are immediately forwarded to the vault address (initially the deployer). Redemption fulfillment pulls USDC from the caller's address
 * (owner or authorized operation manager), allowing separate fund management.
 * The yield backing the protocol is generated off-chain by Pantha Capital, deploying the vault-held USDC into low-risk DeFi strategies,
 * primarily stablecoin liquidity provision on Uniswap V3 / V4 and select other venues.
 * These positions are managed to prioritize capital preservation and consistent yield generation.
 * The resulting real-world yield funds the APY rewards (distributed via on-chain minting) and ensures liquidity for manual redemptions.
 *
 * Staking mechanics:
 * - Supports additive staking (partial additions to a single staked position) with full unstake only (unstake entire staked balance at once).
 * - Reward accrual is linear and time-proportional, delivering proportional share of the annual APY based on holding duration.
 * - Early unstake (< penaltyPeriod) incurs a linearly decreasing fee on principal (max at unstakeFEE).
 * - A configurable minimum lock period enforces a hard lock: unstake is completely blocked until the lock period has elapsed.
 * - Small stakes/redemptions (< boundaryAmount) incur a punitive fee equal to the current APY rate.
 * - This design incentivizes long-term holding and larger positions while keeping calculations simple and predictable.
 *
 * Referral system (two-layer, time-milestone based):
 * - Layer 1 (direct referrer): Rewards released at milestones (instant: 0.5%, 30 days: 0.5%, 90 days: 1%, 180 days: 1%; total up to 3% of qualifying staked amount).
 * - Layer 2 (referrer's referrer): Rewards released at milestones (instant: 0.1%, 30 days: 0.1%, 90 days: 0.1%, 180 days: 0.1%; total up to 0.4% of qualifying staked amount).
 * - Qualifying stakes (≥ boundaryAmount with referrer set) record contributions for independent milestone tracking.
 * - Rewards can be claimed manually by referrers per referee, or automatically settled on stake additions/unstakes to ensure alignment and prevent loss.
 * - Referrer is set once on first qualifying stake and cleared on unstake to prevent referral farming abuse.
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
    error InvalidInput();
    error TooManyContributions();

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
     * @dev Fee decreases linearly to 0 after penaltyPeriod;
     */
    uint256 public unstakeFEE = 100;

    /**
     * @notice Threshold amount in USDD (including 6 decimals) for small-amount operations and referral eligibility
     * @dev Below this threshold: small-amount fee applies and referral reward on small redemption
     *      At or above: referral reward on large deposit
     */
    uint256 public boundaryAmount = 100 * 10**6;

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
     * @notice Seconds in a penalty period for time-based calculations
     */
    uint256 public penaltyPeriod = 180 days;

    /**
    * @notice Minimum lock period in seconds that newly staked USDD must remain locked before unstaking is allowed
    * @dev 
    *   - Applied only to new stakes at the time of staking (existing stakes remain unaffected).
    *   - Default is now 1 day (86400 seconds). The owner can update this to enforce a minimum holding period.
    *   - When a user stakes, their unlockTimestamp is set to stakeStartTime + current minLockPeriod.
    *   - This provides a hard lock (complete block on unstake) in addition to the soft early unstake fee.
    */
    uint256 public minLockPeriod = 86400; // 1 day

    /**
     * @notice USDC contract address on Base chain (fixed for security)
     * @dev Marked immutable for gas savings on reads
     */
    address public immutable USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // New additions for 2-layer referral system

    /**
     * @notice Structure to track individual referral contributions for time-based reward milestones.
     * @dev Each qualifying stake addition records a separate contribution to allow independent milestone progression,
     *      preventing time resets from affecting prior amounts. This supports additive staking while maintaining
     *      proportional rewards. layer1ClaimedMilestones and layer2ClaimedMilestones track claimed indices (0-4)
     *      to prevent duplicate claims. Gas-optimized with uint8 for milestones (max 4).
     */
    struct ReferralContribution {
        uint256 amount; // The staked amount for this contribution (in USDD, 6 decimals)
        uint256 startTime; // Timestamp when this contribution was recorded
        uint8 layer1ClaimedMilestones; // Number of milestones claimed for Layer 1 (0-4)
        uint8 layer2ClaimedMilestones; // Number of milestones claimed for Layer 2 (0-4)
    }

    /**
     * @notice Mapping of user addresses to their array of referral contributions.
     * @dev Allows multiple contributions per user (from additive stakes), enabling independent milestone tracking.
     *      Array design supports dynamic additions but keeps gas low (realistic contributions <10 per user).
     *      Cleared on unstake to prevent abuse and reclaim storage.
     */
    mapping(address => ReferralContribution[]) public referralContributions;

    /**
     * @notice Array of milestone periods in seconds for referral reward releases.
     * @dev Fixed at [0 (instant), 30 days, 90 days, 180 days] for progressive unlocking.
     *      Not updatable to maintain predictability; changes would require governance upgrades.
     */
    uint256[] public milestonePeriods = [0, 30 days, 90 days, 180 days];

    /**
     * @notice Array of Layer 1 reward rates in basis points (bps) for each milestone.
     * @dev Initial: [50, 50, 100, 100] bps (0.5%, 0.5%, 1%, 1%; total 3%).
     *      Updatable by owner (future DAO) to adjust incentives without retroactive effects.
     */
    uint256[] public layer1Rates = [50, 50, 100, 100]; // bps: 0.5%, 0.5%, 1%, 1%

    /**
     * @notice Array of Layer 2 reward rates in basis points (bps) for each milestone.
     * @dev Initial: [10, 10, 10, 10] bps (0.1% x4; total 0.4%).
     *      Updatable by owner (future DAO) to fine-tune multi-level incentives.
     */
    uint256[] public layer2Rates = [10, 10, 10, 10]; // bps: 0.1%, 0.1%, 0.1%, 0.1%

    /**
     * @notice Emitted when referral reward rates are updated.
     * @param layer The layer updated (1 or 2)
     * @param newRates The new array of rates in bps
     */
    event ReferralRatesUpdated(uint8 indexed layer, uint256[] newRates);

    /**
     * @notice Updates the referral reward rates for Layer 1 and/or Layer 2.
     * @dev Only callable by the owner (future DAO). Requires exactly 4 rates per array to match milestones.
     *      Does not affect existing contributions (rates applied at claim time based on current values,
     *      but to maintain fairness, updates should be prospective). Emits events for transparency.
     * @param _newLayer1Rates New rates for Layer 1 (empty array skips update)
     * @param _newLayer2Rates New rates for Layer 2 (empty array skips update)
     */
    function setReferralRates(uint256[] calldata _newLayer1Rates, uint256[] calldata _newLayer2Rates) external onlyOwner {
        if (_newLayer1Rates.length > 0) {
            if (_newLayer1Rates.length != 4) revert InvalidInput(); // Custom error for array length mismatch
            layer1Rates = _newLayer1Rates;
            emit ReferralRatesUpdated(1, _newLayer1Rates);
        }
        if (_newLayer2Rates.length > 0) {
            if (_newLayer2Rates.length != 4) revert InvalidInput();
            layer2Rates = _newLayer2Rates;
            emit ReferralRatesUpdated(2, _newLayer2Rates);
        }
    }

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

    /**
     * @notice Emitted when the penalty period for early unstake fees is updated
     * @param newPeriod The new penalty period in seconds
     */
    event PenaltyPeriodUpdated(uint256 indexed newPeriod);

    // New event for referral claims
    event ReferralRewardClaimed(address indexed referrer, address indexed referee, uint256 amount, uint8 layer);

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
     * @notice Updates the staking APY and maximum early unstake fee in a single transaction
     * @dev Only callable by the contract owner / Lhasa DAO. All values are in basis points.
     * @param _newAPY New staking APY in basis points
     * @param _newFEE New maximum early unstake fee in basis points
     */
    function setAPYandFEE(uint256 _newAPY, uint256 _newFEE) external onlyOwner {
        stakingAPY = _newAPY;
        unstakeFEE = _newFEE;

        emit StakingAPYUpdated(_newAPY);
        emit UnstakeFEEUpdated(_newFEE);
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
     * @notice Updates the penalty period used for early unstake fee calculations
     * @dev Only callable by the contract owner. This period determines the timeframe over which the early unstake fee linearly decreases from the maximum unstakeFEE to zero. Changes do not retroactively affect existing stakes, as fee calculations use the timeStaked relative to the current penaltyPeriod at unstake time. Setting a shorter period accelerates fee decay, potentially increasing liquidity and adoption, while a longer period strengthens long-term holding incentives. Emits a PenaltyPeriodUpdated event for transparency and off-chain monitoring.
     * @param newPeriod The new penalty period in seconds (e.g., 180 days = 15552000 seconds; set to 0 to effectively disable early fees, though not recommended for protocol alignment)
     */
    function setPenaltyPeriod(uint256 newPeriod) external onlyOwner {
        penaltyPeriod = newPeriod;
        emit PenaltyPeriodUpdated(newPeriod);
    }

    /**
     * @notice Deposits USDC to mint USDD 1:1
     * @dev USDC is immediately forwarded to the vault address. USDD is minted directly to the depositor.
     *      This function is a pure deposit mechanism with no referral logic. 
     *      Referrals and associated rewards are handled separately during staking for large positions.
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
     * @dev Small amounts (< boundaryAmount) that pass the minimum check still incur the small-amount fee.
     *      Gas optimized with unchecked arithmetic where overflow is impossible.
     * @param amount Amount of USDD to redeem (6 decimals)
     */
    function requestRedemption(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address investor = _msgSender();

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
     *         referral rewards on large staking actions
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
     *      - If the new staking amount >= boundaryAmount and the user has a referrer set, a referral contribution is added for time-based rewards.
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

        // Transfer the new staking amount to the contract
        IERC20(address(this)).safeTransferFrom(investor, address(this), amount);

        // Load current staked state
        uint256 currentStaked = stakedBalance[investor];

        // If there is an existing stake, accrue and compound pending rewards and settle referral rewards
        uint256 pendingReward = 0;
        uint256 newUnlockTimestamp = block.timestamp + minLockPeriod;

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
            
            // Settle pending referral rewards
            _settleReferralRewards(investor);
            
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

        // Add new referral contribution if qualified
        if (amount >= boundaryAmount && referrerAddress[investor] != address(0)) {
            ReferralContribution[] storage contribs = referralContributions[investor];
            if (contribs.length >= 10) revert TooManyContributions();
            contribs.push(ReferralContribution({
                amount: amount,
                startTime: block.timestamp,
                layer1ClaimedMilestones: 0,
                layer2ClaimedMilestones: 0
            }));
        }

        // Update storage with new compounded + added balance, reset start time, and updated unlock
        stakedBalance[investor] = currentStaked;
        stakeStartTime[investor] = block.timestamp;
        unlockTimestamp[investor] = newUnlockTimestamp;

        emit Staked(investor, amount);
    }

    /**
    * @notice Unstakes the caller's full staked balance, minting accrued rewards and applying fees if applicable
    * @dev Calculates and mints time-based yield rewards. Early unstake (within 365 days) incurs a linearly decreasing fee.
    *      Small stakes incur an additional high punitive fee to discourage small positions.
    *      To prevent referral farming abuse (repeated stake/unstake cycles), the user's referrer is cleared to address(0) after unstake.
    *      This forces potential abusers to make a new deposit with a new referrer and hold for at least 1 year
    *      (to avoid early unstake penalties) before they can trigger another unstake referral reward.
    *      To encourage long-term commitment and prevent short-term cycling for rewards
    *      upon unstake. Users must qualify again (via large referred deposit) to regain.
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

        // Settle pending referral rewards
        _settleReferralRewards(investor);

        uint256 earlyFeeAmount = 0;
        if (unstakeFEE > 0 && timeStaked < penaltyPeriod) {
            uint256 remainingRatio;
            unchecked {
                remainingRatio = (penaltyPeriod - timeStaked) * BPS_DENOMINATOR / penaltyPeriod;
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

        // Clear referral contributions
        delete referralContributions[investor];

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
     * @notice View function to calculate early unstake fee for an account
     * @dev Gas optimized with unchecked arithmetic.
     * @param account Address to query
     * @return Early unstake fee amount in USDD if unstaked now
     */
    function accruePenaltyView(address account) external view returns (uint256) {
        uint256 bal = stakedBalance[account];
        if (bal == 0 || unstakeFEE == 0 || stakeStartTime[account] == 0) return 0;

        uint256 timeStaked = block.timestamp - stakeStartTime[account];
        if (timeStaked >= penaltyPeriod) return 0;

        uint256 remainingRatio;
        unchecked {
            remainingRatio = (penaltyPeriod - timeStaked) * BPS_DENOMINATOR / penaltyPeriod;
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

            // Settle pending referral rewards
            _settleReferralRewards(investor);

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

        // Note: For external sale, assuming no referral trigger here, as it's owner-initiated.

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

    // New referral functions

    /**
     * @notice Calculates the current milestone index for a contribution
     * @param contrib The referral contribution
     * @return The current milestone index (0 to 3)
     */
    function _getCurrentMilestoneIndex(ReferralContribution memory contrib) internal view returns (uint8) {
        uint256 timeStaked = block.timestamp - contrib.startTime;
        if (timeStaked >= milestonePeriods[3]) return 4;
        if (timeStaked >= milestonePeriods[2]) return 3;
        if (timeStaked >= milestonePeriods[1]) return 2;
        if (timeStaked >= milestonePeriods[0]) return 1;
        return 0;
    }

    /**
     * @notice Calculates pending referral reward for a layer from a referee
     * @param referee The referee address
     * @param layer The layer (1 or 2)
     * @return pending The pending reward amount
     */
    function _calculatePending(address referee, uint8 layer) internal view returns (uint256 pending) {
        if (layer != 1 && layer != 2) revert Unauthorized();
        ReferralContribution[] storage contribs = referralContributions[referee];
        uint256[] memory rates = layer == 1 ? layer1Rates : layer2Rates;

        for (uint256 i = 0; i < contribs.length; i++) {
            ReferralContribution memory contrib = contribs[i];
            uint8 claimed = layer == 1 ? contrib.layer1ClaimedMilestones : contrib.layer2ClaimedMilestones;
            uint8 current = _getCurrentMilestoneIndex(contrib);
            for (uint8 j = claimed; j < current; j++) {
                unchecked {
                    pending += (contrib.amount * rates[j]) / BPS_DENOMINATOR;
                }
            }
        }
    }

    /**
     * @notice Updates the claimed milestones for a layer on a referee's contributions
     * @param referee The referee address
     * @param layer The layer (1 or 2)
     */
    function _updateClaimed(address referee, uint8 layer) internal {
        ReferralContribution[] storage contribs = referralContributions[referee];
        for (uint256 i = 0; i < contribs.length; i++) {
            uint8 current = _getCurrentMilestoneIndex(contribs[i]);
            if (layer == 1) {
                contribs[i].layer1ClaimedMilestones = current;
            } else {
                contribs[i].layer2ClaimedMilestones = current;
            }
        }
    }

    /**
     * @notice Settles pending referral rewards for both layers by minting to referrers and updating claimed
     * @param investor The investor (referee) address
     */
    function _settleReferralRewards(address investor) internal {
        address l1 = referrerAddress[investor];
        if (l1 != address(0)) {
            uint256 pending1 = _calculatePending(investor, 1);
            if (pending1 > 0) {
                _mint(l1, pending1);
                emit ReferralRewardClaimed(l1, investor, pending1, 1);
            }
            _updateClaimed(investor, 1);

            address l2 = referrerAddress[l1];
            if (l2 != address(0)) {
                uint256 pending2 = _calculatePending(investor, 2);
                if (pending2 > 0) {
                    _mint(l2, pending2);
                    emit ReferralRewardClaimed(l2, investor, pending2, 2);
                }
                _updateClaimed(investor, 2);
            }
        }
    }

    /**
     * @notice View function to check pending referral reward for the caller from a specific referee
     * @param referee The referee address
     * @return The pending reward amount
     */
    function pendingReferralReward(address referee) external view returns (uint256) {
        address caller = _msgSender();
        address l1 = referrerAddress[referee];
        if (l1 == address(0)) return 0;

        if (caller == l1) {
            return _calculatePending(referee, 1);
        } else {
            address l2 = referrerAddress[l1];
            if (caller == l2) {
                return _calculatePending(referee, 2);
            }
        }
        revert Unauthorized();
    }

    /**
     * @notice Claims pending referral reward for the caller from a specific referee
     * @param referee The referee address
     */
    function claimReferralRewards(address referee) external nonReentrant {
        address caller = _msgSender();
        address l1 = referrerAddress[referee];
        if (l1 == address(0)) revert InvalidReferrer();

        uint8 layer;
        if (caller == l1) {
            layer = 1;
        } else {
            address l2 = referrerAddress[l1];
            if (caller == l2) {
                layer = 2;
            } else {
                revert Unauthorized();
            }
        }

        uint256 pending = _calculatePending(referee, layer);
        if (pending > 0) {
            _mint(caller, pending);
            emit ReferralRewardClaimed(caller, referee, pending, layer);
        }
        _updateClaimed(referee, layer);
    }

    /**
     * @notice Fallback function to accept native ETH transfers (e.g., from failed withdrawals or airdrops)
     */
    receive() external payable {}
}
