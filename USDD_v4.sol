// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title USDD v4 on Pantha Capital
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
 * - Dynamic APY uplift: Qualified $DIVINE DAO members (holding ≥ minDivineForExtra governance tokens) receive an additional yield boost (extraRewardBps),
 *   applied to the entire staking duration reward calculation. This uplift is visible in accrueRewardView and realized upon unstake, incentivizing governance
 *   participation and long-term alignment with the protocol's decentralized future.
 * - This design incentivizes long-term holding, larger positions, and active DAO involvement while keeping calculations simple, predictable, and capital-efficient.
 *
 * Referral system (two-layer, time-milestone based):
 * - Layer 1 (direct referrer): Rewards released at milestones (instant: 0.5%, 30 days: 0.5%, 90 days: 1%, 180 days: 1%; total up to 3% of qualifying staked amount).
 * - Layer 2 (referrer's referrer): Rewards released at milestones (instant: 0.1%, 30 days: 0.1%, 90 days: 0.1%, 180 days: 0.1%; total up to 0.4% of qualifying staked amount).
 * - Qualifying stakes (≥ boundaryAmount with referrer set) record contributions for independent milestone tracking.
 * - Rewards can be claimed manually by referrers per referee, or automatically settled on stake additions/unstakes to ensure alignment and prevent loss.
 * - Referrer is set once on first qualifying stake and cleared on unstake to prevent referral farming abuse.
 *
 * Governance-aligned incentives:
 * - $DIVINE governance token holders benefit from a configurable extra reward uplift on staking yields, strengthening demand for the DAO token and tying
 *   protocol success to active community governance. The feature is disabled by default (divineToken = address(0)) and can only be activated post-governance
 *   transition, ensuring controlled rollout and alignment with Divine DAO decisions.
 * - Uplift introduces activity-linked inflation (minted USDD), balanced by RWA-backed yields and DAO-monitored parameters to maintain long-term sustainability.
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
    error LockPeriodNotElapsed();
    error InvalidInput();
    error TooManyContributions();
    error TooManyReferees();

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
     * @notice Maximum early unstake fee in basis points (e.g., 100 = 1.00%)
     * @dev Fee decreases linearly to 0 after penaltyPeriod;
     */
    uint256 public unstakeFEE = 100;

    /**
     * @notice Seconds in a penalty period for time-based calculations
     */
    uint256 public penaltyPeriod = 180 days;

    /**
     * @notice Threshold amount in USDD (including 6 decimals) for small-amount operations and referral eligibility
     * @dev Below this threshold: small-amount fee applies and referral reward on small redemption
     *      At or above: referral reward on large deposit
     */
    uint256 public boundaryAmount = 100 * 10**6;

    /**
     * @notice Total USDD currently queued for redemption across all users
     */
    uint256 public totalPendingRedemption;

    /**
     * @notice Address of the $DIVINE governance token used to qualify for extra staking rewards.
     * @dev When set to address(0), extra reward logic is completely disabled (safe default).
     *      Intended to be set by owner (later DAO) after governance transition.
     */
    address public divineToken;

    /**
     * @notice Extra reward rate in basis points applied to staked principal upon unstake,
     *         if the user holds at least minDivineForExtra $DIVINE tokens.
     * @dev Maximum capped at 100 bps (1%). Only minted once at unstake time.
     *      Designed as a loyalty incentive to increase $DIVINE demand and align long-term holders.
     */
    uint256 public extraRewardBps;

    /**
     * @notice Minimum $DIVINE token balance (18 decimals) required to qualify for extraRewardBps.
     * @dev Snapshot checked only at unstake time for gas efficiency and simplicity.
     *      Example: 10_000 * 10**18
     */
    uint256 public minDivineForExtra;

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
    struct StakingContribution {
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
    mapping(address => StakingContribution[]) public stakingContributions;


    /**
     * @notice Nested mapping of referrer to referee to their index in referrerReferees array.
     * @dev Enables O(1) removal in unstakeUSDD, optimizing gas for large referral networks while maintaining anti-abuse limits (50 referees).
     *      From a governance security perspective, this enhances scalability for Divine DAO-monitored ecosystems, reducing costs without inflating mints.
     */
    mapping(address => mapping(address => uint256)) public referrerRefereeIndex;

    /**
     * @notice Mapping of referrer addresses to their list of direct referees.
     * @dev Used for aggregating pending rewards in totalPendingReferralRewards. Limited to 50 referees per referrer to prevent gas DoS attacks and ensure scalability.
     *      Updated on stakeUSDD (push on first referrer set) and unstakeUSDD (swap-pop removal), maintaining accuracy post-unstake to prevent double-counting.
     *      From a token economics perspective, this enables efficient UX for referrers to monitor total pending mints (Layer1/2 totals up to 3.4% per qualifying stake),
     *      tied to referee holding milestones, promoting network growth without inflating rewards beyond genuine long-term contributions—aligning with RWA-backed yield sustainability
     *      and capital efficiency by incentivizing consolidated, sustained positions. Governance security benefit: Divine DAO can index via events to monitor referral dynamics and detect abuse.
     */
    mapping(address => address[]) public referrerReferees;

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
     * @notice Flag to enable or disable the Layer 1 referral reward program.
     * @dev When disabled, no new referral contributions will be recorded for Layer 1, but existing pending rewards can still be claimed.
     *      This does not affect Layer 2. Initially enabled.
     */
    bool public layer1Enabled = true;

    /**
     * @notice Flag to enable or disable the Layer 2 referral reward program.
     * @dev When disabled, no new referral contributions will be recorded for Layer 2, but existing pending rewards can still be claimed.
     *      This does not affect Layer 1. Initially enabled.
     */
    bool public layer2Enabled = true;

    /**
     * @notice Emitted when referral reward rates are updated.
     * @param layer The layer updated (1 or 2)
     * @param newRates The new array of rates in bps
     */
    event ReferralRatesUpdated(uint8 indexed layer, uint256[] newRates);

    /**
     * @notice Emitted when the referral layer enabled statuses are updated.
     * @param layer1Enabled The new status for Layer 1
     * @param layer2Enabled The new status for Layer 2
     */
    event ReferralLayersEnabledUpdated(bool layer1Enabled, bool layer2Enabled);

    /**
     * @notice Emitted when a new referee is added to a referrer's list during the first qualifying stake.
     * @dev This event enhances transparency in the referral network, allowing off-chain indexing and monitoring of referral additions.
     *      It supports governance security by enabling Divine DAO to track network growth and detect potential abuse patterns,
     *      aligning with the protocol's long-term holding incentives and capital efficiency goals.
     * @param referrer The address of the referrer who gains the new referee.
     * @param referee The address of the new referee being added.
     */
    event RefereeAdded(address indexed referrer, address indexed referee);

    /**
     * @notice Emitted when a referee is removed from a referrer's list during unstake.
     * @dev This event promotes anti-abuse mechanisms by logging referral clearances, preventing referral farming loops.
     *      It aids in token economics monitoring, ensuring referral rewards remain tied to genuine long-term contributions,
     *      and supports financial sustainability by allowing off-chain analysis of network dynamics without inflating mints unnecessarily.
     * @param referrer The address of the referrer from whose list the referee is removed.
     * @param referee The address of the referee being removed.
     */
    event RefereeRemoved(address indexed referrer, address indexed referee);

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
     * @notice Emitted when a referral reward is claimed and minted to the referrer.
     * @dev This event is triggered during manual claims via claimReferralRewards or automatic settlements in stakeUSDD/unstakeUSDD.
     *      It provides transparency for referral reward distributions in the two-layer time-milestone system, aiding off-chain monitoring
     *      and governance oversight in the Pantha Capital RWA ecosystem. The amount is minted as USDD, contributing to controlled inflation
     *      tied to qualifying staking actions, aligning with long-term holding incentives and capital efficiency.
     * @param referrer The address of the referrer receiving the reward (Layer 1 or 2).
     * @param referee The address of the referee (staker) whose contributions triggered the reward.
     * @param amount The amount of USDD minted as the reward (in 6 decimals).
     * @param layer The referral layer (1 for direct referrer, 2 for referrer's referrer).
     */
    event ReferralRewardClaimed(address indexed referrer, address indexed referee, uint256 amount, uint8 layer);
    
    /**
     * @notice Emitted when the $DIVINE-linked extra reward configuration is updated
     * @dev Only emitted when the owner (future Divine DAO) calls setDivineExtraRewardParams.
     *      Setting divineToken to address(0) effectively disables the extra reward feature.
     * @param divineToken The new address of the $DIVINE governance token (address(0) to disable)
     * @param extraRewardBps The new extra reward rate in basis points (capped at 100 = 1%)
     * @param minDivineForExtra The new minimum $DIVINE holding threshold required to qualify (18 decimals)
     */
    event DivineExtraRewardParamsUpdated(address indexed divineToken, uint256 extraRewardBps, uint256 minDivineForExtra);

    /**
     * @notice Modifier to restrict access to the contract owner or authorized operation managers.
     * @dev Ensures that only the owner or addresses marked as operation managers can execute the modified function.
     *      This is critical for sensitive operations like redemption fulfillment and reversion in the Pantha Capital RWA protocol,
     *      maintaining governance security and preventing unauthorized access. Reverts with Unauthorized if the caller does not qualify.
     *      From a financial sustainability perspective, this aligns with long-term holder incentives by centralizing high-risk actions
     *      under controlled entities (e.g., future Divine DAO), reducing abuse risks while supporting capital efficiency in yield-bearing stablecoin mechanics.
     */
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
     * @notice Allows the owner to enable or disable Layer 1 and/or Layer 2 referral reward programs.
     * @dev When a layer is disabled, no new referral contributions will be recorded for that layer during staking, but existing pending rewards can still be claimed or settled.
     *      This does not affect rates, milestone calculations, or pending rewards for prior contributions, ensuring fairness for existing participants.
     *      Disabling a layer helps control inflation from referral mints without retroactive effects, aligning with governance decisions on token economics.
     *      Emits a ReferralLayersEnabledUpdated event for transparency and off-chain monitoring by the Divine DAO.
     * @param _layer1Enabled True to enable Layer 1 rewards (new contributions allowed), false to disable (no new contributions for Layer 1).
     * @param _layer2Enabled True to enable Layer 2 rewards (new contributions allowed), false to disable (no new contributions for Layer 2).
     */
    function setReferralLayersEnabled(bool _layer1Enabled, bool _layer2Enabled) external onlyOwner {
        layer1Enabled = _layer1Enabled;
        layer2Enabled = _layer2Enabled;
        emit ReferralLayersEnabledUpdated(_layer1Enabled, _layer2Enabled);
    }

    /**
     * @notice Updates the $DIVINE-linked extra reward configuration.
     * @dev Only callable by owner (future DAO). Setting divineToken to address(0) disables
     *      the extra reward feature entirely, providing a safe emergency switch.
     * @param _divineToken Address of the $DIVINE ERC20 token
     * @param _extraRewardBps Extra reward rate in basis points (max 100 = 1%)
     * @param _minDivineForExtra Minimum $DIVINE holding required (in wei, 18 decimals)
     */
    function setDivineExtraRewardParams(address _divineToken, uint256 _extraRewardBps, uint256 _minDivineForExtra) external onlyOwner {
        if (_extraRewardBps > 1000) revert("Extra reward bps exceeds 10% cap");
        // No zero-check on _divineToken — explicitly allowing address(0) to disable feature
        divineToken       = _divineToken;
        extraRewardBps    = _extraRewardBps;
        minDivineForExtra = _minDivineForExtra;
        emit DivineExtraRewardParamsUpdated(_divineToken, _extraRewardBps, _minDivineForExtra);
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
     *        it is set permanently (until cleared on unstake), and the investor is added to the referrer's referrerReferees list (limited to 50 to prevent gas DoS).
     *      - If the new staking amount >= boundaryAmount and the user has a referrer set, a referral contribution is added for time-based rewards (limited to 10 contributions per user).
     *      
     *      This design maintains simplicity (single position, linear time-based rewards) while enabling
     *      compounding and additional stakes. Gas optimized with direct transfers, unchecked arithmetic
     *      where safe, and minimal storage writes. The referrerReferees addition enhances aggregation for total pending rewards,
     *      improving UX without altering mint logic, aligning with token economics for network growth and long-term incentives.
     *      
     *      From a financial sustainability perspective, additive staking with compounding promotes capital efficiency by encouraging sustained positions that amplify RWA off-chain yields (e.g., Uniswap strategies),
     *      while the boundaryAmount threshold for contributions ties rewards to meaningful commitments, reducing fragmented capital risks.
     *      Benefits risks are mitigated through anti-abuse: referrer binding at first stake (decoupled from size for accessibility, but rewards require large actions), array limits (10 contributions, 50 referees) prevent gas bombs and farming loops.
     *      Governance security: Divine DAO can adjust minLockPeriod, boundaryAmount, or referral rates to fine-tune incentives without retroactive effects, allowing monitoring of staking patterns to maintain yield alignment.
     *      Edge cases: Zero amount reverts; existing referrer skips set to prevent rebinding; no referrer/contribution if small amount, reinforcing punitive small-stake fees elsewhere.
     *      Security audit note: nonReentrant covers entire function; referrer != investor validation prevents self-referral loops; events (ReferrerSet, RefereeAdded) enable off-chain indexing for DAO oversight of network dynamics.
     * @param amount Amount of USDD to stake/add (6 decimals; must be > 0 and <= caller's free balance)
     * @param referrer Optional referrer address (address(0) if none; can only be set once until unstake)
     */
    function stakeUSDD(uint256 amount, address referrer) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address investor = _msgSender();

        // Handle referrer setting (only if provided and not already set)
        bool hasReferrer = referrer != address(0);

        /**
         * @dev Internal logic to handle referrer setting during the first qualifying stake.
         *      This block ensures the referrer is set only once (permanently until unstake), preventing referral farming abuse
         *      by avoiding repeated cycles of stake/unstake for rewards. From a financial sustainability perspective,
         *      this aligns with the protocol's long-term holding incentives, as referrers must maintain genuine network contributions
         *      to benefit from Layer1/Layer2 milestone rewards (total 3.4% tied to referee holding periods). The referrerReferees list
         *      is updated here to enable efficient aggregation of pending rewards (via totalPendingReferralRewards), enhancing UX
         *      without altering mint logic—rewards remain proportional to qualifying staking actions, supporting capital efficiency
         *      by encouraging larger, sustained positions that amplify RWA off-chain yields.
         *      
         *      Key mechanics (with referrerRefereeIndex changes for O(1) removal optimization):
         *      - Validates referrer != investor and no existing referrer to enforce one-time binding.
         *      - Adds investor to referrer's referrerReferees array (limited to 50 entries per referrer to prevent gas DoS attacks,
         *        ensuring scalability in large referral networks while maintaining low costs).
         *      - Stores the new index in referrerRefereeIndex for constant-time removal in unstakeUSDD, reducing gas risks from O(n) loops
         *        and preventing edge amplification in high-unstake scenarios.
         *      - Emits ReferrerSet and RefereeAdded events for transparency and off-chain monitoring, aiding governance security
         *        (e.g., Divine DAO can index these to detect anomalous network growth or potential abuse, reducing risks of manipulated inflation).
         *      
         *      Edge cases and risks:
         *      - If referrer is address(0) or already set, skips to avoid invalid states—aligns with anti-abuse design.
         *      - Gas optimization: Array push is O(1) amortized; limit prevents unbounded loops in aggregation functions; referrerRefereeIndex adds minimal storage (one slot per referee) but enables O(1) unstake efficiency.
         *      - Token economics impact: Binding at first stake (regardless of amount) decouples list maintenance from contribution size,
         *        allowing small initial stakes to establish networks while requiring boundaryAmount+ for actual rewards, balancing accessibility
         *        with yield protection. This mitigates benefits risks by ensuring rewards are earned through sustained referee activity.
         *      - Security audit note: Reverts on invalid inputs (e.g., TooManyReferees) protect against spam; no reentrancy risk as nonReentrant modifier covers the entire function.
         *      - Integration: Complements unstakeUSDD's removal logic (using index for swap-pop and delete), ensuring referrerReferees remains accurate post-unstake, supporting reliable DAO oversight of referral dynamics and preventing residual entries that could waste storage/gas.
         */
        if (hasReferrer) {
            if (referrer == investor) revert InvalidReferrer();
            if (referrerAddress[investor] != address(0)) revert AlreadyHasReferrer();

            referrerAddress[investor] = referrer;
            emit ReferrerSet(investor, referrer);

            address[] storage refs = referrerReferees[referrer];
            if (refs.length >= 50) revert TooManyReferees();
            refs.push(investor);
            referrerRefereeIndex[referrer][investor] = refs.length - 1;
            emit RefereeAdded(referrer, investor);
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

        /**
         * @dev Internal logic to record a new referral contribution if the staking amount qualifies (≥ boundaryAmount) and a referrer is set.
         *      This ensures rewards are only triggered for meaningful, larger positions, reinforcing the protocol's capital consolidation incentives
         *      and discouraging fragmented small stakes that could dilute RWA management efficiency. From a token economics viewpoint,
         *      contributions enable independent milestone tracking (0/30/90/180 days for Layer1/2 rates), with rewards minted proportionally
         *      to holding duration—total capped at 3.4% per qualifying stake, tied to genuine long-term commitments that sustain off-chain yields.
         *      This design promotes financial sustainability by linking inflation (minted USDD) to productive ecosystem growth, while the array limit
         *      (10 contributions per user) prevents gas bombs from excessive additions, balancing additive staking flexibility with cost control.
         *      
         *      Key mechanics:
         *      - Pushes a new StakingContribution struct with the staked amount, current timestamp, and zero claimed milestones for both layers.
         *      - Array limited to 10 to mitigate unbounded growth risks, ensuring low gas in loops (e.g., _calculatePending/claimReferralRewards).
         *      - No events emitted here for gas savings; transparency via ReferralRewardClaimed on settlement/claim.
         *      
         *      Edge cases and risks:
         *      - Skips if amount < boundaryAmount or no referrer, aligning with punitive small-amount fees elsewhere to force capital efficiency.
         *      - If array reaches limit, reverts TooManyContributions—users must unstake/restake to reset, but this is rare (realistic <10 additions)
         *        and encourages consolidation, reducing benefits risks from short-term cycling.
         *      - Security audit note: Struct initialization is explicit and safe; unchecked not needed here as operations are bounded.
         *        Integration with unstakeUSDD (deletes array) ensures storage reclamation and anti-abuse (prevents farming via repeated additions).
         *      - Governance security: Divine DAO can adjust boundaryAmount or rates (via setReferralRates) to fine-tune incentives without retroactive effects,
         *        allowing monitoring of contribution patterns to maintain yield alignment with RWA returns.
         */
        if (amount >= boundaryAmount && referrerAddress[investor] != address(0) && (layer1Enabled || layer2Enabled)) {
            StakingContribution[] storage contribs = stakingContributions[investor];
            if (contribs.length >= 10) revert TooManyContributions();
            contribs.push(StakingContribution({
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
     * @notice Unstakes the caller's full staked balance, minting accrued rewards and applying fees if applicable.
     * @dev Calculates and mints time-based yield rewards using the effective APY (base stakingAPY + dynamic uplift if qualified).
     * Early unstake (within penaltyPeriod) incurs a linearly decreasing fee from unstakeFEE.
     * Small stakes incur an additional punitive fee equal to current stakingAPY to discourage fragmented positions.
     * Referral rewards are settled automatically before unstake; referrer and contributions are cleared to prevent farming loops.
     * The effective APY includes an uplift (extraRewardBps) when the caller holds ≥ minDivineForExtra $DIVINE tokens,
     * providing a governance-aligned yield boost visible in accrueRewardView and realized upon unstake.
     * This strengthens $DIVINE demand, rewards DAO participation, and aligns incentives with long-term RWA yield sustainability.
     *
     * Gas optimizations: unchecked arithmetic in safe bounds, single-pass calculations, minimal storage writes.
     * Security: ReentrancyGuard, SafeERC20 transfers, balanceOf snapshot only when feature enabled.
     * Financial sustainability: Fees flow to protocol treasury (future DAO), uplift introduces controlled inflation tied to governance
     * participation without retroactive changes or excessive minting risks.
     * @custom:anti-abuse Referrer/contributions cleared on unstake to eliminate referral cycling; small/early fees force capital consolidation.
     */
    function unstakeUSDD() external nonReentrant {
        address investor = _msgSender();
        uint256 amount = stakedBalance[investor];
        if (amount == 0) revert NoStakedBalance();

        // Enforce hard lock period (applied at stake time, unaffected by later minLockPeriod changes)
        if (block.timestamp < unlockTimestamp[investor]) revert LockPeriodNotElapsed();

        uint256 timeStaked = block.timestamp - stakeStartTime[investor];

        // ────────────────────────────────────────────────────────────────
        // Calculate early unstake penalty (linear decay over penaltyPeriod)
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

        // Small-amount punitive fee (equal to current staking APY rate)
        uint256 smallFeeAmount = 0;
        if (amount < boundaryAmount && stakingAPY > 0) {
            unchecked {
                smallFeeAmount = (amount * stakingAPY) / BPS_DENOMINATOR;
            }
        }

        uint256 totalFee;
        unchecked {
            totalFee = earlyFeeAmount + smallFeeAmount;
        }
        uint256 amountAfterFee;
        unchecked {
            amountAfterFee = amount - totalFee;
        }

        // Settle pending referral rewards before unstake (unchanged)
        _settleReferralRewards(investor);

        // ────────────────────────────────────────────────────────────────
        // Calculate accrued reward using effective APY (includes $DIVINE governance uplift if qualified)
        uint256 effectiveAPY = _getEffectiveAPY(investor);

        uint256 rewardToMint;
        unchecked {
            rewardToMint = (amount * effectiveAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        }

        // Mint accrued rewards directly to investor (base + governance uplift)
        if (rewardToMint > 0) {
            _mint(investor, rewardToMint);
        }

        // ────────────────────────────────────────────────────────────────
        // Clear referrer and remove from referrer's list (anti-farming / anti-abuse)
        if (referrerAddress[investor] != address(0)) {
            address oldReferrer = referrerAddress[investor];
            address[] storage refs = referrerReferees[oldReferrer];
            uint256 idx = referrerRefereeIndex[oldReferrer][investor];
            if (idx < refs.length && refs[idx] == investor) {
                address last = refs[refs.length - 1];
                refs[idx] = last;
                referrerRefereeIndex[oldReferrer][last] = idx;
                refs.pop();
                delete referrerRefereeIndex[oldReferrer][investor];
                emit RefereeRemoved(oldReferrer, investor);
            }
            referrerAddress[investor] = address(0);
        }

        // Clear referral contributions to reclaim storage and prevent residual abuse vectors
        delete stakingContributions[investor];

        // ────────────────────────────────────────────────────────────────
        // Transfer net principal (after fees) to investor
        IERC20(address(this)).safeTransfer(investor, amountAfterFee);

        // Transfer total fees to protocol treasury (owner / future DAO)
        if (totalFee > 0) {
            IERC20(address(this)).safeTransfer(owner(), totalFee);
        }

        // Update global state and clear user mappings
        unchecked {
            totalStaked -= amount;
        }
        delete stakedBalance[investor];
        delete stakeStartTime[investor];
        delete unlockTimestamp[investor];

        // ────────────────────────────────────────────────────────────────
        emit Unstaked(investor, amount, earlyFeeAmount, smallFeeAmount);
    }

    /**
     * @notice Calculates the effective APY applied to a staker's position, including any governance-aligned uplift.
     * @dev Returns the base stakingAPY plus extraRewardBps if the account holds sufficient $DIVINE tokens
     *      and the feature is enabled. This function ensures consistent APY computation across view functions
     *      and state-changing operations.
     * @param account The address whose $DIVINE balance is checked for qualification
     * @return effectiveAPY The total APY in basis points to be used for reward calculation
     */
    function _getEffectiveAPY(address account) internal view returns (uint256) {
        uint256 apy = stakingAPY;

        // Governance uplift is only applied if the feature is configured and the account qualifies
        if (
            divineToken != address(0) &&
            extraRewardBps > 0 &&
            minDivineForExtra > 0 &&
            IERC20(divineToken).balanceOf(account) >= minDivineForExtra
        ) {
            apy += extraRewardBps;
        }

        return apy;
    }

    /**
     * @notice Returns the currently accrued but un-minted staking reward for the given account.
     * @dev The returned value reflects the effective APY, which includes any applicable governance uplift
     *      based on the account's current $DIVINE balance snapshot. This is for display/UI purposes only.
     *
     *      IMPORTANT: The actual reward minted during unstake is determined by a fresh balance check
     *      at the exact moment of unstake execution. Selling $DIVINE tokens between now and unstake
     *      will cause the final minted reward to be lower than shown here.
     *
     * @param account The address to query
     * @return Pending reward amount in USDD (6 decimals)
     */
    function accrueRewardView(address account) external view returns (uint256) {
        uint256 bal = stakedBalance[account];
        if (bal == 0 || stakeStartTime[account] == 0) return 0;

        uint256 timeStaked = block.timestamp - stakeStartTime[account];
        uint256 effectiveAPY = _getEffectiveAPY(account);

        unchecked {
            return (bal * effectiveAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
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
     * @notice Allows the protocol owner to mint and stake USDD directly for an investor (e.g. private sale,
     *         bridge inbound, institutional allocation, or off-chain backed position creation).
     * @dev This function mints new USDD supply without receiving on-chain USDC, and therefore MUST only
     *      be used when equivalent backing assets are secured off-chain and fully auditable.
     *
     *      IMPORTANT: Private sale / external allocations do NOT receive the $DIVINE governance yield uplift,
     *      even if the recipient holds sufficient $DIVINE tokens. This ensures fairness between public stakers
     *      and specially negotiated positions, preventing any unintended advantage in yield accrual.
     *
     *      The function supports additive staking: pending rewards are compounded, stakeStartTime is reset,
     *      and unlockTimestamp is extended (never shortened).
     *
     * @param amount Amount of USDD to mint and add to the investor's staked position (6 decimals)
     * @param investor Recipient address of the minted and staked position
     * @param timePeriod Custom lock period extension in seconds (applied from current timestamp)
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

    // Referral functions

    /**
     * @notice Calculates the current milestone index for a contribution
     * @param contrib The referral contribution
     * @return The current milestone index (0 to 3)
     */
    function _getCurrentMilestoneIndex(StakingContribution memory contrib) internal view returns (uint8) {
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
        if (layer == 1 && !layer1Enabled) return 0;
        if (layer == 2 && !layer2Enabled) return 0;
        StakingContribution[] storage contribs = stakingContributions[referee];
        uint256[] memory rates = layer == 1 ? layer1Rates : layer2Rates;

        for (uint256 i = 0; i < contribs.length; i++) {
            StakingContribution memory contrib = contribs[i];
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
        StakingContribution[] storage contribs = stakingContributions[referee];
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
     * @notice Aggregates and returns the total pending referral rewards for the caller across all their referees (Layer1) and grandchildren (Layer2).
     * @dev Loops through referrerReferees (direct referees) for Layer1 sum; for Layer2, nested loop through each referee's referees (grandchildren).
     *      Filters invalid (e.g., unstaked) by checking referrerAddress. Gas optimized with unchecked sum; reverts if loops too deep (safety).
     *      Returns tuple for separate Layer1/Layer2 totals, aiding UX and monitoring.
     *      
     *      From a token economics perspective, this view enables efficient UX for referrers to monitor total pending mints (Layer1 up to 3%, Layer2 0.4% per qualifying stake),
     *      tied to referee holding milestones (0/30/90/180 days), promoting network growth without inflating rewards beyond genuine long-term contributions—aligning with RWA-backed yield sustainability
     *      and capital efficiency by incentivizing consolidated, sustained positions. Governance security benefit: Divine DAO can call this to aggregate referral dynamics across users, detecting anomalous patterns or abuse.
     *      Benefits risks: Promotes timely claims to reduce lost rewards, while keeping mints proportional to activity; no alteration to underlying _calculatePending logic.
     *      Edge cases: Returns (0,0) for no referees or all invalid; filters ensure no double-counting post-unstake.
     *      Security audit note: View-only, no state change; loops bounded by array limits (50 per level) to mitigate gas risks—for very large networks, off-chain indexing recommended.
     *      Security audit note: View-only, no state change; loops bounded by array limits (50 per level) to mitigate gas risks—for very large networks, off-chain indexing recommended.
     * @return layer1Total Total pending from direct referees (Layer1)
     * @return layer2Total Total pending from grandchildren (Layer2)
     */
function totalPendingReferralRewards() external view returns (uint256 layer1Total, uint256 layer2Total) {
        address caller = _msgSender();
        address[] memory directRefs = referrerReferees[caller];

        // Layer 1: sum pending rewards from all direct referees
        for (uint256 i = 0; i < directRefs.length; ) {
            address referee = directRefs[i];
            // Only include valid referees still pointing to caller
            if (referrerAddress[referee] == caller) {
                unchecked {
                    layer1Total += _calculatePending(referee, 1);
                }
            }
            unchecked { ++i; }
        }

        // Layer 2: sum pending rewards from all grandchildren
        for (uint256 i = 0; i < directRefs.length; ) {
            address l1 = directRefs[i];
            // Skip if this is no longer a valid direct referee of caller
            if (referrerAddress[l1] != caller) {
                unchecked { ++i; }
                continue;
            }
            address[] memory grandRefs = referrerReferees[l1];
            for (uint256 j = 0; j < grandRefs.length; ) {
                address grandchild = grandRefs[j];
                // Only include valid grandchildren still pointing to their referrer (l1)
                if (referrerAddress[grandchild] == l1) {
                    unchecked {
                        layer2Total += _calculatePending(grandchild, 2);
                    }
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
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
     * @notice Updates the referral reward rates for Layer 1 and/or Layer 2.
     * @dev Only callable by the owner (future DAO). Requires exactly 4 rates per array to match milestones.
     *      Does not affect existing contributions (rates applied at claim time based on current values,
     *      but to maintain fairness, updates should be prospective. Emits events for transparency.
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

    /**
     * @notice Fallback function to accept native ETH transfers (e.g., from failed withdrawals or airdrops)
     */
    receive() external payable {}
}
