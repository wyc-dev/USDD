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
 *         Users can deposit USDC to mint USDD 1:1, stake for fixed APY rewards, request redemption (with manual fulfillment by owner or operations managers),
 *         and benefit from referral rewards. Early unstake and small-amount operations incur fees.
 * @dev All USDC deposits are immediately forwarded to the vault address (initially the owner), who manages the underlying assets.
 *      Staking is full-amount only with fixed yield accrual based on holding period.
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
    mapping(address => bool) public isVIP;

    /**
     * @notice Operation manager status mapping - authorized addresses can fulfill redemptions
     * @dev Operation managers act on behalf of the owner for redemption fulfillment
     */
    mapping(address => bool) public isOperationManager;

    /**
     * @notice Referrer address for each user, set once during first deposit
     * @dev Used for referral reward distribution
     */
    mapping(address => address) public referrerAddress;

    /**
     * @notice Pending redemption amount per user (after any small-amount fees)
     */
    mapping(address => uint256) public pendingRedemption;

    /**
     * @notice Total USDD currently queued for redemption across all users
     */
    uint256 public totalPendingRedemption;

    /**
     * @notice Staked USDD balance per user (full-amount staking only)
     */
    mapping(address => uint256) public stakedBalance;

    /**
     * @notice Timestamp when the user staked their USDD
     * @dev Used for reward calculation and early unstake fee determination
     */
    mapping(address => uint256) public stakeStartTime;

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
     * @dev Initially set to the contract owner; can be updated by the owner to a separate treasury
     */
    address public vault;

    /**
     * @notice Referral reward rate in basis points (fixed at 100 = 1.00%)
     */
    uint256 private constant REFERRAL_RATE_BPS = 100;

    /**
     * @notice Basis points denominator for percentage calculations
     */
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /**
     * @notice Seconds in a standard year for time-based calculations
     */
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /**
     * @notice USDC contract address on Base chain (fixed for security)
     */
    address public constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Events with detailed descriptions

    /**
     * @notice Emitted when staking APY is updated
     * @param newAPY New APY in basis points
     */
    event StakingAPYUpdated(uint256 newAPY);

    /**
     * @notice Emitted when the early unstake fee is updated
     * @param newFEE New maximum fee in basis points
     */
    event UnstakeFEEUpdated(uint256 newFEE);

    /**
     * @notice Emitted when the boundary amount threshold is updated
     * @param newAmount New threshold in USDD units
     */
    event BoundaryAmountUpdated(uint256 newAmount);

    /**
     * @notice Emitted when vault address is updated
     * @param newVault New vault address
     */
    event VaultUpdated(address indexed newVault);

    /**
     * @notice Emitted when VIP status is set for an address
     * @param user Address whose VIP status changed
     * @param status New VIP status
     */
    event VIPStatusUpdated(address indexed user, bool status);

    /**
     * @notice Emitted when the operation manager status is updated
     * @param manager Address whose status changed
     * @param status New operation manager status
     */
    event OperationManagerUpdated(address indexed manager, bool status);

    /**
     * @notice Emitted when a referrer is set for a user
     * @param user User address
     * @param referrer Referrer address
     */
    event ReferrerSet(address indexed user, address indexed referrer);

    /**
     * @notice Emitted when a referral reward is minted
     * @param referrer Referrer receiving the reward
     * @param referee User who triggered the reward
     * @param amount Reward amount in USDD
     * @param reason Reason for reward ("large_deposit", "unstake", or "small_redemption")
     */
    event ReferralRewardMinted(address indexed referrer, address indexed referee, uint256 amount, string reason);

    /**
     * @notice Emitted on successful USDC deposit and USDD mint
     * @param user Depositor address
     * @param amount Deposited amount
     * @param referralReward Referral reward minted (if any)
     */
    event USDCDeposited(address indexed user, uint256 amount, uint256 referralReward);

    /**
     * @notice Emitted when redemption is requested
     * @param user Requester address
     * @param amount Amount queued for redemption (after small fee)
     * @param smallFeeAmount Small-amount fee deducted (if any)
     * @param referralReward Referral reward minted (if small redemption)
     */
    event RedemptionRequested(address indexed user, uint256 amount, uint256 smallFeeAmount, uint256 referralReward);

    /**
     * @notice Emitted when redemption is fulfilled
     * @param investor Investor receiving USDC
     * @param amount Amount of USDC transferred
     */
    event RedemptionFulfilled(address indexed investor, uint256 amount);

    /**
     * @notice Emitted when USDD is staked
     * @param user Staker address
     * @param amount Staked amount
     */
    event Staked(address indexed user, uint256 amount);

    /**
     * @notice Emitted when USDD is unstaked
     * @param user Unstaker address
     * @param amount Principal amount
     * @param earlyFeeAmount Early unstake fee deducted
     * @param smallFeeAmount Small-amount fee deducted
     * @param rewardMinted Staking reward minted
     * @param referralReward Referral reward minted on unstake
     */
    event Unstaked(address indexed user, uint256 amount, uint256 earlyFeeAmount, uint256 smallFeeAmount, uint256 rewardMinted, uint256 referralReward);

    /**
     * @notice Emitted when stuck assets are withdrawn by the owner
     * @param token Token address (address(0) for ETH)
     * @param amount Withdrawn amount
     */
    event AssetsWithdrawn(address indexed token, uint256 amount);

    /**
     * @dev Modifier restricting access to the owner or authorised operation managers
     */
    modifier onlyAuthorizedRedeemer() {
        if (msg.sender != owner() && !isOperationManager[msg.sender]) revert Unauthorized();
        _;
    }

    /**
     * @notice Contract constructor
     */
    constructor()
        ERC20("USDD", "USDD")
        Ownable(_msgSender())
    {
        vault = _msgSender();
    }

    /**
     * @notice Returns the number of decimals used by USDD (6 to match USDC)
     * @return uint8 Decimal places
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Owner-only function to set staking APY and early unstake fee
     * @param _newAPY New APY in basis points
     * @param _newFEE New maximum early unstake fee in basis points
     */
    function setAPYandFEE(uint256 _newAPY, uint256 _newFEE) external onlyOwner {
        stakingAPY = _newAPY;
        unstakeFEE = _newFEE;
        emit StakingAPYUpdated(_newAPY);
        emit UnstakeFEEUpdated(_newFEE);
    }

    /**
     * @notice Owner-only function to update the boundary threshold amount
     * @param _newAmount New threshold in USDD units (including decimals)
     */
    function setBoundaryAmount(uint256 _newAmount) external onlyOwner {
        boundaryAmount = _newAmount;
        emit BoundaryAmountUpdated(_newAmount);
    }

    /**
     * @notice Owner-only function to update the vault address
     * @dev All future USDC deposits will be forwarded to this address
     * @param _newVault New vault address (cannot be zero address)
     */
    function setVault(address _newVault) external onlyOwner {
        if (_newVault == address(0)) revert InvalidAddress();
        vault = _newVault;
        emit VaultUpdated(_newVault);
    }

    /**
     * @notice Owner-only function to set VIP status for an address
     * @param user Target address
     * @param status VIP status (true = exempt from early unstake fee)
     */
    function setVIP(address user, bool status) external onlyOwner {
        isVIP[user] = status;
        emit VIPStatusUpdated(user, status);
    }

    /**
     * @notice Owner-only function to set the operation manager status for an address
     * @dev Operation managers can fulfill redemptions on behalf of the owner
     * @param manager Target address
     * @param status Operation manager status
     */
    function setOperationManager(address manager, bool status) external onlyOwner {
        isOperationManager[manager] = status;
        emit OperationManagerUpdated(manager, status);
    }

    /**
     * @notice Deposit USDC to mint an equal amount of USDD (1:1)
     * @dev All received USDC is immediately transferred to the vault address. An optional referrer can be set once.
     *      Large deposits (>= boundaryAmount) trigger 1% referral reward.
     * @param amount USDC amount to deposit
     * @param referrer Optional referrer address (cannot be self, set only once)
     */
    function depositUSDC(uint256 amount, address referrer) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Set referrer if provided and valid (only once)
        if (referrer != address(0)) {
            if (referrer == msg.sender) revert InvalidReferrer();
            if (referrerAddress[msg.sender] != address(0)) revert AlreadyHasReferrer();
            referrerAddress[msg.sender] = referrer;
            emit ReferrerSet(msg.sender, referrer);
        }

        IERC20(USDC_BASE).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(USDC_BASE).safeTransfer(vault, amount);

        _mint(msg.sender, amount);

        // Referral reward 1: large deposit >= boundaryAmount
        uint256 referralReward = 0;
        if (amount >= boundaryAmount) {
            referralReward = amount * REFERRAL_RATE_BPS / BPS_DENOMINATOR;
            if (referralReward > 0 && referrerAddress[msg.sender] != address(0)) {
                _mint(referrerAddress[msg.sender], referralReward);
                emit ReferralRewardMinted(referrerAddress[msg.sender], msg.sender, referralReward, "large_deposit");
            }
        }

        emit USDCDeposited(msg.sender, amount, referralReward);
    }

    /**
     * @notice Request redemption of USDD for underlying USDC
     * @dev Escrows USDD in contract. Small amounts (< boundaryAmount) incur a fee based on staking APY.
     *      Small redemptions trigger 1% referral reward.
     * @param amount USDD amount to redeem
     */
    function requestRedemption(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20(address(this)).safeTransferFrom(msg.sender, address(this), amount);

        uint256 originalAmount = amount;
        uint256 smallFeeAmount = 0;
        if (amount < boundaryAmount && stakingAPY > 0) {
            smallFeeAmount = amount * stakingAPY / BPS_DENOMINATOR;
            if (smallFeeAmount > 0) {
                IERC20(address(this)).safeTransfer(owner(), smallFeeAmount);
            }
            amount -= smallFeeAmount;
        }

        // Referral reward 3: small redemption < boundaryAmount (use original amount)
        uint256 referralReward = 0;
        if (originalAmount < boundaryAmount) {
            referralReward = originalAmount * REFERRAL_RATE_BPS / BPS_DENOMINATOR;
            if (referralReward > 0 && referrerAddress[msg.sender] != address(0)) {
                _mint(referrerAddress[msg.sender], referralReward);
                emit ReferralRewardMinted(referrerAddress[msg.sender], msg.sender, referralReward, "small_redemption");
            }
        }

        pendingRedemption[msg.sender] += amount;
        totalPendingRedemption += amount;

        emit RedemptionRequested(msg.sender, amount, smallFeeAmount, referralReward);
    }

    /**
     * @notice Fulfill a pending redemption by transferring USDC from the owner to the investor
     * @dev Restricted to the owner or authorized operation managers. The owner must have approved this contract for USDC.
     *      Burns the escrowed USDD after successful transfer.
     * @param investor Address of the investor to fulfill the redemption for
     */
    function fulfillRedemption(address investor) external onlyAuthorizedRedeemer nonReentrant {
        uint256 amount = pendingRedemption[investor];
        if (amount == 0) revert NoPendingRedemption();

        IERC20(USDC_BASE).safeTransferFrom(owner(), investor, amount);

        _burn(address(this), amount);

        pendingRedemption[investor] = 0;
        totalPendingRedemption -= amount;

        emit RedemptionFulfilled(investor, amount);
    }

    /**
     * @notice Stake an amount of USDD for yield
     * @dev Only allowed if user has no existing stake (full-amount staking only)
     * @param amount USDD amount to stake
     */
    function stakeUSDD(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[msg.sender] != 0) revert AlreadyStaked();

        IERC20(address(this)).safeTransferFrom(msg.sender, address(this), amount);

        stakedBalance[msg.sender] = amount;
        stakeStartTime[msg.sender] = block.timestamp;

        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake the full staked amount, claim rewards, and pay any applicable fees
     * @dev Mints staking reward based on holding period. Applies early unstake fee (VIP exempt) and small-amount fee if applicable.
     *      Triggers 1% referral reward on unstake.
     */
    function unstakeUSDD() external nonReentrant {
        uint256 amount = stakedBalance[msg.sender];
        if (amount == 0) revert NoStakedBalance();

        uint256 timeStaked = block.timestamp - stakeStartTime[msg.sender];

        // 1. Calculate and mint a reward
        uint256 rewardToMint = amount * stakingAPY * timeStaked / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        if (rewardToMint > 0) {
            _mint(msg.sender, rewardToMint);
        }

        // 2. Early unstake fee (VIP exempt)
        uint256 earlyFeeAmount = 0;
        if (!isVIP[msg.sender] && unstakeFEE > 0 && timeStaked < SECONDS_PER_YEAR) {
            uint256 remainingRatio = (SECONDS_PER_YEAR - timeStaked) * BPS_DENOMINATOR / SECONDS_PER_YEAR;
            uint256 feeRate = unstakeFEE * remainingRatio / BPS_DENOMINATOR;
            earlyFeeAmount = amount * feeRate / BPS_DENOMINATOR;
        }

        // 3. Small-amount fee
        uint256 smallFeeAmount = 0;
        if (amount < boundaryAmount && stakingAPY > 0) {
            smallFeeAmount = amount * stakingAPY / BPS_DENOMINATOR;
        }

        // 4. Referral reward 2: on unstake (1% of principal)
        uint256 referralReward = amount * REFERRAL_RATE_BPS / BPS_DENOMINATOR;
        if (referralReward > 0 && referrerAddress[msg.sender] != address(0)) {
            _mint(referrerAddress[msg.sender], referralReward);
            emit ReferralRewardMinted(referrerAddress[msg.sender], msg.sender, referralReward, "unstake");
        }

        uint256 totalFee = earlyFeeAmount + smallFeeAmount;
        uint256 amountAfterFee = amount - totalFee;

        // 5. Transfer principal after fees
        IERC20(address(this)).safeTransfer(msg.sender, amountAfterFee);

        // 6. Transfer fees to the owner
        if (totalFee > 0) {
            IERC20(address(this)).safeTransfer(owner(), totalFee);
        }

        // 7. Clear state
        totalStaked -= amount;
        delete stakedBalance[msg.sender];
        delete stakeStartTime[msg.sender];

        emit Unstaked(msg.sender, amount, earlyFeeAmount, smallFeeAmount, rewardToMint, referralReward);
    }

    /**
     * @notice View function to calculate pending staking reward for an account
     * @param account Address to query
     * @return reward Pending reward in USDD
     */
    function accrueRewardView(address account) public view returns (uint256 reward) {
        uint256 bal = stakedBalance[account];
        if (bal == 0 || stakeStartTime[account] == 0) return 0;

        uint256 timeStaked = block.timestamp - stakeStartTime[account];
        return bal * stakingAPY * timeStaked / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    /**
     * @notice View function to calculate early unstake fee for an account (VIP exempt)
     * @param account Address to query
     * @return feeAmount Early unstake fee in USDD
     */
    function accruePenaltyView(address account) public view returns (uint256 feeAmount) {
        uint256 bal = stakedBalance[account];
        if (bal == 0 || unstakeFEE == 0 || stakeStartTime[account] == 0) return 0;

        if (isVIP[account]) return 0;

        uint256 timeStaked = block.timestamp - stakeStartTime[account];
        if (timeStaked >= SECONDS_PER_YEAR) return 0;

        uint256 remainingRatio = (SECONDS_PER_YEAR - timeStaked) * BPS_DENOMINATOR / SECONDS_PER_YEAR;
        uint256 feeRate = unstakeFEE * remainingRatio / BPS_DENOMINATOR;
        return bal * feeRate / BPS_DENOMINATOR;
    }

    /**
     * @notice Convenience view for pending staking reward
     * @param account Address to query
     * @return Pending reward
     */
    function pendingStakingReward(address account) public view returns (uint256) {
        return accrueRewardView(account);
    }

    /**
     * @notice Convenience view for pending early unstake fee
     * @param account Address to query
     * @return Pending early fee
     */
    function pendingUnstakeFee(address account) public view returns (uint256) {
        return accruePenaltyView(account);
    }

    /**
     * @notice Owner-only function to withdraw stuck ETH or ERC20 tokens (except USDD)
     * @param token Token address (address(0) for ETH)
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
     * @notice Receive ETH (for potential stuck funds)
     */
    receive() external payable {}
}
