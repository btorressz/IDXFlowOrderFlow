// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// ─── OpenZeppelin Imports ─────────────────────────────────────────────────────
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// ─── External Interfaces ───────────────────────────────────────────────────────

/// @notice Interface for zero-knowledge proof verification
/// @dev Used to verify ZK proofs for privacy-preserving reward claims
interface IZKVerifier {
    /// @notice Verifies a zero-knowledge proof for a user's volume claim
    /// @param proof The ZK proof data
    /// @param epoch The epoch for which the proof is valid
    /// @param user The user address claiming rewards
    /// @return True if the proof is valid, false otherwise
    function verify(bytes calldata proof, uint256 epoch, address user) external view returns (bool);
}

/// @notice Interface for identity verification registry
/// @dev Used for KYC/AML compliance in reward distribution
interface IIdentityRegistry {
    /// @notice Checks if a user has completed identity verification
    /// @param user The user address to check
    /// @return True if the user is verified, false otherwise
    function isVerified(address user) external view returns (bool);
}

/// @notice Interface for ERC-6551 token bound accounts
/// @dev Enables binding user accounts to NFTs for enhanced functionality
interface IERC6551Registry {
    /// @notice Gets the token bound account address for a given NFT
    /// @param tokenContract The NFT contract address
    /// @param chainId The chain ID where the account exists
    /// @param implementation The account implementation address
    /// @param tokenId The specific NFT token ID
    /// @return The token bound account address
    function account(
        address tokenContract,
        uint256 chainId,
        address implementation,
        uint256 tokenId
    ) external view returns (address);
}

/// @notice Interface for LayerZero cross-chain messaging
/// @dev Used for cross-chain state synchronization
interface ILayerZeroEndpoint {
    /// @notice Sends a cross-chain message
    /// @param _dstChainId Destination chain ID
    /// @param _payload Message payload
    /// @param _refundAddress Address to refund excess gas fees
    /// @param _zroPaymentAddress ZRO token payment address (if applicable)
    /// @param _adapterParams Additional adapter parameters
    function send(
        uint16 _dstChainId,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;
}

// ─── ERC-4626 Vault for Composable Fee Sharing ────────────────────────────────

/// @title Staking Vault
/// @notice ERC-4626 compliant vault for staked tokens
/// @dev Enables composable DeFi integrations with staked positions
contract StakingVault is ERC4626 {
    /// @notice Creates a new staking vault
    /// @param asset The underlying ERC20 token
    /// @param name The vault token name
    /// @param symbol The vault token symbol
    constructor(IERC20 asset, string memory name, string memory symbol)
        ERC20(name, symbol)
        ERC4626(asset)
    {}
}

// ─── Main Contract ─────────────────────────────────────────────────────────────

/// @title IDXFlow Order Flow Rewards Contract
/// @notice Advanced DeFi rewards system with staking, vesting, and cross-chain capabilities
/// @dev Implements multiple reward mechanisms including volume-based rewards, staking tiers,
///      ZK proofs, KYC compliance, gas rebates, and cross-chain synchronization
/// @author IDXFlow Team
/// @custom:version 1.0.0
contract IDXFlowOrderFlow is
    EIP712("IDXFlow","1"),
    AccessControl,
    Pausable,
    IERC1363Receiver
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using Math for uint256;

    // ── Roles ───────────────────────────────────────────────────────────────────
    
    /// @notice Role for pausing/unpausing contract functions
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");
    
    /// @notice Role for governance functions and parameter updates
    bytes32 public constant GOVERNOR_ROLE  = keccak256("GOVERNOR_ROLE");

    // ── Tokens & Integrations ───────────────────────────────────────────────────
    
    /// @notice The main reward token used throughout the system
    IERC20       public immutable token;
    
    /// @notice Permit-enabled version of the reward token for gasless approvals
    IERC20Permit public immutable permitToken;
    
