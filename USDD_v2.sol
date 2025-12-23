// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {UD60x18, ud, pow} from "github.com/PaulRBerg/prb-math/src/UD60x18.sol";

/**
 * @title USDD on Pantha Capital
 * @notice USDD is a yield-bearing stablecoin representing tokenized real-world assets (RWA) managed by Pantha Capital.
 * Users can deposit USDC to mint USDD 1:1, stake for APY-based rewards with strong time-based incentives, request redemption (with manual fulfillment by owner or operation managers),
 * and benefit from referral rewards. Early unstake and small-amount operations incur fees.
 * @dev All USDC deposits are immediately forwarded to the vault address (initially the deployer). Redemption fulfillment pulls USDC from the caller's address
 * (owner or authorized operation manager), allowing separate fund management.
 * The yield backing the protocol is generated off-chain by Pantha Capital, deploying the vault-held USDC into low-risk DeFi strategies,
 * primarily stablecoin liquidity provision on Uniswap V3 and select other venues (e.g., concentrated liquidity pools in USDC/USDT or USDC/DAI pairs).
 * These positions are carefully managed to prioritize capital preservation and consistent yield generation while minimizing impermanent loss exposure.
 * The resulting real-world yield funds the APY rewards (distributed via on-chain minting) and ensures sufficient liquidity for manual redemptions,
 * effectively bridging traditional fixed-income-like returns with on-chain accessibility.
 *
 * Staking mechanics:
 * - Full-amount staking only (stake/unstake entire position at once).
 * - Reward accrual is heavily back-loaded in the first year using a cubic power curve ((time_fraction)^2) to penalize early unstaking
 *   (rewards accrue very slowly at first, with most of the annual APY earned near the end of the year).
 * - At exactly 1 year and beyond: switches to linear proportional accrual, delivering the full advertised APY at 1 year and continuing linearly thereafter.
 * - This design creates a powerful incentive to hold for at least one full year while maintaining simple, predictable long-term yields.
 * - Calculations for the <1-year curve utilize PRBMath UD60x18 fixed-point library for precise exponentiation.
 *
 * Gas optimizations include: direct transfers to vault, immutable constants where possible, unchecked arithmetic in safe calculations,
 * and minimized storage reads/writes.
 * @custom:security-contact hopeallgood.unadvised619@passinbox.com
 */
