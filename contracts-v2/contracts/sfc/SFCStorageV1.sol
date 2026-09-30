// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {INodeDriverAuth} from "../interfaces/INodeDriverAuth.sol";

/**
 * @title SFCStorageV1
 *
 * @dev The v1 SFC's own state, slots 102..123, EXACTLY as the deployed v1 SFC and its 0.8.20 port
 * lay it out (docs/design/sfc-v2.md 5.1 in the node repository; `TestV1StorageIsThePortLayout` reads
 * every one of these slots raw on the deployed blob). SFC v2 is installed on the testnet over that
 * storage (DECIDE-22), so this contract is load-bearing byte for byte:
 *
 *  - never reorder, retype or remove a variable; a variable v2 no longer uses is renamed
 *    `__deprecated_<name>` and keeps its slot;
 *  - the four structs live only as mapping values, so members may be APPENDED to them, never
 *    inserted, retyped or reordered;
 *  - nothing is appended to this contract: v2's own state is SFCStorageV2, which follows it.
 *
 * `npm run verify` enforces all of it against layout/SFC.json, which is generated from the port's
 * compiled layout (`node compile.js --port-baselines`), not written by hand.
 */
abstract contract SFCStorageV1 {
    struct Validator {
        uint256 status;
        uint256 deactivatedTime;
        uint256 deactivatedEpoch;
        uint256 receivedStake;
        uint256 createdEpoch;
        uint256 createdTime;
        address auth;
    }

    struct Rewards {
        uint256 lockupExtraReward;
        uint256 lockupBaseReward;
        uint256 unlockedReward;
    }

    struct WithdrawalRequest {
        uint256 epoch;
        uint256 time;
        uint256 amount;
    }

    struct LockedDelegation {
        uint256 lockedStake;
        uint256 fromEpoch;
        uint256 endTime;
        uint256 duration;
    }

    struct EpochSnapshot {
        mapping(uint256 => uint256) receivedStake;
        mapping(uint256 => uint256) accumulatedRewardPerToken;
        mapping(uint256 => uint256) accumulatedUptime;
        mapping(uint256 => uint256) accumulatedOriginatedTxsFee;
        mapping(uint256 => uint256) offlineTime;
        mapping(uint256 => uint256) offlineBlocks;
        uint256[] validatorIDs;
        uint256 endTime;
        uint256 epochFee;
        uint256 totalBaseRewardWeight;
        uint256 totalTxRewardWeight;
        uint256 baseRewardPerSecond;
        uint256 totalStake;
        uint256 totalSupply;
    }

    // slot 102: the NodeDriverAuth predeploy the SFC calls back into (design 2.2).
    INodeDriverAuth internal node;
    // slot 103
    uint256 public currentSealedEpoch;
    // slot 104
    mapping(uint256 => Validator) public getValidator;
    // slot 105
    mapping(address => uint256) public getValidatorID;
    // slot 106
    mapping(uint256 => bytes) public getValidatorPubkey;
    // slot 107
    uint256 public lastValidatorID;
    // slot 108
    uint256 public totalStake;
    // slot 109
    uint256 public totalActiveStake;
    // slot 110: v2 counts every confiscation here (F5)
    uint256 public totalSlashedStake;
    // slot 111: delegator, validatorID -> rewards
    mapping(address => mapping(uint256 => Rewards)) internal _rewardsStash;
    // slot 112
    mapping(address => mapping(uint256 => uint256)) public stashedRewardsUntilEpoch;
    // slot 113: delegator, validatorID, wrID -> request
    mapping(address => mapping(uint256 => mapping(uint256 => WithdrawalRequest))) public getWithdrawalRequest;
    // slot 114
    mapping(address => mapping(uint256 => uint256)) public getStake;
    // slot 115
    mapping(address => mapping(uint256 => LockedDelegation)) public getLockupInfo;
    // slot 116
    mapping(address => mapping(uint256 => Rewards)) public getStashedLockupRewards;
    // slot 117: v1's instant, owner-set emission rate. v2 reads the ConstantsManager instead.
    uint256 internal __deprecated_baseRewardPerSecond;
    // slot 118: every native NEC in existence (F1; design 7)
    uint256 public totalSupply;
    // slot 119
    mapping(uint256 => EpochSnapshot) public getEpochSnapshot;
    // slots 120, 121: moved to the ConstantsManager, bounded (audit SFC-8)
    uint256 internal __deprecated_offlinePenaltyThresholdBlocksNum;
    uint256 internal __deprecated_offlinePenaltyThresholdTime;
    // slot 122: validator ID -> refund ratio of a slashed validator's delegations
    mapping(uint256 => uint256) public slashingRefundRatio;
    // slot 123: the StakeTokenizer / sNEC is removed (F10); initializeV2 requires this to be zero
    address internal __deprecated_stakeTokenizerAddress;
}
