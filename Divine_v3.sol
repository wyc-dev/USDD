// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title USDD Interface
 * @notice Interface exposing all owner-only functions of the USDD contract, including redemption fulfillment.
 * @dev This must exactly match the signatures in the deployed USDD contract. The addition of fulfillRedemption enables
 * decentralized governance over manual redemptions, aligning with community-driven protocol maintenance.
 */
interface IUSDD {
    function setAPYandFEE(uint256 _newAPY, uint256 _newFEE) external;
    function setBoundaryAmount(uint256 _newAmount) external;
    function setVault(address _newVault) external;
    function setMinLockPeriod(uint256 newPeriod) external;
    function setOperationManager(address manager, bool status) external;
    function setReferralRates(uint256[] calldata _newLayer1Rates, uint256[] calldata _newLayer2Rates) external;
    function setPenaltyPeriod(uint256 newPeriod) external;
    function externalSale(uint256 amount, address investor, uint256 timePeriod) external;
    function ResetInvestorUnlockTime(address investor, uint256 timePeriod) external;
    function withdrawAssets(address token) external;
    function fulfillRedemption(address investor) external; 
    function revertRedemption(address investor) external; 
    function pendingRedemption(address investor) external view returns (uint256); 
    function setReferralLayersEnabled(bool _layer1Enabled, bool _layer2Enabled) external; 
    function setDivineExtraRewardParams(address _divineToken, uint256 _extraRewardBps, uint256 _minDivineForExtra) external;
}

/**
 * @title Lhasa DAO ($DIVINE v3) Governance Contract
 * @notice Lhasa DAO is the decentralized governance layer for the USDD yield-bearing stablecoin protocol.
 * It empowers holders of the $DIVINE governance token (collectively known as the Pantheon)
 * to collectively manage all administrative functions previously controlled by a single owner,
 * including decentralized fulfillment of redemptions with token minting incentives.
 *
 * The model is deliberately simple and secure: only one proposal may be active at a time,
 * with a configurable voting period (initially 7 days). Proposals pass if yes votes meet both
 * a percentage of votes cast and a minimum absolute threshold. To prevent vote manipulation,
 * $DIVINE token transfers are fully locked while a proposal is active.
 *
 * Supported actions include adjusting staking APY and fees, updating the vault address,
 * managing operation manager statuses, setting lock and penalty periods, updating referral rates,
 * executing external sales, resetting investor unlock timestamps, withdrawing assets, modifying
 * quorum parameters, changing the proposal duration, setting redemption rewards, reverting pending
 * redemptions, and updating the USDD contract address for upgrade possibilities.
 * @dev After deployment, the ownership of the deployed USDD contract must be transferred to this
 * DAO address to complete the transition from centralized to community-led governance.
 * The redemption fulfillment reward introduces controlled inflation tied to protocol activity,
 * promoting long-term alignment and capital efficiency. v3 adds proposal description hashes,
 * execution timelocks, and hybrid quorum for enhanced transparency and security.
 * @custom:security-contact hopeallgood.unadvised619@passinbox.com
 */