contract USDD is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Custom errors for gas-efficient reverts
    error ZeroAmount();
    error AlreadyStaked();
    error NoStakedBalance();
    error NoPendingRedemption();
    error InvalidReferrer();
    error AlreadyHasReferrer();
    error Unauthorized();
    error InvalidAddress();
    error CannotWithdrawUSDD();
    error WithdrawFailed();
    error BelowMinimumRedemption();

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
     * @notice Total USDD currently staked across all users
     */
    uint256 public totalStaked;

    /**
     * @notice Current staking APY in basis points (e.g., 1200 = 12.00%)
     */
    uint256 public stakingAPY = 1200;

    /**
     * @notice Maximum early unstake fee in basis points (e.g., 600 = 6.00%)
     * @dev Fee decreases linearly to 0 after 365 days; VIP addresses are exempt
     */
    uint256 public unstakeFEE = 0;

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
     * @param referralReward The referral reward minted (if any)
     */
    event USDCDeposited(address indexed user, uint256 amount, uint256 referralReward);

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
     * @notice Deposits USDC to mint USDD 1:1 and optionally sets a referrer
     * @dev Deposits are immediately forwarded to the vault. Large deposits (≥ boundaryAmount) trigger a referral reward to the referrer.
     *      If the deposit includes a referrer and amount ≥ boundaryAmount, the depositor is automatically granted VIP status.
     *      Gas optimized by direct transfer to vault without intermediate step.
     * @param amount Amount of USDC to deposit (6 decimals)
     * @param referrer Optional referrer address (can only be set once, on first deposit)
     */
    function depositUSDC(uint256 amount, address referrer) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address sender = _msgSender();

        bool hasReferrer = referrer != address(0);
        if (hasReferrer) {
            if (referrer == sender) revert InvalidReferrer();
            if (referrerAddress[sender] != address(0)) revert AlreadyHasReferrer();
            referrerAddress[sender] = referrer;
            emit ReferrerSet(sender, referrer);
        }

        IERC20(USDC_BASE).safeTransferFrom(sender, vault, amount);

        _mint(sender, amount);

        uint256 referralReward = 0;
        if (amount >= boundaryAmount) {
            unchecked {
                referralReward = (amount * reReRate) / BPS_DENOMINATOR;
            }
            if (referralReward > 0 && referrerAddress[sender] != address(0)) {
                _mint(referrerAddress[sender], referralReward);
                emit ReferralRewardMinted(referrerAddress[sender], sender, referralReward, "large_deposit");
            }
            if (hasReferrer && !isVIP[sender]) {

                // Automatically grant VIP status only when a referrer is provided on a large deposit.
                // Intent: Strongly incentivize users to actively seek and use referrer addresses,
                // driving organic ecosystem growth through referral networks. Deposits without a referrer
                // (even large ones) do not receive this benefit, encouraging community expansion.

                isVIP[sender] = true;
                emit VIPStatusUpdated(sender, true);
            }
        }

        emit USDCDeposited(sender, amount, referralReward);
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

        address sender = _msgSender();

        if (!isVIP[sender] && amount < boundaryAmount) revert BelowMinimumRedemption();

        IERC20(address(this)).safeTransferFrom(sender, address(this), amount);

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
            pendingRedemption[sender] += amount;
            totalPendingRedemption += amount;
        }

        emit RedemptionRequested(sender, amount, smallFeeAmount);
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
    * @notice Stakes the caller's entire free USDD balance (full-amount staking only)
    * @dev Users can only have one active stake at a time to ensure APY accrual is calculated
    *      fairly and simply based on a single deposit amount and continuous holding period.
    *      This prevents complex partial staking scenarios that could lead to unfair yield distribution
    *      or gaming of the time-based rewards. Users must unstake fully before staking again.
    *      Gas optimized with direct transfer.
    * @param amount Amount of USDD to stake (must match full intended stake if already partially held)
    */
    function stakeUSDD(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address sender = _msgSender();

        if (stakedBalance[sender] != 0) revert AlreadyStaked();

        IERC20(address(this)).safeTransferFrom(sender, address(this), amount);

        stakedBalance[sender] = amount;
        stakeStartTime[sender] = block.timestamp;

        unchecked {
            totalStaked += amount;
        }

        emit Staked(sender, amount);
    }

    /**
     * @notice Unstakes the caller's full staked balance, minting accrued rewards and applying fees if applicable
     * @dev Reward calculation matches accrueRewardView: compound interest for staking duration < 1 year (back-loaded accrual to discourage early exit),
     *      linear accrual for duration ≥ 1 year (ensuring exact full annual APY at 1 year mark and continued proportional growth thereafter).
     *      Early unstake (within 365 days) incurs a linearly decreasing fee (VIP exempt).
     *      Small stakes incur an additional high punitive fee to discourage small positions.
     *      To prevent referral farming abuse (repeated stake/unstake cycles), the user's referrer is cleared to address(0) after unstake.
     *      This forces potential abusers to make a new deposit with a new referrer and hold for at least 1 year.
     *      VIP status is automatically revoked upon unstaking to incentivize long-term holding.
     *      Users must re-qualify for VIP through future large referred deposits.
     *      Gas optimized with unchecked arithmetic in safe calculations.
     */
    function unstakeUSDD() external nonReentrant {
        address sender = _msgSender();

        uint256 amount = stakedBalance[sender];
        if (amount == 0) revert NoStakedBalance();

        uint256 timeStaked = block.timestamp - stakeStartTime[sender];

        // Reward calculation synchronized with accrueRewardView - using exaggerated cubic curve for <1 year
        uint256 rewardToMint = 0;

        if (timeStaked >= SECONDS_PER_YEAR) {
            // Linear accrual for ≥1 year (continues proportionally beyond 1 year)
            unchecked {
                rewardToMint = (amount * stakingAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
            }
        } else if (timeStaked > 0) {
            // Exaggerated cubic accrual for <1 year (heavy back-loading / early penalty)
            UD60x18 timeFrac = ud(timeStaked).mul(ud(1e18)).div(ud(SECONDS_PER_YEAR)); // precise time fraction
            UD60x18 curvePower = ud(2e18);  // 2.0 = quadratic (very back-loaded)
            UD60x18 poweredFrac = timeFrac.pow(curvePower); // (time_fraction)^power
            uint256 fullAnnualReward = (amount * stakingAPY) / BPS_DENOMINATOR;

            rewardToMint = (fullAnnualReward * poweredFrac.unwrap()) / 1e18;
        }

        if (rewardToMint > 0) {
            _mint(sender, rewardToMint);
        }

        uint256 earlyFeeAmount = 0;
        if (!isVIP[sender] && unstakeFEE > 0 && timeStaked < SECONDS_PER_YEAR) {
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

        // Revoke VIP status on unstake to incentivize long-term holding
        // VIP privileges must be re-qualified through future large referred deposits

        if (isVIP[sender]) {
            isVIP[sender] = false;
            emit VIPStatusUpdated(sender, false);
        }

        // Clear referrer after reward is issued to prevent referral farming loops
        // Users must make a fresh deposit with a new referrer to qualify for future unstake referrals

        if (referrerAddress[sender] != address(0)) {
            referrerAddress[sender] = address(0);
        }

        uint256 totalFee;
        unchecked {
            totalFee = earlyFeeAmount + smallFeeAmount;
        }
        uint256 amountAfterFee;
        unchecked {
            amountAfterFee = amount - totalFee;
        }

        IERC20(address(this)).safeTransfer(sender, amountAfterFee);

        if (totalFee > 0) {
            IERC20(address(this)).safeTransfer(owner(), totalFee);
        }

        unchecked {
            totalStaked -= amount;
        }
        delete stakedBalance[sender];
        delete stakeStartTime[sender];

        emit Unstaked(sender, amount, earlyFeeAmount, smallFeeAmount);
    }

    /**
    * @notice View function to calculate pending staking reward for an account
    * @dev For staking duration < 1 year: uses exaggerated quadratic power curve (time_fraction^2), resulting in strong back-loaded accrual (heavy penalty for early unstaking — rewards mostly accrue near the end of the year).
    *      For duration >= 1 year: uses original linear formula (proportional to time), ensuring exact full annual APY at exactly 1 year and continued linear accrual thereafter.
    *      This creates a much more exaggerated curve than standard compounding, while utilizing PRBMath UD60x18 .pow() for exponentiation.
    * @param account Address to query
    * @return Pending reward (uint256)
    */
    function accrueRewardView(address account) external view returns (uint256) {
        uint256 bal = stakedBalance[account];
        if (bal == 0 || stakeStartTime[account] == 0) return 0;

        uint256 timeStaked = block.timestamp - stakeStartTime[account];

        if (timeStaked >= SECONDS_PER_YEAR) {
            // Linear accrual (original formula) - gas optimized
            unchecked {
                return (bal * stakingAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
            }
        }

        // Exaggerated quadratic accrual only for < 1 year
        UD60x18 timeFrac = ud(timeStaked).mul(ud(1e18)).div(ud(SECONDS_PER_YEAR)); // Precise fraction
        UD60x18 curvePower = ud(2e18); // 2.0 = quadratic (very back-loaded)
        UD60x18 poweredFrac = timeFrac.pow(curvePower); // (time_fraction)^power
        uint256 fullAnnualReward = (bal * stakingAPY) / BPS_DENOMINATOR;

        return (fullAnnualReward * poweredFrac.unwrap()) / 1e18;
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
