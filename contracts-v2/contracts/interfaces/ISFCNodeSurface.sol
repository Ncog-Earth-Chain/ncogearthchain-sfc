// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title ISFCNodeSurface
 *
 * @dev The SFC exactly as the NCOG node sees it. SFC v2 must implement this interface, and the node
 * repository pins it: `ncogearthchain/genesis/sfc/nodesurface_test.go` compares the compiled ABI of
 * this file with the selectors the node's own calldata builders produce and the topic hashes the
 * node's own decoders listen for. Changing a single type, name, argument order or `indexed` flag
 * here breaks a running network, so this file changes only together with the node.
 *
 * The node never calls the SFC directly. The path is
 *
 *     node internal tx --> NodeDriver (onlyNode: msg.sender == 0) --> NodeDriverAuth (onlyDriver)
 *                      --> SFC (onlyDriver: msg.sender == NodeDriverAuth)
 *
 * with the SAME selector at every hop, plus one call from NetworkInitializer at block 1. The six
 * internal-tx selectors of gossip/blockproc/drivermodule/driver_txs.go therefore project onto the
 * six functions below.
 *
 * Events: the node decodes seven SFC events (gossip/sfcapi/process.go), reading topics[1..] and
 * fixed data offsets, so both the signature and the indexed layout are part of the contract. Two
 * further topics the node listens for, ClaimedDelegationReward and ClaimedValidatorReward
 * (gossip/sfcapi/sfcpos.go), are dead v1 names that no SFC of this lineage emits; v2 does not emit
 * them either.
 */
interface ISFCNodeSurface {
    // --- the seven events the node consumes (gossip/sfcapi/process.go) ---

    event CreatedValidator(uint256 indexed validatorID, address indexed auth, uint256 createdEpoch, uint256 createdTime);
    event DeactivatedValidator(uint256 indexed validatorID, uint256 deactivatedEpoch, uint256 deactivatedTime);
    event ChangedValidatorStatus(uint256 indexed validatorID, uint256 status);
    event Delegated(address indexed delegator, uint256 indexed toValidatorID, uint256 amount);
    event Undelegated(address indexed delegator, uint256 indexed toValidatorID, uint256 indexed wrID, uint256 amount);
    event ClaimedRewards(address indexed delegator, uint256 indexed toValidatorID, uint256 lockupExtraReward, uint256 lockupBaseReward, uint256 unlockedReward);
    event RestakedRewards(address indexed delegator, uint256 indexed toValidatorID, uint256 lockupExtraReward, uint256 lockupBaseReward, uint256 unlockedReward);

    // --- called once, at block 1, by NetworkInitializer.initializeAll ---

    function initialize(uint256 sealedEpoch, uint256 _totalSupply, address nodeDriver, address owner) external;

    // --- called by NodeDriverAuth (onlyDriver), forwarding the node's internal transactions ---

    function setGenesisValidator(
        address auth,
        uint256 validatorID,
        bytes calldata pubkey,
        uint256 status,
        uint256 createdEpoch,
        uint256 createdTime,
        uint256 deactivatedEpoch,
        uint256 deactivatedTime
    ) external;

    function setGenesisDelegation(
        address delegator,
        uint256 toValidatorID,
        uint256 stake,
        uint256 lockedStake,
        uint256 lockupFromEpoch,
        uint256 lockupEndTime,
        uint256 lockupDuration,
        uint256 earlyUnlockPenalty,
        uint256 rewards
    ) external;

    function deactivateValidator(uint256 validatorID, uint256 status) external;

    function sealEpochValidators(uint256[] calldata nextValidatorIDs) external;

    function sealEpoch(
        uint256[] calldata offlineTimes,
        uint256[] calldata offlineBlocks,
        uint256[] calldata uptimes,
        uint256[] calldata originatedTxsFee
    ) external;
}
