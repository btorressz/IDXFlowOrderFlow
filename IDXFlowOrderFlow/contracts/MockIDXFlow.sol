// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MockIDXFlow
/// @notice Simplified mock of IDXFlowOrderFlow for unit testing core staking and reward logic
/// @dev Omits external integrations (ZK, LayerZero, ERC-6551) and focuses on fee tiers, staking, rewards, and vesting
contract MockIDXFlow is AccessControl {
    /// @notice ERC-20 token used for staking and reward distribution
    IERC20 public token;

    /// @notice Role allowed to perform governance actions
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    /// @notice Current epoch counter
    uint256 public currentEpoch = 1;

    /// @notice Reward rate per unit of volume (scaled by 1e6)
    uint256 public rewardRatePerVolume = 1e6;

    /// @notice Minimum volume required to be eligible for rewards
    uint256 public minVolumeThreshold = 100 * 1e6;

    /// @notice Total rewards distributed so far
    uint256 public totalDistributed;

    /// @notice Default number of epochs over which rewards vest
    uint256 public defaultVestingEpochs = 4;

    /// @notice Fee tiers based on staked amount
    enum FeeTier { Bronze, Silver, Gold, Platinum, Diamond }

    /// @notice Tracks vesting streams per user
    struct RewardStream {
        uint256 total;        // total amount to vest
        uint256 claimed;      // amount already claimed
        uint256 startEpoch;   // epoch when vesting started
        uint256 vestingEpochs;// over how many epochs vesting occurs
    }

    /// @notice Tracks per-user state
    struct UserInfo {
        uint256 epochVolume;  // trading volume in current epoch
        uint256 stakedAmount; // total staked tokens
        FeeTier tier;         // current fee tier
        uint256 lastClaimEpoch;    // last epoch when rewards were claimed
        bool autoCompound;    // whether immediate rewards are restaked
    }

    /// @notice User info mapping
    mapping(address => UserInfo) public users;

    /// @notice Vesting streams mapping
    mapping(address => RewardStream) public rewardStreams;

    /// @notice Emitted when a user stakes tokens
    /// @param user The address staking tokens
    /// @param amount The amount staked
    /// @param tier The user’s resulting fee tier
    event StakeUpdated(address indexed user, uint256 amount, FeeTier tier);

    /// @notice Emitted when immediate rewards are paid out
    /// @param user The address receiving rewards
    /// @param amount The reward amount
    event RewardsClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when rewards are added to vesting
    /// @param user The address whose vesting was updated
    /// @param amount The amount vested
    /// @param startEpoch The epoch when vesting started
    /// @param vestingEpochs Number of epochs over which vesting occurs
    event RewardsVested(address indexed user, uint256 amount, uint256 startEpoch, uint256 vestingEpochs);

    /// @notice Constructs the mock with a given ERC-20 token
    /// @param _token The address of the ERC-20 token contract
    constructor(address _token) {
        token = IERC20(_token);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNOR_ROLE, msg.sender);
    }

    /// @notice Stakes a specified amount of tokens
    /// @dev Transfers tokens from sender to this contract, updates tier
    /// @param amount The amount of tokens to stake
    function mockStake(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        UserInfo storage u = users[msg.sender];
        u.stakedAmount += amount;
        u.tier = _calculateFeeTier(u.stakedAmount);
        emit StakeUpdated(msg.sender, amount, u.tier);
    }

    /// @notice Claims rewards based on provided volume
    /// @dev Requires volume ≥ `minVolumeThreshold` and that the user has not claimed this epoch
    /// @param volume The trading volume used for reward calculation
    function mockClaim(uint256 volume) external {
        UserInfo storage u = users[msg.sender];
        require(u.lastClaimEpoch < currentEpoch, "Already claimed");
        require(volume >= minVolumeThreshold, "Volume too low");

        u.epochVolume = volume;
        u.lastClaimEpoch = currentEpoch;

        uint256 baseReward = (volume * rewardRatePerVolume) / 1e6;
        uint256 reward = (baseReward * _getRewardMultiplier(u.tier)) / 100;
        totalDistributed += reward;

        uint256 immediate = (reward * 25) / 100;
        uint256 vestingAmt = reward - immediate;

        // immediate payout
        token.transfer(msg.sender, immediate);
        emit RewardsClaimed(msg.sender, immediate);

        // add to vesting
        if (vestingAmt > 0) {
            RewardStream storage s = rewardStreams[msg.sender];
            if (s.startEpoch == 0) {
                s.startEpoch = currentEpoch;
                s.vestingEpochs = defaultVestingEpochs;
            }
            s.total += vestingAmt;
            emit RewardsVested(msg.sender, vestingAmt, s.startEpoch, s.vestingEpochs);
        }
    }

    /// @notice Calculates the fee tier based on a staked amount
    /// @param s The staked token amount (with 6 decimals)
    /// @return The corresponding `FeeTier`
    function _calculateFeeTier(uint256 s) internal pure returns (FeeTier) {
        if (s < 1_000 * 1e6)    return FeeTier.Bronze;
        if (s < 10_000 * 1e6)   return FeeTier.Silver;
        if (s < 50_000 * 1e6)   return FeeTier.Gold;
        if (s < 100_000 * 1e6)  return FeeTier.Platinum;
        return FeeTier.Diamond;
    }

    /// @notice Returns the reward multiplier (in basis points) for a given tier
    /// @param t The user’s `FeeTier`
    /// @return The multiplier (e.g., `150` = 1.5×)
    function _getRewardMultiplier(FeeTier t) internal pure returns (uint256) {
        if (t == FeeTier.Silver)   return 125;
        if (t == FeeTier.Gold)     return 150;
        if (t == FeeTier.Platinum) return 200;
        if (t == FeeTier.Diamond)  return 300;
        return 100; // Bronze
    }
}
