// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IConstantsManager} from "../interfaces/IConstantsManager.sol";
import {IRewardsReserve} from "../interfaces/IRewardsReserve.sol";
import {IHostBonds} from "../interfaces/IHostBonds.sol";

/**
 * @title SFCStorageV2
 *
 * @dev What SFC v2 appends after the v1 state (SFCStorageV1, slots 102..123), from slot 124
 * (docs/design/sfc-v2.md 5.2 in the node repository). Append-only from now on: a later version takes
 * its new variables from the FRONT of `__gap` and shrinks the gap by as many slots, so the gap still
 * ends at slot 185 and nothing after it moves (`npm run verify` refuses anything else).
 *
 * The ReentrancyGuard's status word is here, not in a base contract ahead of the v1 variables: a
 * base with storage placed there would move slot 102 and break the install over v1 storage.
 */
abstract contract SFCStorageV2 {
    /// @dev One interval of epochs in which a validator was out of the validator set between an
    /// OFFLINE deactivation and its reactivation, with the reward index it held when it left
    /// (design 9, D9).
    struct RewardGap {
        uint256 fromEpoch;
        uint256 toEpoch;
        uint256 accumulatedRewardPerToken;
    }

    // slot 124: every economic parameter (design 6.2)
    IConstantsManager internal consts;
    // slot 125: emission source; sink of the fee reserve share, unlock penalties and confiscations
    IRewardsReserve public rewardsReserve;
    // slot 126: the gas-fee treasury share (sustainability carve-out included)
    address public treasury;
    // slot 127: the insurance share of confiscations
    address public insurancePool;
    // slot 128: ECO-02a's HostBonds; zero until installed
    IHostBonds public hostBonds;
    // slot 129: ReentrancyGuard (0 or 1: not entered, 2: entered)
    uint256 internal _reentrancyStatus;
    // slot 130: fences setGenesisValidator / setGenesisDelegation once the first epoch is sealed
    bool public genesisSealed;
    // slot 131: validator ID -> the epoch of its last pubkey rotation (one per epoch)
    mapping(uint256 => uint256) public lastPubkeyUpdateEpoch;
    // slot 132: validator ID -> its reward-index gaps, oldest first (D9)
    mapping(uint256 => RewardGap[]) internal _rewardGaps;
    // slot 133: vaults excluded from circulatingSupply() (ECO-01a; the view arrives with UPG-00)
    address[] public excludedFromCirculation;
    // slot 134: NEC minted by the tail (_mint), the only path that moves totalSupply after genesis
    uint256 public totalMinted;
    // slot 135: NEC drawn from the RewardsReserve (supply-neutral)
    uint256 public totalReserveDrawn;
    // slots 136..185: reserved headroom, used from the front
    uint256[50] private __gap;
}
