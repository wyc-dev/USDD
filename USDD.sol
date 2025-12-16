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
 *         Users can deposit USDC to mint USDD 1:1, stake for fixed APY rewards, request redemption (with manual fulfillment by owner or operation managers),
 *         and benefit from referral rewards. Early unstake and small-amount operations incur fees.
 * @dev All USDC deposits are immediately forwarded to the vault address (initially the deployer). Redemption fulfillment pulls USDC from the caller's address
 *      (owner or authorized operation manager), allowing separate fund management.
 *      Staking is full-amount only with fixed yield accrual based on holding period.
 *      Gas optimizations include: direct transfers to vault, immutable constants where possible, unchecked arithmetic in safe calculations, and minimized storage reads/writes.
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
     * @notice Current staking APY in basis points (e.g., 500 = 5.00%)
     */
    uint256 public stakingAPY;

    /**
     * @notice Maximum early unstake fee in basis points (e.g., 1000 = 10.00%)
     * @dev Fee decreases linearly to 0 after 365 days; VIP addresses are exempt
     */
    uint256 public unstakeFEE;

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
     * @notice Referral reward rate in basis points (fixed at 100 = 1.00%)
     * @dev Marked immutable for gas savings on reads
     */
    uint256 public immutable REFERRAL_RATE_BPS = 100;

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

    /// @dev Events with detailed descriptions

    event StakingAPYUpdated(uint256 indexed newAPY);
    event UnstakeFEEUpdated(uint256 indexed newFEE);
    event BoundaryAmountUpdated(uint256 indexed newAmount);
    event VaultUpdated(address indexed newVault);
    event VIPStatusUpdated(address indexed user, bool status);
    event OperationManagerUpdated(address indexed manager, bool status);
    event ReferrerSet(address indexed user, address indexed referrer);
    event ReferralRewardMinted(address indexed referrer, address indexed referee, uint256 amount, string reason);
    event USDCDeposited(address indexed user, uint256 amount, uint256 referralReward);
    event RedemptionRequested(address indexed user, uint256 amount, uint256 smallFeeAmount, uint256 referralReward);
    event RedemptionFulfilled(address indexed investor, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 earlyFeeAmount, uint256 smallFeeAmount, uint256 rewardMinted, uint256 referralReward);
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
    }

    /**
     * @notice Updates the staking APY and maximum early unstake fee in a single transaction
     * @dev Only callable by the contract owner
     * @param _newAPY New staking APY in basis points (e.g., 500 = 5.00%)
     * @param _newFEE New maximum early unstake fee in basis points (e.g., 1000 = 10.00%)
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
     *      Gas optimized by direct transfer to vault without intermediate step.
     * @param amount Amount of USDC to deposit (6 decimals)
     * @param referrer Optional referrer address (can only be set once, on first deposit)
     */
    function depositUSDC(uint256 amount, address referrer) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address sender = _msgSender();

        if (referrer != address(0)) {
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
                referralReward = (amount * REFERRAL_RATE_BPS) / BPS_DENOMINATOR;
            }
            if (referralReward > 0 && referrerAddress[sender] != address(0)) {
                _mint(referrerAddress[sender], referralReward);
                emit ReferralRewardMinted(referrerAddress[sender], sender, referralReward, "large_deposit");
            }
        }

        emit USDCDeposited(sender, amount, referralReward);
    }

    /**
     * @notice Requests redemption by burning USDD and queuing USDC for manual fulfillment
     * @dev Small amounts (< boundaryAmount) incur a fee paid to the owner. Small redemptions trigger a referral reward.
     *      Gas optimized with unchecked arithmetic where overflow is impossible.
     * @param amount Amount of USDD to redeem (6 decimals)
     */
    function requestRedemption(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address sender = _msgSender();

        IERC20(address(this)).safeTransferFrom(sender, address(this), amount);

        uint256 originalAmount = amount;
        uint256 smallFeeAmount = 0;
        if (amount < boundaryAmount && stakingAPY > 0) {
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

        uint256 referralReward = 0;
        if (originalAmount < boundaryAmount) {
            unchecked {
                referralReward = (originalAmount * REFERRAL_RATE_BPS) / BPS_DENOMINATOR;
            }
            if (referralReward > 0 && referrerAddress[sender] != address(0)) {
                _mint(referrerAddress[sender], referralReward);
                emit ReferralRewardMinted(referrerAddress[sender], sender, referralReward, "small_redemption");
            }
        }

        unchecked {
            pendingRedemption[sender] += amount;
            totalPendingRedemption += amount;
        }

        emit RedemptionRequested(sender, amount, smallFeeAmount, referralReward);
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
     * @dev Users can only have one active stake at a time. Rewards begin accruing from the stake timestamp.
     *      Gas optimized with direct transfer.
     * @param amount Amount of USDD to stake (must match full free balance if already partially held)
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
     * @dev Calculates and mints time-based yield rewards. Early unstake (within 365 days) incurs a linearly decreasing fee (VIP exempt).
     *      Small stakes incur an additional fee. Always mints a referral reward on unstake.
     *      Gas optimized with unchecked arithmetic in calculations where overflow is impossible.
     */
    function unstakeUSDD() external nonReentrant {
        address sender = _msgSender();

        uint256 amount = stakedBalance[sender];
        if (amount == 0) revert NoStakedBalance();

        uint256 timeStaked = block.timestamp - stakeStartTime[sender];

        uint256 rewardToMint;
        unchecked {
            rewardToMint = (amount * stakingAPY * timeStaked) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
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
            unchecked {
                smallFeeAmount = (amount * stakingAPY) / BPS_DENOMINATOR;
            }
        }

        uint256 referralReward;
        unchecked {
            referralReward = (amount * REFERRAL_RATE_BPS) / BPS_DENOMINATOR;
        }
        if (referralReward > 0 && referrerAddress[sender] != address(0)) {
            _mint(referrerAddress[sender], referralReward);
            emit ReferralRewardMinted(referrerAddress[sender], sender, referralReward, "unstake");
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

        emit Unstaked(sender, amount, earlyFeeAmount, smallFeeAmount, rewardToMint, referralReward);
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