contract Divine is ERC20, ReentrancyGuard {

    error MustHoldDivineTokens();               // Caller holds zero $DIVINE
    error OngoingProposal();                    // Another proposal is active
    error NoOngoingProposal();                  // No active proposal to vote/finalize
    error ProposalNotEnded();                   // Voting period has not yet concluded
    error ProposalExpired();                    // Voting window has closed
    error AlreadyVoted();                       // Voter has already cast vote on this proposal
    error TotalSupplyZero();                    // Cannot calculate quorum with zero supply
    error TransfersLocked();                    // $DIVINE transfers blocked during active proposal
    error InvalidParameter();                   // Generic invalid input (zero address, etc.)
    error InvalidExtraRewardBps();              // Proposed extraRewardBps exceeds safe/reasonable cap
    error InvalidRedemptionRewardValue();       // Proposed rewardPerUSDC is invalid (zero when disallowed, or exceeds cap)
    error NoPendingRedemption();                // No queued redemption for specified investor
    error ProposalNotReady();                   // Timelock delay has not elapsed
    error NoExecutableProposal();               // No passed proposal ready for execution

    /**
     * @notice Address of the USDD contract being governed (updatable via governance for upgrades).
     */
    address public USDD_ADDRESS;
    /**
     * @notice Instance of the IUSDD interface pointing to the current USDD contract.
     */
    IUSDD public usdd;
    /**
     * @notice Duration of the voting period for proposals in seconds (initially 7 days, adjustable via governance).
     */
    uint256 public proposalDuration = 7 days;
    /**
     * @notice Percentage of votes cast required for a proposal to pass (initially 45%, adjustable via governance).
     * @dev Used in hybrid quorum: yesVotes >= (votesCast * participationQuorumBps / 10_000)
     */
    uint256 public participationQuorumBps = 4500; // 45% of votes cast
    /**
     * @notice Minimum absolute yes votes required for quorum (initially 3B $DIVINE, adjustable via governance).
     * @dev Prevents low-participation passes; complements participationQuorumBps for robust governance.
     */
    uint256 public minQuorumAbsolute = 3_000_000_000 * 10**18; // 3B $DIVINE
    /**
     * @notice Amount of $DIVINE (in 18-decimal wei) minted to the fulfiller per 1 full USDC (6-decimal unit) redeemed.
     * @dev Adjustable via governance proposal. Represents the incentive for decentralized redemption fulfillment.
     *      Initial value: 0.1 $DIVINE per 1 USDC (lowered from v2 for controlled inflation).
     *      Upper bound enforced: maximum 2 $DIVINE per 1 USDC to prevent excessive inflation.
     *      Setting to 0 disables the reward while still allowing fulfillment.
     */
    uint256 public rewardPerUSDC = 100_000_000_000_000_000; // 0.1 × 10^18
    /**
     * @notice Maximum allowed value for rewardPerUSDC (2 $DIVINE per 1 USDC).
     * @dev Hard cap to protect long-term $DIVINE token economics and prevent governance capture attacks via extreme inflation.
     */
    uint256 public constant MAX_REWARD_PER_USDC = 2_000_000_000_000_000_000; // 2 × 10^18
    /**
     * @notice Delay before a passed proposal can be executed (initially 2 days).
     * @dev Mitigates risks from malicious or erroneous proposals by allowing reaction time.
     */
    uint256 public constant EXECUTION_DELAY = 2 days;

    /**
     * @notice Enum defining the types of governance proposals supported by the DAO.
     * @dev Each type corresponds to a specific administrative action on the USDD contract or DAO parameters.
     *      v3 adds SetParticipationQuorumBps and SetMinQuorumAbsolute for quorum tuning.
     */
    enum ProposalType {
        None,
        SetStakingParams,
        SetBoundaryAmount,
        SetVault,
        SetMinLockPeriod,
        SetOperationManager,
        SetReferralRates,
        SetPenaltyPeriod,
        ExternalSale,
        ResetInvestorUnlockTime,
        WithdrawAssets,
        ChangeProposalDuration,
        SetRedemptionRewardPerUSDC,
        RevertRedemption,
        SetUSDDAddress,
        SetReferralLayersEnabled,
        SetDivineExtraRewardParams,
        SetParticipationQuorumBps,
        SetMinQuorumAbsolute
    }

    // Current active proposal state
    /**
     * @notice Flag indicating if a proposal is currently active.
     */
    bool public activeProposal;
    /**
     * @notice Unique identifier for the current proposal (incremented per proposal).
     */
    uint256 public currentProposalId;
    /**
     * @notice Type of the current active proposal.
     */
    ProposalType public currentProposalType;
    /**
     * @notice ABI-encoded data for the current proposal's parameters.
     */
    bytes public currentProposalData;
    /**
     * @notice Timestamp when the current proposal started.
     */
    uint256 public currentProposalStart;
    /**
     * @notice Cumulative yes votes for the current proposal.
     */
    uint256 public currentYesVotes;
    /**
     * @notice Hash of the current proposal's description (keccak256 of UTF-8 string or IPFS CIDv0).
     */
    bytes32 public currentProposalDescriptionHash;
    /**
     * @notice Timestamp when the current passed proposal becomes executable (0 if not ready).
     */
    uint256 public executionReadyTimestamp;

    // Historical data (for transparency/off-chain indexing)
    /**
     * @notice Mapping of proposal IDs to their types (historical record).
     */
    mapping(uint256 => ProposalType) public proposalType;
    /**
     * @notice Mapping of proposal IDs to their ABI-encoded data (historical record).
     */
    mapping(uint256 => bytes) public proposalData;
    /**
     * @notice Mapping of proposal IDs to their final yes vote counts (historical record).
     */
    mapping(uint256 => uint256) public proposalYesVotes;
    /**
     * @notice Mapping of proposal IDs to their execution status (historical record).
     */
    mapping(uint256 => bool) public proposalExecuted;
    /**
     * @notice Mapping of proposal IDs to their start timestamps (historical record).
     */
    mapping(uint256 => uint256) public proposalStartTime;
    /**
     * @notice Mapping of proposal IDs to their description hashes (historical record).
     */
    mapping(uint256 => bytes32) public proposalDescriptionHashes;

    // Voting tracking
    /**
     * @notice Nested mapping tracking if an address has voted on a specific proposal.
     */
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /**
     * @notice Emitted when a new governance proposal is initiated.
     * @param proposalType Human-readable string of the proposal type.
     * @param id Unique identifier of the proposal.
     * @param initiator Address that initiated the proposal.
     * @param descriptionHash keccak256 hash of the proposal description for off-chain lookup.
     */
    event ProposalInitiated(string proposalType, uint256 indexed id, address indexed initiator, bytes32 descriptionHash);
    /**
     * @notice Emitted when a vote is cast on a proposal.
     * @param proposalType Human-readable string of the proposal type.
     * @param id Unique identifier of the proposal.
     * @param voter Address that cast the vote.
     * @param power Voting power (balance) of the voter.
     */
    event Voted(string proposalType, uint256 indexed id, address indexed voter, uint256 power);
    /**
     * @notice Emitted when a passed proposal is queued for execution after timelock.
     * @param proposalType Human-readable string of the proposal type.
     * @param id Unique identifier of the proposal.
     * @param executionTimestamp Timestamp when the proposal becomes executable.
     */
    event ProposalQueued(string proposalType, uint256 indexed id, uint256 executionTimestamp);
    /**
     * @notice Emitted when a proposal is successfully executed.
     * @param proposalType Human-readable string of the proposal type.
     * @param id Unique identifier of the proposal.
     */
    event ProposalExecuted(string proposalType, uint256 indexed id);
    /**
     * @notice Emitted when a proposal ends (passed or failed).
     * @param proposalType Human-readable string of the proposal type.
     * @param id Unique identifier of the proposal.
     * @param passed True if the proposal passed quorum, false otherwise.
     */
    event ProposalEnded(string proposalType, uint256 indexed id, bool passed);
    /**
     * @notice Emitted when a redemption is fulfilled with a governance reward.
     * @param fulfiller Address that finalized the fulfillment (receiving the reward).
     * @param investor Address of the investor whose redemption was fulfilled.
     * @param amount USDC amount redeemed.
     * @param rewardMinted DIVINE reward minted to the fulfiller.
     */
    event RedemptionFulfilledWithReward(address indexed fulfiller, address indexed investor, uint256 amount, uint256 rewardMinted);
    /**
     * @notice Emitted when the redemption fulfillment reward rate is updated via governance.
     * @dev Provides full transparency and enables off-chain indexing of changes to the activity-linked inflation mechanism.
     * @param newRewardPerUSDC New reward amount in 18-decimal precision (DIVINE wei per 1 full USDC)
     */
    event RedemptionRewardPerUSDCUpdated(uint256 indexed newRewardPerUSDC);
    /**
     * @notice Emitted when the USDD contract address is updated via governance.
     * @param newAddress The new USDD contract address.
     */
    event USDDAddressUpdated(address indexed newAddress);
    /**
     * @notice Emitted when a governance proposal to configure (or disable) the $DIVINE-linked extra staking yield
     * mechanism is successfully executed via the Divine DAO.
     * @dev This event mirrors the `DivineExtraRewardParamsUpdated` event emitted by the USDD contract, enabling
     * seamless off-chain indexing, transparency, and cross-contract traceability of governance decisions that directly
     * impact token utility and yield distribution.
     *
     * The parameters set here control a dynamic APY uplift for qualified $DIVINE holders, creating a powerful incentive
     * loop:
     *   - Increased $DIVINE demand → stronger governance participation
     *   - Higher effective staking yields → improved capital efficiency and long-term USDD holder alignment
     *   - Controlled, activity-tied inflation balanced against real RWA-backed returns
     *
     * Emitted exclusively upon successful execution of a SetDivineExtraRewardParams proposal.
     * Setting divineToken = address(0) disables the feature entirely (emergency governance kill-switch).
     *
     * @custom:impact Directly increases $DIVINE token velocity and holding incentive; recommended initial tuning:
     *                extraRewardBps = 50–300 bps (0.5%–3%), minDivineForExtra ≈ 5,000–50,000 DIVINE depending on
     *                circulating supply and target governance participation rate.
     *
     * @param divineToken The ERC20 address of the $DIVINE governance token (address(0) disables the uplift)
     * @param extraRewardBps Additional APY applied to qualified stakers, in basis points (e.g., 200 = 2.00% extra yield)
     * @param minDivineForExtra Minimum $DIVINE balance required to qualify for the uplift (18 decimals precision)
     */
    event DivineExtraRewardParamsProposedAndExecuted(address indexed divineToken, uint256 extraRewardBps, uint256 minDivineForExtra);

    /**
     * @notice Deploys the Divine governance token and mints the full initial supply to the deployer.
     * @dev The deployer receives 10 billion $DIVINE tokens, representing full initial governance rights.
     * Post-deployment, ownership of the USDD contract should be transferred to this DAO address
     * to enable decentralized administration of the yield-bearing stablecoin protocol.
     * Initializes USDD_ADDRESS to a hardcoded value and sets the usdd interface instance.
     */
    constructor() ERC20("Divine", "DIVINE") {
        _mint(_msgSender(), 10_000_000_000 * 10 ** decimals()); // 10B DIVINE to deployer
        USDD_ADDRESS = 0x5b95BaD2844CA1EA17867f8188003e3894C296AE;
        usdd = IUSDD(USDD_ADDRESS);
    }

    /* ===================== VIEW HELPERS ===================== */
    /**
     * @notice Converts a ProposalType enum value to its human-readable string representation.
     * @dev Used primarily for event emission and off-chain indexing to enhance transparency.
     * @param pType The proposal type to convert.
     * @return string memory The descriptive string corresponding to the proposal type.
     */
    function proposalTypeToString(ProposalType pType) public pure returns (string memory) {
        if (pType == ProposalType.SetStakingParams) return "Set Staking Parameters";
        if (pType == ProposalType.SetBoundaryAmount) return "Update Boundary Amount";
        if (pType == ProposalType.SetVault) return "Update Vault Address";
        if (pType == ProposalType.SetMinLockPeriod) return "Update Min Lock Period";
        if (pType == ProposalType.SetOperationManager) return "Set Operation Manager";
        if (pType == ProposalType.SetReferralRates) return "Set Referral Rates";
        if (pType == ProposalType.SetPenaltyPeriod) return "Set Penalty Period";
        if (pType == ProposalType.ExternalSale) return "External Sale";
        if (pType == ProposalType.ResetInvestorUnlockTime) return "Reset Investor Unlock Time";
        if (pType == ProposalType.WithdrawAssets) return "Withdraw Assets";
        if (pType == ProposalType.ChangeProposalDuration) return "Change Proposal Duration";
        if (pType == ProposalType.SetRedemptionRewardPerUSDC) return "Set Redemption Reward Per USDC";
        if (pType == ProposalType.RevertRedemption) return "Revert Redemption";
        if (pType == ProposalType.SetUSDDAddress) return "Set USDD Address";
        if (pType == ProposalType.SetReferralLayersEnabled) return "Set Referral Layers Enabled";
        if (pType == ProposalType.SetDivineExtraRewardParams) return "Set Divine Extra Reward Parameters";
        if (pType == ProposalType.SetParticipationQuorumBps) return "Set Participation Quorum Bps";
        if (pType == ProposalType.SetMinQuorumAbsolute) return "Set Min Quorum Absolute";
        return "None";
    }

    /**
     * @notice Returns whether a governance proposal is currently active and within its voting window.
     * @dev Considers both the activeProposal flag and the time elapsed since proposal start.
     * Critical for transfer lock enforcement and voting eligibility checks.
     * @return bool True if a proposal is active and the voting period has not expired.
     */
    function isProposalActive() public view returns (bool) {
        return activeProposal && block.timestamp < currentProposalStart + proposalDuration;
    }

    /* ===================== INTERNAL PROPOSAL LOGIC ===================== */

    /**
     * @dev Internal helper to initiate a new proposal. Enforces that the caller holds $DIVINE tokens
     * and that no proposal is currently active. Records proposal metadata and emits an event.
     * @param pType The type of proposal.
     * @param data ABI-encoded proposal parameters.
     * @param descriptionHash keccak256 hash of the proposal description for off-chain lookup.
     */
    function _initiateProposal(ProposalType pType, bytes memory data, bytes32 descriptionHash) private {
        if (balanceOf(_msgSender()) == 0) revert MustHoldDivineTokens();
        if (activeProposal) revert OngoingProposal();
        currentProposalId++;
        currentProposalType = pType;
        currentProposalData = data;
        currentProposalDescriptionHash = descriptionHash;
        currentProposalStart = block.timestamp;
        currentYesVotes = 0;
        activeProposal = true;
        emit ProposalInitiated(proposalTypeToString(pType), currentProposalId, _msgSender(), descriptionHash);
    }

    /**
     * @dev Internal helper to execute a passed proposal. Decodes the stored data and performs
     * the corresponding administrative action on the USDD contract or updates local governance parameters.
     * For FulfillRedemption, calls USDD's fulfillRedemption and mints rewardPerUSDC as incentive,
     * promoting decentralized liquidity provision while introducing activity-tied inflation for long-term alignment.
     */
    function _executeCurrentProposal() private {
        ProposalType pType = currentProposalType;
        if (pType == ProposalType.SetStakingParams) {
            (uint256 apy, uint256 fee) = abi.decode(currentProposalData, (uint256, uint256));
            usdd.setAPYandFEE(apy, fee);
        } else if (pType == ProposalType.SetBoundaryAmount) {
            uint256 amt = abi.decode(currentProposalData, (uint256));
            usdd.setBoundaryAmount(amt);
        } else if (pType == ProposalType.SetVault) {
            address v = abi.decode(currentProposalData, (address));
            usdd.setVault(v);
        } else if (pType == ProposalType.SetMinLockPeriod) {
            uint256 p = abi.decode(currentProposalData, (uint256));
            usdd.setMinLockPeriod(p);
        } else if (pType == ProposalType.SetOperationManager) {
            (address m, bool s) = abi.decode(currentProposalData, (address, bool));
            usdd.setOperationManager(m, s);
        } else if (pType == ProposalType.SetReferralRates) {
            (uint256[] memory l1, uint256[] memory l2) = abi.decode(currentProposalData, (uint256[], uint256[]));
            usdd.setReferralRates(l1, l2);
        } else if (pType == ProposalType.SetPenaltyPeriod) {
            uint256 p = abi.decode(currentProposalData, (uint256));
            usdd.setPenaltyPeriod(p);
        } else if (pType == ProposalType.ExternalSale) {
            (uint256 amt, address inv, uint256 tp) = abi.decode(currentProposalData, (uint256, address, uint256));
            usdd.externalSale(amt, inv, tp);
        } else if (pType == ProposalType.ResetInvestorUnlockTime) {
            (address inv, uint256 tp) = abi.decode(currentProposalData, (address, uint256));
            usdd.ResetInvestorUnlockTime(inv, tp);
        } else if (pType == ProposalType.WithdrawAssets) {
            address t = abi.decode(currentProposalData, (address));
            usdd.withdrawAssets(t);
        } else if (pType == ProposalType.ChangeProposalDuration) {
            uint256 newDur = abi.decode(currentProposalData, (uint256));
            proposalDuration = newDur;
        } else if (pType == ProposalType.SetRedemptionRewardPerUSDC) {
            uint256 newValue = abi.decode(currentProposalData, (uint256));
            if (newValue > MAX_REWARD_PER_USDC) revert InvalidRedemptionRewardValue();
            rewardPerUSDC = newValue;
            emit RedemptionRewardPerUSDCUpdated(newValue);
        } else if (pType == ProposalType.RevertRedemption) {
            address investor = abi.decode(currentProposalData, (address));
            usdd.revertRedemption(investor);
        } else if (pType == ProposalType.SetUSDDAddress) {
            address newUSDD = abi.decode(currentProposalData, (address));
            USDD_ADDRESS = newUSDD;
            usdd = IUSDD(newUSDD);
            emit USDDAddressUpdated(newUSDD);
        } else if (pType == ProposalType.SetReferralLayersEnabled) {
            (bool l1Enabled, bool l2Enabled) = abi.decode(currentProposalData, (bool, bool));
            usdd.setReferralLayersEnabled(l1Enabled, l2Enabled);
        } else if (pType == ProposalType.SetDivineExtraRewardParams) {
            (address divineToken, uint256 extraBps, uint256 minHold) =
                abi.decode(currentProposalData, (address, uint256, uint256));
            if (extraBps > 1000) revert InvalidExtraRewardBps();
            usdd.setDivineExtraRewardParams(divineToken, extraBps, minHold);
            emit DivineExtraRewardParamsProposedAndExecuted(divineToken, extraBps, minHold);
        } else if (pType == ProposalType.SetParticipationQuorumBps) {
            uint256 newBps = abi.decode(currentProposalData, (uint256));
            participationQuorumBps = newBps;
        } else if (pType == ProposalType.SetMinQuorumAbsolute) {
            uint256 newAbs = abi.decode(currentProposalData, (uint256));
            minQuorumAbsolute = newAbs;
        }
    }

    /* ===================== PROPOSAL INITIATION ===================== */

    /**
     * @notice Initiates a governance proposal to update staking yield (APY) and unstaking fee parameters in the USDD protocol.
     * @dev Restricted to $DIVINE holders; only one proposal may be active at a time. Protected against reentrancy.
     * Successful passage enables community-driven adjustment of yield economics and fee structures,
     * balancing investor returns with protocol sustainability.
     * @param newAPY Proposed new Annual Percentage Yield for staking rewards.
     * @param newUnstakeFEE Proposed new fee applied on unstaking operations.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetStakingParams(uint256 newAPY, uint256 newUnstakeFEE, bytes32 descriptionHash) external nonReentrant {
        _initiateProposal(ProposalType.SetStakingParams, abi.encode(newAPY, newUnstakeFEE), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to modify the boundary amount parameter in the USDD protocol.
     * @dev Restricted to $DIVINE holders; enforces single-proposal-at-a-time rule. Reentrancy protected.
     * This parameter typically governs risk thresholds or operational limits in the yield mechanism.
     * @param newAmount Proposed new boundary amount value.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetBoundaryAmount(uint256 newAmount, bytes32 descriptionHash) external nonReentrant {
        _initiateProposal(ProposalType.SetBoundaryAmount, abi.encode(newAmount), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to update the treasury vault address in the USDD protocol.
     * @dev Restricted to $DIVINE holders; zero address prohibited to prevent irreversible fund lockup.
     * Critical for secure asset management and protocol treasury operations.
     * @param newVault Proposed new vault contract address.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetVault(address newVault, bytes32 descriptionHash) external nonReentrant {
        if (newVault == address(0)) revert InvalidParameter();
        _initiateProposal(ProposalType.SetVault, abi.encode(newVault), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to adjust the minimum lock period for staked assets in the USDD protocol.
     * @dev Restricted to $DIVINE holders. Affects liquidity risk and yield commitment requirements.
     * @param newPeriod Proposed new minimum lock period in seconds.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetMinLockPeriod(uint256 newPeriod, bytes32 descriptionHash) external nonReentrant {
        _initiateProposal(ProposalType.SetMinLockPeriod, abi.encode(newPeriod), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to appoint or remove an operation manager in the USDD protocol.
     * @dev Restricted to $DIVINE holders; zero address prohibited. Operation managers may have limited administrative privileges.
     * @param manager Address of the operation manager.
     * @param status Proposed status (true = appointed, false = removed).
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetOperationManager(address manager, bool status, bytes32 descriptionHash) external nonReentrant {
        if (manager == address(0)) revert InvalidParameter();
        _initiateProposal(ProposalType.SetOperationManager, abi.encode(manager, status), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to update the referral reward rates for Layer 1 and/or Layer 2 in the USDD protocol.
     * @dev Restricted to $DIVINE holders; arrays must be length 4 or empty. Allows fine-tuning of multi-level referral incentives.
     * @param newLayer1Rates Proposed new rates for Layer 1 (empty skips update).
     * @param newLayer2Rates Proposed new rates for Layer 2 (empty skips update).
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetReferralRates(uint256[] calldata newLayer1Rates, uint256[] calldata newLayer2Rates, bytes32 descriptionHash) external nonReentrant {
        _initiateProposal(ProposalType.SetReferralRates, abi.encode(newLayer1Rates, newLayer2Rates), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to update the penalty period for early unstake fees in the USDD protocol.
     * @dev Restricted to $DIVINE holders. Affects the timeframe for fee decay, strengthening long-term holding incentives.
     * @param newPeriod Proposed new penalty period in seconds.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetPenaltyPeriod(uint256 newPeriod, bytes32 descriptionHash) external nonReentrant {
        _initiateProposal(ProposalType.SetPenaltyPeriod, abi.encode(newPeriod), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal for an external sale of USDD tokens to a specified investor.
     * @dev Restricted to $DIVINE holders; zero amount or address prohibited. Enables controlled token distribution outside standard staking.
     * @param amount Number of USDD tokens to be sold.
     * @param investor Recipient address for the external sale.
     * @param timePeriod Associated lock-up or vesting period for the sale.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeExternalSale(uint256 amount, address investor, uint256 timePeriod, bytes32 descriptionHash) external nonReentrant {
        if (amount == 0 || investor == address(0)) revert InvalidParameter();
        _initiateProposal(ProposalType.ExternalSale, abi.encode(amount, investor, timePeriod), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to reset the unlock timestamp for a specific investor's locked assets.
     * @dev Restricted to $DIVINE holders; zero address prohibited. Used for exceptional liquidity management.
     * @param investor Address of the investor whose unlock time is to be reset.
     * @param timePeriod New unlock timestamp or period extension.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeResetInvestorUnlockTime(address investor, uint256 timePeriod, bytes32 descriptionHash) external nonReentrant {
        if (investor == address(0)) revert InvalidParameter();
        _initiateProposal(ProposalType.ResetInvestorUnlockTime, abi.encode(investor, timePeriod), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to withdraw assets of a specified token type from the USDD contract.
     * @dev Restricted to $DIVINE holders. High-risk operation requiring supermajority consensus to protect protocol treasury.
     * @param token Address of the ERC20 token to be withdrawn.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeWithdrawAssets(address token, bytes32 descriptionHash) external nonReentrant {
        _initiateProposal(ProposalType.WithdrawAssets, abi.encode(token), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to change the duration of the voting period for future proposals.
     * @dev Restricted to $DIVINE holders; zero duration prohibited to prevent governance deadlock.
     * Enables the community to balance deliberation time with decision-making agility.
     * @param newDuration Proposed new proposal voting duration in seconds.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeChangeProposalDuration(uint256 newDuration, bytes32 descriptionHash) external nonReentrant {
        if (newDuration == 0) revert InvalidParameter();
        _initiateProposal(ProposalType.ChangeProposalDuration, abi.encode(newDuration), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to update the $DIVINE reward amount
     * minted to the entity that fulfills a pending redemption (per 1 full USDC redeemed).
     * @dev Restricted to $DIVINE holders. The new value must be ≤ MAX_REWARD_PER_USDC.
     *      Setting to 0 disables the reward incentive while preserving fulfillment capability.
     * @param newRewardPerUSDC Proposed new reward in 18-decimal precision (DIVINE wei per 1 USDC)
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetRedemptionRewardPerUSDC(uint256 newRewardPerUSDC, bytes32 descriptionHash) external nonReentrant {
        if (newRewardPerUSDC > MAX_REWARD_PER_USDC) revert InvalidRedemptionRewardValue();
        _initiateProposal(ProposalType.SetRedemptionRewardPerUSDC, abi.encode(newRewardPerUSDC), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to revert/cancel a pending redemption for a specified investor in the USDD protocol.
     * @dev Restricted to $DIVINE holders; zero address prohibited. Useful for correcting errors or handling special cases.
     * @param investor Address of the investor whose pending redemption is to be reverted.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeRevertRedemption(address investor, bytes32 descriptionHash) external nonReentrant {
        if (investor == address(0)) revert InvalidParameter();
        _initiateProposal(ProposalType.RevertRedemption, abi.encode(investor), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to update the USDD contract address (e.g., for protocol upgrades).
     * @dev Restricted to $DIVINE holders; zero address prohibited. This high-risk action enables seamless upgrades
     * while maintaining governance security through community consensus, ensuring long-term protocol adaptability
     * and capital efficiency without compromising anti-abuse mechanisms.
     * @param newUSDD Proposed new USDD contract address.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetUSDDAddress(address newUSDD, bytes32 descriptionHash) external nonReentrant {
        if (newUSDD == address(0)) revert InvalidParameter();
        _initiateProposal(ProposalType.SetUSDDAddress, abi.encode(newUSDD), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to enable or disable referral layers in the USDD protocol.
     * @dev Restricted to $DIVINE holders. Allows toggling Layer 1 and Layer 2 independently to control referral incentives.
     * Disabling prevents new contributions but allows claiming existing rewards.
     * @param layer1Enabled New enabled status for Layer 1.
     * @param layer2Enabled New enabled status for Layer 2.
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetReferralLayersEnabled(bool layer1Enabled, bool layer2Enabled, bytes32 descriptionHash) external nonReentrant {
        _initiateProposal(ProposalType.SetReferralLayersEnabled, abi.encode(layer1Enabled, layer2Enabled), descriptionHash);
    }

    /**
     * @notice Proposes to configure (or disable) the $DIVINE governance token-linked extra staking yield
     * mechanism introduced in USDD v4.
     * @dev Allows the community to:
     *   - Activate the feature by setting a valid divineToken address
     *   - Tune the additional APY boost (extraRewardBps)
     *   - Set the minimum $DIVINE holding threshold required to qualify
     * Setting divineToken = address(0) effectively disables the uplift.
     *
     * This parameter directly influences $DIVINE token utility and demand, creating a positive feedback
     * loop between governance participation and enhanced stablecoin yields — a key mechanism for
     * long-term alignment in the Pantha Capital RWA ecosystem.
     *
     * @param divineToken Address of the $DIVINE ERC20 token (address(0) to disable)
     * @param extraRewardBps Additional APY in basis points (recommended range: 50–300 bps)
     * @param minDivineForExtra Minimum $DIVINE balance required (18 decimals)
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetDivineExtraRewardParams(
        address divineToken,
        uint256 extraRewardBps,
        uint256 minDivineForExtra,
        bytes32 descriptionHash
    ) external nonReentrant {
        if (divineToken == address(0) && extraRewardBps == 0) revert InvalidParameter();
        _initiateProposal(ProposalType.SetDivineExtraRewardParams, abi.encode(divineToken, extraRewardBps, minDivineForExtra), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to update the participation quorum percentage (of votes cast).
     * @dev Restricted to $DIVINE holders. Value must be between 1000 and 10000 bps. Allows adaptive quorum adjustment.
     * @param newBps Proposed new participation quorum in basis points (1000-10000).
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetParticipationQuorumBps(uint256 newBps, bytes32 descriptionHash) external nonReentrant {
        if (newBps < 1000 || newBps > 10000) revert InvalidParameter();
        _initiateProposal(ProposalType.SetParticipationQuorumBps, abi.encode(newBps), descriptionHash);
    }

    /**
     * @notice Initiates a governance proposal to update the minimum absolute quorum threshold.
     * @dev Restricted to $DIVINE holders. Value must be >0. Allows adaptive quorum adjustment.
     * @param newAbsolute Proposed new minimum absolute yes votes (in DIVINE wei).
     * @param descriptionHash keccak256 hash of the proposal description (e.g. IPFS CIDv0 or UTF-8 string).
     */
    function proposeSetMinQuorumAbsolute(uint256 newAbsolute, bytes32 descriptionHash) external nonReentrant {
        if (newAbsolute == 0) revert InvalidParameter();
        _initiateProposal(ProposalType.SetMinQuorumAbsolute, abi.encode(newAbsolute), descriptionHash);
    }

    /* ===================== VOTING ===================== */

    /**
     * @notice Allows a $DIVINE holder to vote in support of the currently active proposal.
     * @dev Voting power equals the holder's current token balance (snapshot at vote time).
     * Each holder may vote only once per proposal. Transfers are locked during active proposals
     * to prevent vote manipulation and ensure fair representation of committed governance participants.
     * Reentrancy protected.
     */
    function voteOnCurrentProposal() external nonReentrant {
        if (balanceOf(_msgSender()) == 0) revert MustHoldDivineTokens();
        if (!activeProposal) revert NoOngoingProposal();
        if (block.timestamp >= currentProposalStart + proposalDuration) revert ProposalExpired();
        uint256 propId = currentProposalId;
        if (hasVoted[propId][_msgSender()]) revert AlreadyVoted();
        hasVoted[propId][_msgSender()] = true;
        uint256 power = balanceOf(_msgSender());
        currentYesVotes += power;
        emit Voted(proposalTypeToString(currentProposalType), propId, _msgSender(), power);
    }

    /* ===================== EXECUTION / FINALIZATION ===================== */

    /**
     * @notice Finalizes the current proposal after the voting period ends, queuing it for execution if quorum is met,
     * and rewards the finalizer with 1 DIVINE upon successful passage.
     * @dev Callable by any address. Uses hybrid quorum: yesVotes >= (votesCast * participationQuorumBps / 10_000)
     *      AND yesVotes >= minQuorumAbsolute. If passed, sets executionReadyTimestamp for timelock.
     *      Historical data is recorded for transparency and auditability. Reentrancy protected.
     */
    function finalizeCurrentProposal() external nonReentrant {
        if (!activeProposal) revert NoOngoingProposal();
        if (block.timestamp < currentProposalStart + proposalDuration) revert ProposalNotEnded();
        uint256 id = currentProposalId;
        string memory typeStr = proposalTypeToString(currentProposalType);
        uint256 total = totalSupply();
        if (total == 0) revert TotalSupplyZero();

        uint256 votesCast = currentYesVotes; // Yes-only voting
        bool quorumMet = (currentYesVotes * 10_000 >= votesCast * participationQuorumBps) &&
                         (currentYesVotes >= minQuorumAbsolute);
        bool passed = quorumMet;

        if (passed) {
            executionReadyTimestamp = block.timestamp + EXECUTION_DELAY;
            emit ProposalQueued(typeStr, id, executionReadyTimestamp);
            _mint(_msgSender(), 1 * 10 ** decimals());
        }

        proposalType[id] = currentProposalType;
        proposalData[id] = currentProposalData;
        proposalDescriptionHashes[id] = currentProposalDescriptionHash;
        proposalYesVotes[id] = currentYesVotes;
        proposalStartTime[id] = currentProposalStart;
        proposalExecuted[id] = false;

        activeProposal = false;
        currentProposalType = ProposalType.None;
        delete currentProposalData;
        delete currentProposalDescriptionHash;
        delete currentYesVotes;
        delete currentProposalStart;

        emit ProposalEnded(typeStr, id, passed);
    }

    /**
     * @notice Executes the current queued proposal after the timelock delay has elapsed.
     * @dev Callable by any address. Executes the stored proposal action if ready.
     *      Reentrancy protected. Emits ProposalExecuted upon success.
     */
    function executeCurrentProposal() external nonReentrant {
        if (executionReadyTimestamp == 0) revert NoExecutableProposal();
        if (block.timestamp < executionReadyTimestamp) revert ProposalNotReady();

        _executeCurrentProposal();

        uint256 id = currentProposalId;
        proposalExecuted[id] = true;
        emit ProposalExecuted(proposalTypeToString(currentProposalType), id);

        executionReadyTimestamp = 0;
    }

    /**
     * @notice Allows any address to fulfill a pending redemption for an investor and receive the current governance reward.
     * @dev Callable by anyone (no $DIVINE balance required). Pulls USDC from the caller's balance via USDD.fulfillRedemption.
     *      Mints $DIVINE reward to the caller based on rewardPerUSDC × redeemed USDC amount.
     *      If rewardPerUSDC is 0, fulfillment still succeeds but no reward is minted.
     *      Protected against reentrancy and zero-amount abuse.
     * @param investor The address whose pending redemption is to be fulfilled
     * @custom:security This function decentralizes redemption liquidity provision, removing the previous governance-only restriction.
     *                  Reward is capped by governance (max 2 $DIVINE per USDC) to control inflation.
     */
    function fulfillRedemptionDirect(address investor) external nonReentrant {
        if (investor == address(0)) revert InvalidParameter();

        uint256 amount = usdd.pendingRedemption(investor);
        if (amount == 0) revert NoPendingRedemption();

        // Execute the redemption (pulls USDC from msg.sender's balance)
        usdd.fulfillRedemption(investor);

        // Calculate and mint reward if configured
        if (rewardPerUSDC > 0) {
            // amount is in 6 decimals (USDC), rewardPerUSDC is wei DIVINE per full USDC unit
            uint256 reward = (amount * rewardPerUSDC) / 1_000_000;

            if (reward > 0) {
                _mint(_msgSender(), reward);
                emit RedemptionFulfilledWithReward(_msgSender(), investor, amount, reward);
            }
        }
    }

    /* ===================== TRANSFER LOCK DURING VOTING ===================== */
    
    /**
     * @dev Overrides ERC20 _update to prevent $DIVINE transfers while a proposal is active,
     * mitigating vote manipulation risks. Minting and burning are still permitted.
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (isProposalActive()) revert TransfersLocked();
        }
        super._update(from, to, value);
    }
}