    /// @notice Zero-knowledge proof verifier for privacy-preserving claims
    IZKVerifier        public zkVerifier;
    
    /// @notice Identity registry for KYC/AML compliance
    IIdentityRegistry  public identityRegistry;
    
    /// @notice ERC-6551 registry for token bound accounts
    IERC6551Registry   public erc6551Registry;
    
    /// @notice LayerZero endpoint for cross-chain messaging
    ILayerZeroEndpoint public lzEndpoint;
    
    /// @notice ERC-4626 vault for composable staking
    StakingVault       public vault;

    // ── Epoch & Reward Params ───────────────────────────────────────────────────
    
    /// @notice Reward rate per unit of volume (scaled by 1e6)
    uint256 public rewardRatePerVolume;
    
    /// @notice Duration of each reward epoch in seconds
    uint256 public epochDuration;
    
    /// @notice Minimum volume required to claim rewards in an epoch
    uint256 public minVolumeThreshold;
    
    /// @notice Current active epoch number
    uint256 public currentEpoch;
    
    /// @notice Timestamp of the last epoch reset
    uint256 public lastEpochReset;
    
    /// @notice Total amount of rewards distributed across all users
    uint256 public totalDistributed;

    // ── Merkle Claims ───────────────────────────────────────────────────────────
    
    /// @notice Merkle root for batch reward distributions
    bytes32 public merkleRoot;
    
    /// @notice Tracks which addresses have claimed their merkle rewards
    mapping(address => bool) public merkleClaimed;

    // ── Unstake Cooldown ─────────────────────────────────────────────────────────
    
    /// @notice Cooldown period for unstaking in seconds
    uint256 public unstakeCooldown;
    
    /// @notice Amount of tokens pending unstaking for each user
    mapping(address => uint256) public pendingUnstakes;
    
    /// @notice Timestamp when unstaked tokens become withdrawable
    mapping(address => uint256) public unstakeUnlockTime;

    // ── Bonded Slashing ─────────────────────────────────────────────────────────
    
    /// @notice Represents a bonded stake with lock time
    /// @param amount The bonded token amount
    /// @param unlockTime When the bond can be withdrawn
    struct Bond { uint256 amount; uint256 unlockTime; }
    
    /// @notice User bonded stakes for slashing protection
    mapping(address => Bond) public bonds;

    // ── Reward Vesting ──────────────────────────────────────────────────────────
    
    /// @notice Represents a vesting reward stream
    /// @param total Total amount to be vested
    /// @param claimed Amount already claimed from vesting
    /// @param startEpoch Epoch when vesting started
    /// @param vestingEpochs Number of epochs over which rewards vest
    struct RewardStream {
        uint256 total;
        uint256 claimed;
        uint256 startEpoch;
        uint256 vestingEpochs;
    }
    
    /// @notice Vesting streams for each user
    mapping(address => RewardStream) public rewardStreams;
    
    /// @notice Default number of epochs for reward vesting
    uint256 public defaultVestingEpochs;

    // ── Gas Rebate ───────────────────────────────────────────────────────────────
    
    /// @notice Rate for gas rebates (tokens per gas unit)
    uint256 public rebateRate;
    
    /// @notice Maximum gas amount eligible for rebate
    uint256 public maxGasRebate;

    // ── User State ──────────────────────────────────────────────────────────────
    
    /// @notice Fee tiers based on staked amount
    /// @dev Higher tiers receive better reward multipliers
    enum FeeTier { Bronze, Silver, Gold, Platinum, Diamond }
    
    /// @notice Comprehensive user information and state
    /// @param totalVolume Cumulative trading volume across all epochs
    /// @param epochVolume Trading volume in the current epoch
    /// @param stakedAmount Currently staked token amount
    /// @param tier Current fee tier based on staked amount
    /// @param lastClaimEpoch Last epoch when user claimed rewards
    /// @param boundAccount ERC-6551 token bound account (if any)
    /// @param autoCompound Whether to automatically compound rewards
    struct UserInfo {
        uint256 totalVolume;
        uint256 epochVolume;
        uint256 stakedAmount;
        FeeTier tier;
        uint256 lastClaimEpoch;
        address boundAccount;
        bool autoCompound;
    }
    
    /// @notice User information mapping
    mapping(address => UserInfo) public users;

    // ── Meta-Tx ─────────────────────────────────────────────────────────────────
    
    /// @notice Nonces for meta-transaction replay protection
    mapping(address => uint256) public nonces;
    
    /// @notice EIP-712 typehash for claim signatures
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(uint256 epoch,uint256 volume,uint256 nonce,address user)");

    // ── Events ─────────────────────────────────────────────────────────────────
    
    /// @notice Emitted when user volume is recorded
    /// @param user The user address
    /// @param volume The volume amount recorded
    event VolumeRecorded(address indexed user, uint256 volume);
    
    /// @notice Emitted when user stake is updated
    /// @param user The user address
    /// @param amount The stake amount change
    /// @param tier The new fee tier
    event StakeUpdated(address indexed user, uint256 amount, FeeTier tier);
    
    /// @notice Emitted when rewards are claimed
    /// @param user The user address
    /// @param amount The reward amount claimed
    event RewardsClaimed(address indexed user, uint256 amount);
    
    /// @notice Emitted when rewards are added to vesting
    /// @param user The user address
    /// @param amount The amount added to vesting
    /// @param startEpoch The vesting start epoch
    /// @param vestingEpochs The vesting duration in epochs
    event RewardsVested(address indexed user, uint256 amount, uint256 startEpoch, uint256 vestingEpochs);
    
    /// @notice Emitted when vested rewards are claimed
    /// @param user The user address
    /// @param amount The vested amount claimed
    event VestedRewardsClaimed(address indexed user, uint256 amount);
    
    /// @notice Emitted when gas rebate is provided
    /// @param user The user address
    /// @param rebate The rebate amount
    /// @param gasUsed The gas amount used
    event GasRebate(address indexed user, uint256 rebate, uint256 gasUsed);
    
    /// @notice Emitted when unstaking is requested
    /// @param user The user address
    /// @param amount The amount to unstake
    event UnstakeRequested(address indexed user, uint256 amount);
    
    /// @notice Emitted when unstaking is executed
    /// @param user The user address
    /// @param amount The amount unstaked
    event UnstakeExecuted(address indexed user, uint256 amount);
    
    /// @notice Emitted when auto-compound is toggled
    /// @param user The user address
    /// @param enabled Whether auto-compound is enabled
    event AutoCompoundToggled(address indexed user, bool enabled);

    // ── Structs for Constructor Parameters ─────────────────────────────────────
    
    /// @notice Primary constructor parameters
    /// @param tokenAddress The reward token address
    /// @param zkVerifier Zero-knowledge proof verifier
    /// @param identityRegistry Identity verification registry
    /// @param erc6551Registry ERC-6551 token bound account registry
    /// @param lzEndpoint LayerZero cross-chain endpoint
    /// @param rewardRatePerVolume Reward rate per volume unit
    /// @param epochDuration Duration of each epoch
    /// @param minVolumeThreshold Minimum volume for reward eligibility
    struct ConstructorParams {
        address tokenAddress;
        IZKVerifier zkVerifier;
        IIdentityRegistry identityRegistry;
        IERC6551Registry erc6551Registry;
        ILayerZeroEndpoint lzEndpoint;
        uint256 rewardRatePerVolume;
        uint256 epochDuration;
        uint256 minVolumeThreshold;
    }
    
    /// @notice Secondary constructor parameters
    /// @param unstakeCooldown Cooldown period for unstaking
    /// @param defaultVestingEpochs Default vesting duration
    /// @param rebateRate Gas rebate rate
    /// @param maxGasRebate Maximum gas eligible for rebate
    struct ConstructorParams2 {
        uint256 unstakeCooldown;
        uint256 defaultVestingEpochs;
        uint256 rebateRate;
        uint256 maxGasRebate;
    }

    /// @notice Initializes the IDXFlow rewards contract
    /// @param params1 Primary configuration parameters
    /// @param params2 Secondary configuration parameters
    constructor(
        ConstructorParams memory params1,
        ConstructorParams2 memory params2
    ) {
        token               = IERC20(params1.tokenAddress);
        permitToken         = IERC20Permit(params1.tokenAddress);
        zkVerifier          = params1.zkVerifier;
        identityRegistry    = params1.identityRegistry;
        erc6551Registry     = params1.erc6551Registry;
        lzEndpoint          = params1.lzEndpoint;

        rewardRatePerVolume   = params1.rewardRatePerVolume;
        epochDuration         = params1.epochDuration;
        minVolumeThreshold    = params1.minVolumeThreshold;
        unstakeCooldown       = params2.unstakeCooldown;
        defaultVestingEpochs  = params2.defaultVestingEpochs;
        rebateRate            = params2.rebateRate;
        maxGasRebate          = params2.maxGasRebate;

        currentEpoch      = 1;
        lastEpochReset    = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(GOVERNOR_ROLE, msg.sender);

        vault = new StakingVault(IERC20(params1.tokenAddress), "IDXFlow Vault", "IDXV");
    }

    // ── Meta-Transactions ───────────────────────────────────────────────────────
    
    /// @notice Claims rewards using a meta-transaction signature
    /// @dev Enables gasless reward claiming through signed messages
    /// @param epoch The epoch for which rewards are claimed
    /// @param volume The user's trading volume for the epoch
    /// @param signature EIP-712 signature authorizing the claim
    function claimRewardsWithSig(
        uint256 epoch,
        uint256 volume,
        bytes calldata signature
    ) external whenNotPaused {
        uint256 gasStart = gasleft();
        _verifySignature(epoch, volume, signature);
        _recordVolume(msg.sender, volume);
        _processReward(msg.sender);
        _maybeRebate(msg.sender, gasStart);
    }

    /// @notice Verifies EIP-712 signature for meta-transactions
    /// @dev Internal function to validate claim signatures
    /// @param epoch The epoch in the signature
    /// @param volume The volume in the signature
    /// @param signature The signature to verify
    function _verifySignature(uint256 epoch, uint256 volume, bytes calldata signature) internal {
        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, epoch, volume, nonces[msg.sender]++, msg.sender)
        );
        require(_hashTypedDataV4(structHash).recover(signature) == msg.sender, "Invalid sig");
    }

    // ── Permit Staking ──────────────────────────────────────────────────────────
    
    /// @notice Stakes tokens using EIP-2612 permit for gasless approval
    /// @dev Combines permit approval and staking in a single transaction
    /// @param amount Amount of tokens to stake
    /// @param deadline Permit signature deadline
    /// @param v Signature parameter v
    /// @param r Signature parameter r
    /// @param s Signature parameter s
    function stakeWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused {
        permitToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
        token.safeTransferFrom(msg.sender, address(this), amount);
        _stake(msg.sender, amount);
    }

    // ── ERC-6551 Binding ───────────────────────────────────────────────────────
    
    /// @notice Binds user account to an ERC-6551 token bound account
    /// @dev Enables NFT-based account functionality and enhanced features
    /// @param nftContract The NFT contract address
    /// @param tokenId The specific NFT token ID
    function bindToToken(address nftContract, uint256 tokenId) external {
        address acct = erc6551Registry.account(
            nftContract, block.chainid, address(this), tokenId
        );
        require(acct != address(0), "Invalid 6551");
        users[msg.sender].boundAccount = acct;
    }

    // ── MEV-Protected Claim ────────────────────────────────────────────────────
    
    /// @notice Claims rewards with MEV protection through private mempool
    /// @dev Provides protection against front-running and sandwich attacks
    /// @param volume The user's trading volume for reward calculation
    function claimRewardsPrivate(uint256 volume) external whenNotPaused {
        uint256 gasStart = gasleft();
        _recordVolume(msg.sender, volume);
        _processReward(msg.sender);
        _maybeRebate(msg.sender, gasStart);
    }

    // ── ZK Proof Claim ─────────────────────────────────────────────────────────
    
    /// @notice Claims rewards using zero-knowledge proof verification
    /// @dev Enables privacy-preserving reward claims without revealing sensitive data
    /// @param volume The claimed trading volume
    /// @param proof Zero-knowledge proof of volume eligibility
    function claimWithZKProof(uint256 volume, bytes calldata proof) external whenNotPaused {
        uint256 gasStart = gasleft();
        require(zkVerifier.verify(proof, currentEpoch, msg.sender), "Invalid ZK");
        _recordVolume(msg.sender, volume);
        _processReward(msg.sender);
        _maybeRebate(msg.sender, gasStart);
    }

    // ── KYC Claim ──────────────────────────────────────────────────────────────
    
    /// @notice Claims rewards with KYC/AML compliance verification
    /// @dev Requires identity verification for regulatory compliance
    /// @param volume The user's trading volume for reward calculation
    function claimKYCRewards(uint256 volume) external whenNotPaused {
        uint256 gasStart = gasleft();
        require(identityRegistry.isVerified(msg.sender), "Not KYC");
        _recordVolume(msg.sender, volume);
        _processReward(msg.sender);
        _maybeRebate(msg.sender, gasStart);
    }

    // ── Merkle-Based Claim ─────────────────────────────────────────────────────
    
    /// @notice Sets the merkle root for batch reward distributions
    /// @dev Only governance can update the merkle root for security
    /// @param _root The new merkle root hash
    function setMerkleRoot(bytes32 _root) external onlyRole(GOVERNOR_ROLE) {
        merkleRoot = _root;
    }
    
    /// @notice Claims rewards using merkle proof verification
    /// @dev Enables gas-efficient batch reward distributions
    /// @param rewardAmount The reward amount to claim
    /// @param proof Merkle proof of reward eligibility
    function claimMerkleReward(
        uint256 rewardAmount,
        bytes32[] calldata proof
    ) external whenNotPaused {
        uint256 gasStart = gasleft();
        _processMerkleClaim(rewardAmount, proof);
        _maybeRebate(msg.sender, gasStart);
    }

    /// @notice Processes merkle-based reward claims
    /// @dev Internal function to handle merkle proof verification and payout
    /// @param rewardAmount The amount to claim
    /// @param proof The merkle proof
    function _processMerkleClaim(uint256 rewardAmount, bytes32[] calldata proof) internal {
        require(!merkleClaimed[msg.sender], "Already claimed");
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, rewardAmount));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "Invalid proof");
        
        merkleClaimed[msg.sender] = true;
        token.safeTransfer(msg.sender, rewardAmount);
        totalDistributed += rewardAmount;
        emit RewardsClaimed(msg.sender, rewardAmount);
    }

    // ── Unstake Cooldown ───────────────────────────────────────────────────────
    
    /// @notice Requests unstaking of tokens with cooldown period
    /// @dev Initiates unstaking process with mandatory waiting period
    /// @param amount Amount of tokens to unstake
    function requestUnstake(uint256 amount) external whenNotPaused {
        UserInfo storage u = users[msg.sender];
        require(u.stakedAmount >= amount, "Insufficient staked");
        
        u.stakedAmount -= amount;
        u.tier = _calculateFeeTier(u.stakedAmount);
        pendingUnstakes[msg.sender] = amount;
        unstakeUnlockTime[msg.sender] = block.timestamp + unstakeCooldown;
        
        emit UnstakeRequested(msg.sender, amount);
    }
    
    /// @notice Withdraws unstaked tokens after cooldown period
    /// @dev Completes the unstaking process and transfers tokens
    function withdrawUnstaked() external whenNotPaused {
        uint256 amount = pendingUnstakes[msg.sender];
        require(amount > 0, "No pending unstake");
        require(block.timestamp >= unstakeUnlockTime[msg.sender], "Cooldown active");
        
        delete pendingUnstakes[msg.sender];
        delete unstakeUnlockTime[msg.sender];
        token.safeTransfer(msg.sender, amount);
        
        emit UnstakeExecuted(msg.sender, amount);
    }

    // ── Reward Vesting ─────────────────────────────────────────────────────────
    
    /// @notice Claims available vested rewards
    /// @dev Allows users to claim rewards that have completed vesting
    function claimVestedRewards() external whenNotPaused {
        RewardStream storage s = rewardStreams[msg.sender];
        require(s.total > s.claimed, "None vested");
        
        uint256 claimable = _calculateVestedAmount(s);
        require(claimable > 0, "Nothing to claim");
        
        s.claimed += claimable;
        token.safeTransfer(msg.sender, claimable);
        emit VestedRewardsClaimed(msg.sender, claimable);
    }

    /// @notice Calculates the amount of vested rewards available for claiming
    /// @dev Internal function to compute vested amount based on time elapsed
    /// @param s The reward stream storage reference
    /// @return The amount of tokens available for claiming
    function _calculateVestedAmount(RewardStream storage s) internal view returns (uint256) {
        uint256 passed = currentEpoch - s.startEpoch;
        uint256 vestPortion = Math.min(passed, s.vestingEpochs);
        uint256 vested = (s.total * vestPortion) / s.vestingEpochs;
        return vested - s.claimed;
    }

    // ── Bonded Slashing ────────────────────────────────────────────────────────
    
    /// @notice Creates a bonded stake with lock period
    /// @dev Bonds tokens that can be slashed for misbehavior
    /// @param amount Amount of tokens to bond
    /// @param lockDuration Duration of the bond lock in seconds
    function bondedStake(uint256 amount, uint256 lockDuration) external whenNotPaused {
        token.safeTransferFrom(msg.sender, address(this), amount);
        bonds[msg.sender] = Bond(amount, block.timestamp + lockDuration);
    }
    
    /// @notice Slashes a user's bonded stake
    /// @dev Emergency function to penalize misbehavior (requires appropriate permissions)
    /// @param user The user whose bond to slash
    function slashBond(address user) external whenNotPaused {
        Bond storage b = bonds[user];
        require(b.amount > 0, "No bond");
        token.safeTransfer(msg.sender, b.amount);
        delete bonds[user];
    }
    
    /// @notice Withdraws bonded stake after lock period
    /// @dev Allows users to reclaim their bonded tokens after expiration
    function withdrawBond() external whenNotPaused {
        Bond storage b = bonds[msg.sender];
        require(block.timestamp >= b.unlockTime, "Bond locked");
        token.safeTransfer(msg.sender, b.amount);
        delete bonds[msg.sender];
    }

    // ── ERC-1363 Auto-Stake ────────────────────────────────────────────────────
    
    /// @notice Handles ERC-1363 token transfers for automatic staking
    /// @dev Automatically stakes tokens sent via transferAndCall
    /// @param from The address sending tokens
    /// @param amount The amount of tokens received
    /// @return The function selector to confirm receipt
    function onTransferReceived(
        address, address from, uint256 amount, bytes calldata
    ) external override whenNotPaused returns (bytes4) {
        require(msg.sender == address(token), "Unknown token");
        _stake(from, amount);
        return IERC1363Receiver.onTransferReceived.selector;
    }

    // ── Governance & Pausing ────────────────────────────────────────────────────
    
    /// @notice Pauses all contract functions
    /// @dev Emergency function to halt operations
    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    
    /// @notice Unpauses all contract functions
    /// @dev Resumes normal operations after pause
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
    
    /// @notice Updates the reward rate per volume
    /// @dev Governance function to adjust reward economics
    /// @param newRate The new reward rate (scaled by 1e6)
    function updateRewardRate(uint256 newRate) external onlyRole(GOVERNOR_ROLE) {
        rewardRatePerVolume = newRate;
    }

    // ── Cross-Chain Mirroring ───────────────────────────────────────────────────
    
    /// @notice Mirrors contract state to another chain
    /// @dev Uses LayerZero to synchronize state across chains
    /// @param dstChainId The destination chain ID
    function mirrorState(uint16 dstChainId) external payable onlyRole(GOVERNOR_ROLE) {
        bytes memory payload = abi.encode(currentEpoch, totalDistributed);
        lzEndpoint.send{ value: msg.value }(
            dstChainId, payload, payable(msg.sender), address(0), ""
        );
    }
    
    /// @notice Receives cross-chain state updates
    /// @dev Callback function for LayerZero message reception
    /// @param payload The encoded state data
    function lzReceive(
        uint16, bytes calldata, uint64, bytes calldata payload
    ) external {
        require(msg.sender == address(lzEndpoint), "Invalid endpoint");
        (uint256 e, uint256 d) = abi.decode(payload, (uint256,uint256));
        currentEpoch     = e;
        totalDistributed = d;
    }

    // ── Auto-Compound Toggle ───────────────────────────────────────────────────
    
    /// @notice Toggles automatic reward compounding
    /// @dev Allows users to automatically stake their rewards
    /// @param enabled Whether to enable auto-compounding
    function toggleAutoCompound(bool enabled) external whenNotPaused {
        users[msg.sender].autoCompound = enabled;
        emit AutoCompoundToggled(msg.sender, enabled);
    }

    // ── Batch Multicall ────────────────────────────────────────────────────────
    
    /// @notice Executes multiple function calls in a single transaction
    /// @dev Enables batching of operations for gas efficiency
    /// @param data Array of encoded function call data
    /// @return results Array of return data from each call
    function multicall(bytes[] calldata data) external whenNotPaused returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).call(data[i]);
            require(success, "Multicall failed");
            results[i] = result;
        }
        return results;
    }

    // ── Internal Helpers ───────────────────────────────────────────────────────
    
    /// @notice Records trading volume for a user and manages epoch transitions
    /// @dev Internal function to track user activity and handle epoch rollovers
    /// @param user The user address
    /// @param volume The volume amount to record
    function _recordVolume(address user, uint256 volume) internal {
        UserInfo storage u = users[user];
        
        if (block.timestamp >= lastEpochReset + epochDuration) {
            currentEpoch++;
            lastEpochReset = block.timestamp;
            u.epochVolume = 0;
        }
        
        u.totalVolume += volume;
        u.epochVolume += volume;
        emit VolumeRecorded(user, volume);
    }

     /// @notice Stakes a specified amount of tokens for a user and updates their fee tier.
    /// @dev Increases the user’s `stakedAmount` and recalculates their `tier`.
    /// @param user The address of the user whose tokens are being staked.
    /// @param amount The amount of tokens to stake.
    
    function _stake(address user, uint256 amount) internal {
        UserInfo storage u = users[user];
        u.stakedAmount += amount;
        u.tier = _calculateFeeTier(u.stakedAmount);
        emit StakeUpdated(user, amount, u.tier);
    }

    /// @notice Processes and issues a user’s reward for the current epoch.
    /// @dev Checks that the user hasn’t already claimed and meets the volume threshold,
    ///      then calculates and distributes their reward.
    /// @param user The address of the user to process rewards for.

    function _processReward(address user) internal {
        UserInfo storage u = users[user];
        require(u.lastClaimEpoch < currentEpoch, "Already claimed");
        require(u.epochVolume >= minVolumeThreshold, "Volume too low");
        
        uint256 reward = _calculateReward(u);
        require(reward > 0, "No reward");

        u.lastClaimEpoch = currentEpoch;
        totalDistributed += reward;

        _distributeReward(user, reward, u.autoCompound);
    }

    /// @notice Calculates the raw reward amount for a user based on their volume and tier.
    /// @dev Multiplies `epochVolume` by `rewardRatePerVolume`, then applies the tier multiplier.
    /// @param u Reference to the user’s `UserInfo` struct.
    /// @return The computed reward amount.

    function _calculateReward(UserInfo storage u) internal view returns (uint256) {
        uint256 baseReward = (u.epochVolume * rewardRatePerVolume) / 1e6;
        uint256 mult = _getRewardMultiplier(u.tier);
        return (baseReward * mult) / 100;
    }

    /// @notice Distributes the computed reward to the user, with immediate payout and vesting.
    /// @dev Splits reward into 25% immediate and 75% vesting; auto-compounds if enabled.
    /// @param user The address receiving rewards.
    /// @param reward The total reward amount to distribute.
    /// @param autoCompound Whether to restake the immediate portion automatically.

    function _distributeReward(address user, uint256 reward, bool autoCompound) internal {
        uint256 immediate = (reward * 25) / 100;
        uint256 vestingAmt = reward - immediate;

        if (autoCompound) {
            _stake(user, immediate);
        } else {
            token.safeTransfer(user, immediate);
            emit RewardsClaimed(user, immediate);
        }

        if (vestingAmt > 0) {
            _addToVestingStream(user, vestingAmt);
        }
    }

    /// @notice Adds tokens to the user’s vesting stream, initializing if first-time.
    /// @dev Records `startEpoch` and `vestingEpochs` on first vest, then accumulates `total`.
    /// @param user The address whose vesting stream is updated.
    /// @param amount The amount of tokens to vest.

    function _addToVestingStream(address user, uint256 amount) internal {
        RewardStream storage s = rewardStreams[user];
        if (s.startEpoch == 0) {
            s.startEpoch = currentEpoch;
            s.vestingEpochs = defaultVestingEpochs;
        }
        s.total += amount;
        emit RewardsVested(user, amount, s.startEpoch, s.vestingEpochs);
    }

     /// @notice Optionally rebates gas cost in tokens if gas used is below a threshold.
    /// @dev Computes `gasUsed = gasStart - gasleft()`, caps at `maxGasRebate`, and transfers rebate.
    /// @param user The address to receive any rebate.
    /// @param gasStart The `gasleft()` value at the start of the transaction.
    
    function _maybeRebate(address user, uint256 gasStart) internal {
        uint256 gasUsed = gasStart - gasleft();
        if (gasUsed <= maxGasRebate) {
            uint256 rebate = gasUsed * rebateRate;
            totalDistributed += rebate;
            token.safeTransfer(user, rebate);
            emit GasRebate(user, rebate, gasUsed);
        }
    }
    
    /// @notice Determines a user’s fee tier based on their staked token amount.
    /// @param s The user’s staked amount (scaled by token decimals).
    /// @return The corresponding `FeeTier` enum value.

    function _calculateFeeTier(uint256 s) internal pure returns (FeeTier) {
        if (s < 1_000 * 1e6)    return FeeTier.Bronze;
        if (s < 10_000 * 1e6)   return FeeTier.Silver;
        if (s < 50_000 * 1e6)   return FeeTier.Gold;
        if (s < 100_000 * 1e6)  return FeeTier.Platinum;
        return FeeTier.Diamond;
    }

     /// @notice Returns the reward multiplier (in basis points) for a given fee tier.
    /// @param t The user’s `FeeTier`.
    /// @return The multiplier (e.g., `150` = 1.5×).
    
    function _getRewardMultiplier(FeeTier t) internal pure returns (uint256) {
        if (t == FeeTier.Silver)   return 125;
        if (t == FeeTier.Gold)     return 150;
        if (t == FeeTier.Platinum) return 200;
        if (t == FeeTier.Diamond)  return 300;
        return 100;
    }
}