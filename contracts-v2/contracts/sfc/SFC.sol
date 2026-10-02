// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "../common/Initializable.sol";
import {Ownable} from "../ownership/Ownable.sol";
import {Decimal} from "../common/Decimal.sol";
import {INodeDriverAuth} from "../interfaces/INodeDriverAuth.sol";
import {ISFCNodeSurface} from "../interfaces/ISFCNodeSurface.sol";
import {IConstantsManager} from "../interfaces/IConstantsManager.sol";
import {IRewardsReserve} from "../interfaces/IRewardsReserve.sol";
import {IHostBonds} from "../interfaces/IHostBonds.sol";
import {SFCStorageV1} from "./SFCStorageV1.sol";
import {SFCStorageV2} from "./SFCStorageV2.sol";

/**
 * @title SFC v2 core (GOV-01b)
 *
 * @dev The staking contract at 0xfc00face..., rewritten for solc 0.8.20 (docs/design/sfc-v2.md in the
 * node repository is the specification; the section numbers below are that document's).
 *
 * WHAT IT KEEPS
 *  - the node surface, exactly (2): the six node-facing functions and the seven consumed events come
 *    from ISFCNodeSurface, and the callbacks into NodeDriverAuth keep their order -- a validator's
 *    weight is always sent before its pubkey (2.2 rule 1);
 *  - the v1 storage as a prefix (5.1): SFCStorageV1 is slots 102..123, SFCStorageV2 appends from 124;
 *  - the reward-accounting core of v1: epoch snapshots, accumulatedRewardPerToken, the stash,
 *    commission and the three reward parts, and every v1 getter with its selector.
 *
 * WHAT IT FIXES (1, table F1..F14)
 *  - F1 the supply ledger: claims pay NEC the SFC already holds and never mint; the only mint is
 *    _mint, which moves totalSupply;
 *  - F2 emission is drawn from the RewardsReserve (supply-neutral). This is the fixed-budget STUB:
 *    ConstantsManager.emissionPerSecond() x the epoch's duration, while the reserve holds it; ECO-01b
 *    brings the glide controller and the tail mint;
 *  - F3 the fee split: 100% of the epoch's gas fees is re-credited and split validators / reserve /
 *    treasury; nothing is destroyed (DECIDE-25);
 *  - F4 every economic figure is read from the ConstantsManager when it is applied. There is no
 *    economic constant in this contract: the Timelock changes any of them through the
 *    ConstantsManager's bounded, rate-limited setters;
 *  - F5 a double-sign confiscates self-stake at fault time and routes it (reserve / insurance),
 *    delegations are charged at exit, both are counted in totalSlashedStake, and refunds are capped;
 *  - F6 the early-unlock penalty is linear: the share is applied once;
 *  - F7 renounceOwnership reverts (Ownable v2);
 *  - F8 reactivateValidator, updateValidatorPubkey, payouts by `call` behind a ReentrancyGuard;
 *  - F9 sealEpoch checks its array lengths; _syncValidator is internal;
 *  - F10 the StakeTokenizer is gone;
 *  - F13 the concentration cap (DECIDE-24; design D3);
 *  - F14 version() is "200" (D8).
 */
contract SFC is Initializable, Ownable, SFCStorageV1, SFCStorageV2, ISFCNodeSurface {
    // Validator status bits. The number grows with severity; a status only ever increases, except
    // through reactivateValidator (OFFLINE_BIT only). DOUBLESIGN_BIT is drivertype.DoublesignBit.
    uint256 internal constant OK_STATUS = 0;
    uint256 internal constant WITHDRAWN_BIT = 1;
    uint256 internal constant OFFLINE_BIT = 1 << 3;
    uint256 internal constant DOUBLESIGN_BIT = 1 << 7;
    uint256 internal constant CHEATER_MASK = DOUBLESIGN_BIT;

    // The one validator key the network accepts: ML-DSA-87, one type byte 0xc0 and 2,592 bytes of key
    // (design 2.2 rule 2, D4). A protocol fact, not an economic parameter: the node would reject every
    // event signed under any other key, so the contract is the only place a validator can be stopped
    // from registering one.
    uint256 internal constant PUBKEY_LENGTH = 2593;
    bytes1 internal constant PUBKEY_TYPE = 0xc0;

    // ConstantsManager.Param indices (its enum is append-only: an index is its storage index and never
    // changes meaning). Every economic figure below is read through _c() when it is applied.
    uint8 internal constant P_MIN_SELF_STAKE = 0;
    uint8 internal constant P_MAX_DELEGATED_RATIO = 1;
    uint8 internal constant P_VALIDATOR_COMMISSION = 2;
    uint8 internal constant P_MAX_VALIDATOR_WEIGHT_SHARE = 3;
    uint8 internal constant P_UNLOCKED_REWARD_RATIO = 4;
    uint8 internal constant P_MIN_LOCKUP_DURATION = 5;
    uint8 internal constant P_MAX_LOCKUP_DURATION = 6;
    uint8 internal constant P_WITHDRAWAL_PERIOD_EPOCHS = 7;
    uint8 internal constant P_WITHDRAWAL_PERIOD_TIME = 8;
    uint8 internal constant P_GAS_FEE_RESERVE_SHARE = 9;
    uint8 internal constant P_GAS_FEE_TREASURY_SHARE = 10;
    uint8 internal constant P_SUSTAINABILITY_SHARE = 16;
    uint8 internal constant P_UTILISATION_REWARD_SHARE = 17;
    uint8 internal constant P_OFFLINE_PENALTY_THRESHOLD_TIME = 18;
    uint8 internal constant P_OFFLINE_PENALTY_THRESHOLD_BLOCKS_NUM = 19;
    uint8 internal constant P_DOUBLE_SIGN_SELF_SLASH_RATIO = 20;
    uint8 internal constant P_DOUBLE_SIGN_DELEGATION_SLASH_RATIO = 21;
    uint8 internal constant P_CONFISCATION_RESERVE_SHARE = 22;
    uint8 internal constant P_MAX_SLASHING_REFUND_RATIO = 23;
    uint8 internal constant P_EMISSION_PER_SECOND = 24;

    // Errors. Custom errors, not strings: EIP-170 leaves the core no room for revert strings.
    error AlreadyExcluded();
    error AlreadyLockedUp();
    error ConcentrationCapExceeded();
    error DelegationLimitExceeded();
    error GenesisSealed();
    error IncorrectDuration();
    error InsufficientSelfStake();
    error LockedAboveStake();
    error LockupDurationDecreases();
    error MalformedPubkey();
    error ModulesAlreadySet();
    error NotAscending();
    error NotContract();
    error NotDriver();
    error NotEnoughEpochsPassed();
    error NotEnoughLockedStake();
    error NotEnoughTimePassed();
    error NotEnoughUnlockedStake();
    error NotExcluded();
    error NotLockedUp();
    error NotOffline();
    error NotRewardsReserve();
    error NothingToStash();
    error OnePubkeyUpdatePerEpoch();
    error PaymentFailed();
    error Reentrant();
    error RefundRatioTooHigh();
    error RequestExists();
    error RequestNotFound();
    error RewardRateUnderflow();
    error SealArraysMismatch();
    error StakeTokenizerSet();
    error TooEarly();
    error ValidatorExists();
    error ValidatorLockupEndsEarlier();
    error ValidatorNotActive();
    error ValidatorNotFound();
    error ValidatorNotSlashed();
    error ValidatorSlashed();
    error WrongStatus();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroRewards();

    event Withdrawn(address indexed delegator, uint256 indexed toValidatorID, uint256 indexed wrID, uint256 amount);
    event LockedUpStake(address indexed delegator, uint256 indexed validatorID, uint256 duration, uint256 amount);
    event UnlockedStake(address indexed delegator, uint256 indexed validatorID, uint256 amount, uint256 penalty);
    event UpdatedSlashingRefundRatio(uint256 indexed validatorID, uint256 refundRatio);
    event UpdatedValidatorPubkey(uint256 indexed validatorID, bytes pubkey);
    event Confiscated(uint256 indexed validatorID, address indexed delegator, uint256 amount, uint256 toReserve, uint256 toInsurance);
    event SplitEpochFees(uint256 indexed epoch, uint256 toValidators, uint256 toReserve, uint256 toTreasury, uint256 sustainability);
    event DrewRewards(uint256 indexed epoch, uint256 amount);
    event UpdatedModule(bytes32 indexed module, address addr);
    event ExcludedFromCirculation(address indexed vault);
    event IncludedInCirculation(address indexed vault);

    modifier onlyDriver() {
        if (msg.sender != address(node)) revert NotDriver();
        _;
    }

    modifier nonReentrant() {
        _enter();
        _;
        _reentrancyStatus = 1;
    }

    function _enter() private {
        if (_reentrancyStatus == 2) revert Reentrant();
        _reentrancyStatus = 2;
    }

    /// @dev Only the RewardsReserve pays the SFC by a plain transfer (its `draw`). Stake arrives with
    /// delegate/createValidator, fees and mints by incBalance; stray NEC would be stranded here.
    receive() external payable {
        if (msg.sender != address(rewardsReserve)) revert NotRewardsReserve();
    }

    // ================================================================ initialisation

    /// @notice Block 1 of a fresh genesis (NetworkInitializer). `_totalSupply` already includes the
    /// genesis stake (DECIDE-14), so setGenesisDelegation does not add it again. On a fresh genesis the
    /// builder writes the module slots (124..127); on the testnet install, initializeV2 does.
    function initialize(uint256 sealedEpoch, uint256 _totalSupply, address nodeDriver, address owner_) external initializer {
        if (nodeDriver == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        currentSealedEpoch = sealedEpoch;
        node = INodeDriverAuth(nodeDriver);
        totalSupply = _totalSupply;
        getEpochSnapshot[sealedEpoch].endTime = block.timestamp;
    }

    /// @notice The testnet install over v1 storage (DECIDE-22), by the owner (Timelock, 72 h class)
    /// right after NodeDriverAuth.upgradeCode. Runs once. Refuses to overwrite module slots a genesis
    /// builder already wrote, and refuses a v1 state that still has a stake tokenizer.
    function initializeV2(address consts_, address reserve_, address treasury_, address insurancePool_) external onlyOwner reinitializer(2) {
        if (__deprecated_stakeTokenizerAddress != address(0)) revert StakeTokenizerSet();
        if (address(consts) != address(0) || address(rewardsReserve) != address(0) || treasury != address(0) || insurancePool != address(0)) {
            revert ModulesAlreadySet();
        }
        consts = IConstantsManager(_contract(consts_));
        rewardsReserve = IRewardsReserve(_contract(reserve_));
        treasury = _contract(treasury_);
        insurancePool = _contract(insurancePool_);
    }

    // ================================================================ node-facing (driver)

    function setGenesisValidator(
        address auth,
        uint256 validatorID,
        bytes calldata pubkey,
        uint256 status,
        uint256 createdEpoch,
        uint256 createdTime,
        uint256 deactivatedEpoch,
        uint256 deactivatedTime
    ) external onlyDriver {
        if (genesisSealed) revert GenesisSealed();
        if (auth == address(0) || validatorID == 0) revert ZeroAddress();
        if (getValidator[validatorID].auth != address(0)) revert ValidatorExists();
        _requirePubkey(pubkey);
        _rawCreateValidator(auth, validatorID, pubkey, status, createdEpoch, createdTime, deactivatedEpoch, deactivatedTime);
        if (validatorID > lastValidatorID) {
            lastValidatorID = validatorID;
        }
    }

    /// @dev Credits the genesis stake with incBalance WITHOUT moving totalSupply: it is inside the
    /// declared supply already (DECIDE-14; the 4M double count ECO-01a found in v1). Genesis reward
    /// balances, if any, are new NEC and go through _mint.
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
    ) external onlyDriver {
        if (genesisSealed) revert GenesisSealed();
        if (!_validatorExists(toValidatorID)) revert ValidatorNotFound();
        if (lockedStake > stake) revert LockedAboveStake();
        _rawDelegate(delegator, toValidatorID, stake);
        node.incBalance(address(this), stake);
        if (rewards != 0) {
            _rewardsStash[delegator][toValidatorID].unlockedReward = rewards;
            _mint(rewards);
        }
        if (lockedStake != 0) {
            LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
            ld.lockedStake = lockedStake;
            ld.fromEpoch = lockupFromEpoch;
            ld.endTime = lockupEndTime;
            ld.duration = lockupDuration;
            getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward = earlyUnlockPenalty;
            emit LockedUpStake(delegator, toValidatorID, lockupDuration, lockedStake);
        }
    }

    /// @notice The node's report of a misbehaving validator. A double-sign confiscates the self-stake
    /// share NOW and routes it (F5, D6); delegations are charged when they exit (withdraw).
    function deactivateValidator(uint256 validatorID, uint256 status) external onlyDriver {
        if (status == OK_STATUS) revert WrongStatus();
        if (!_validatorExists(validatorID)) revert ValidatorNotFound();
        bool wasCheater = isSlashed(validatorID);
        _setValidatorDeactivated(validatorID, status);
        if (!wasCheater && isSlashed(validatorID)) {
            _slashSelfStake(validatorID);
        }
        _syncValidator(validatorID, false);
    }

    /// @notice The next epoch's validator set. The node sends SortedIDs(), so neither check can fire on
    /// its input; they stop a malformed set from being recorded.
    function sealEpochValidators(uint256[] calldata nextValidatorIDs) external onlyDriver {
        EpochSnapshot storage snapshot = getEpochSnapshot[currentEpoch()];
        uint256 prev = 0;
        uint256 total = snapshot.totalStake;
        for (uint256 i = 0; i < nextValidatorIDs.length; i++) {
            uint256 validatorID = nextValidatorIDs[i];
            if (validatorID <= prev) revert NotAscending();
            if (!_validatorExists(validatorID)) revert ValidatorNotFound();
            prev = validatorID;
            uint256 receivedStake = getValidator[validatorID].receivedStake;
            snapshot.receivedStake[validatorID] = receivedStake;
            total += receivedStake;
        }
        snapshot.totalStake = total;
        snapshot.validatorIDs = nextValidatorIDs;
    }

    /// @notice Seals the current epoch (design 7): offline marking, the fee split, the emission draw,
    /// rewards, the snapshot. Every array carries one entry per validator of the epoch's snapshot, in
    /// the snapshot's order; anything else is refused (F9, plan mutant (ii)) rather than read out of
    /// step with the validator it belongs to.
    function sealEpoch(
        uint256[] calldata offlineTimes,
        uint256[] calldata offlineBlocks,
        uint256[] calldata uptimes,
        uint256[] calldata originatedTxsFee
    ) external onlyDriver nonReentrant {
        EpochSnapshot storage snapshot = getEpochSnapshot[currentEpoch()];
        uint256[] memory validatorIDs = snapshot.validatorIDs;
        uint256 n = validatorIDs.length;
        if (offlineTimes.length != n || offlineBlocks.length != n || uptimes.length != n || originatedTxsFee.length != n) {
            revert SealArraysMismatch();
        }
        _sealEpochOffline(snapshot, validatorIDs, offlineTimes, offlineBlocks);
        _sealEpochRewards(snapshot, validatorIDs, uptimes, originatedTxsFee);

        currentSealedEpoch = currentEpoch();
        snapshot.endTime = block.timestamp;
        snapshot.baseRewardPerSecond = _emissionPerSecond();
        snapshot.totalSupply = totalSupply;
        genesisSealed = true;
    }

    // ================================================================ validators and delegators

    function createValidator(bytes calldata pubkey) external payable nonReentrant {
        if (msg.value < _c(P_MIN_SELF_STAKE)) revert InsufficientSelfStake();
        _requirePubkey(pubkey);
        uint256 validatorID = ++lastValidatorID;
        _rawCreateValidator(msg.sender, validatorID, pubkey, OK_STATUS, currentEpoch(), block.timestamp, 0, 0);
        _delegate(msg.sender, validatorID, msg.value);
    }

    /// @notice Rotates the caller's validator key, at most once per epoch. A validator in the set gets
    /// its weight and then the key sent to the node, which applies both at the next seal (2.2 rule 1).
    function updateValidatorPubkey(bytes calldata pubkey) external nonReentrant {
        uint256 validatorID = getValidatorID[msg.sender];
        if (validatorID == 0) revert ValidatorNotFound();
        if (isSlashed(validatorID)) revert ValidatorSlashed();
        _requirePubkey(pubkey);
        if (lastPubkeyUpdateEpoch[validatorID] >= currentEpoch()) revert OnePubkeyUpdatePerEpoch();
        lastPubkeyUpdateEpoch[validatorID] = currentEpoch();
        getValidatorPubkey[validatorID] = pubkey;
        emit UpdatedValidatorPubkey(validatorID, pubkey);
        _syncValidator(validatorID, true);
    }

    /// @notice Brings an OFFLINE validator back (F8). Never after a double-sign or a full withdrawal;
    /// at least one sealed epoch after the deactivation; the self-stake, the delegation ratio and the
    /// concentration cap must all hold again. The epochs it spent outside the set are recorded as a
    /// reward-index gap so that no delegator's stake is frozen by them (D9).
    function reactivateValidator() external nonReentrant {
        uint256 validatorID = getValidatorID[msg.sender];
        if (validatorID == 0) revert ValidatorNotFound();
        Validator storage v = getValidator[validatorID];
        if (v.status != OFFLINE_BIT) revert NotOffline();
        if (currentSealedEpoch < v.deactivatedEpoch) revert TooEarly();
        if (getSelfStake(validatorID) < _c(P_MIN_SELF_STAKE)) revert InsufficientSelfStake();

        _rewardGaps[validatorID].push(RewardGap(v.deactivatedEpoch + 1, currentEpoch(), _rateAt(validatorID, v.deactivatedEpoch)));
        v.status = OK_STATUS;
        v.deactivatedEpoch = 0;
        v.deactivatedTime = 0;
        totalActiveStake += v.receivedStake;
        _checkDelegatedStakeLimit(validatorID);
        _checkConcentration(validatorID);
        emit ChangedValidatorStatus(validatorID, OK_STATUS);
        _syncValidator(validatorID, true);
    }

    function delegate(uint256 toValidatorID) external payable nonReentrant {
        _delegate(msg.sender, toValidatorID, msg.value);
    }

    function undelegate(uint256 toValidatorID, uint256 wrID, uint256 amount) external nonReentrant {
        address delegator = msg.sender;
        _stashRewards(delegator, toValidatorID);
        if (amount == 0) revert ZeroAmount();
        if (amount > getUnlockedStake(delegator, toValidatorID)) revert NotEnoughUnlockedStake();
        WithdrawalRequest storage wr = getWithdrawalRequest[delegator][toValidatorID][wrID];
        if (wr.amount != 0) revert RequestExists();

        _rawUndelegate(delegator, toValidatorID, amount);
        wr.amount = amount;
        wr.epoch = currentEpoch();
        wr.time = block.timestamp;
        _syncValidator(toValidatorID, false);
        emit Undelegated(delegator, toValidatorID, wrID, amount);
    }

    /// @notice Pays out a withdrawal request once both withdrawal periods have passed (read now, as in
    /// v1). A delegation to a double-signer is charged its confiscation here, less any refund the
    /// Timelock granted; the charge is routed and counted, never destroyed (F5).
    function withdraw(uint256 toValidatorID, uint256 wrID) external nonReentrant {
        address delegator = msg.sender;
        WithdrawalRequest memory request = getWithdrawalRequest[delegator][toValidatorID][wrID];
        if (request.epoch == 0) revert RequestNotFound();
        Validator storage v = getValidator[toValidatorID];
        uint256 requestTime = request.time;
        uint256 requestEpoch = request.epoch;
        if (v.deactivatedTime != 0 && v.deactivatedTime < requestTime) {
            requestTime = v.deactivatedTime;
            requestEpoch = v.deactivatedEpoch;
        }
        if (block.timestamp < requestTime + _c(P_WITHDRAWAL_PERIOD_TIME)) revert NotEnoughTimePassed();
        if (currentEpoch() < requestEpoch + _c(P_WITHDRAWAL_PERIOD_EPOCHS)) revert NotEnoughEpochsPassed();
        delete getWithdrawalRequest[delegator][toValidatorID][wrID];

        uint256 amount = request.amount;
        uint256 penalty = 0;
        if (isSlashed(toValidatorID) && delegator != v.auth) {
            // ceil(amount x ratio x (1 - refund)): rounding up stops a dust split from escaping it
            uint256 u = Decimal.unit();
            penalty = _ceilDiv(amount * _c(P_DOUBLE_SIGN_DELEGATION_SLASH_RATIO) * (u - slashingRefundRatio[toValidatorID]), u * u);
            if (penalty > amount) {
                penalty = amount;
            }
            if (penalty != 0) {
                totalSlashedStake += penalty;
                _routeConfiscation(toValidatorID, delegator, penalty);
            }
        }
        _pay(delegator, amount - penalty);
        emit Withdrawn(delegator, toValidatorID, wrID, amount);
    }

    function claimRewards(uint256 toValidatorID) external nonReentrant {
        address delegator = msg.sender;
        Rewards memory rewards = _claimRewards(delegator, toValidatorID);
        _pay(delegator, rewards.lockupExtraReward + rewards.lockupBaseReward + rewards.unlockedReward);
        emit ClaimedRewards(delegator, toValidatorID, rewards.lockupExtraReward, rewards.lockupBaseReward, rewards.unlockedReward);
    }

    function restakeRewards(uint256 toValidatorID) external nonReentrant {
        address delegator = msg.sender;
        Rewards memory rewards = _claimRewards(delegator, toValidatorID);
        uint256 lockupReward = rewards.lockupExtraReward + rewards.lockupBaseReward;
        _delegate(delegator, toValidatorID, lockupReward + rewards.unlockedReward);
        getLockupInfo[delegator][toValidatorID].lockedStake += lockupReward;
        emit RestakedRewards(delegator, toValidatorID, rewards.lockupExtraReward, rewards.lockupBaseReward, rewards.unlockedReward);
    }

    function stashRewards(address delegator, uint256 toValidatorID) external nonReentrant {
        if (!_stashRewards(delegator, toValidatorID)) revert NothingToStash();
    }

    function lockStake(uint256 toValidatorID, uint256 lockupDuration, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (isLockedUp(msg.sender, toValidatorID)) revert AlreadyLockedUp();
        _lockStake(msg.sender, toValidatorID, lockupDuration, amount);
    }

    function relockStake(uint256 toValidatorID, uint256 lockupDuration, uint256 amount) external nonReentrant {
        _lockStake(msg.sender, toValidatorID, lockupDuration, amount);
    }

    /// @notice Unlocks `amount` of locked stake early. The penalty is LINEAR in the amount: the
    /// unlocked fraction of the stashed lockup rewards, extra in full and base at half, applied ONCE
    /// (F6). Unlocking in 100 chunks costs what unlocking at once costs; applying the fraction a
    /// second time (v1's bug, plan mutant (i)) makes 100 chunks cost 5.2% of it. The penalty leaves
    /// the stake and is paid into the RewardsReserve, never stranded here.
    function unlockStake(uint256 toValidatorID, uint256 amount) external nonReentrant returns (uint256) {
        address delegator = msg.sender;
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        if (amount == 0) revert ZeroAmount();
        if (!isLockedUp(delegator, toValidatorID)) revert NotLockedUp();
        if (amount > ld.lockedStake) revert NotEnoughLockedStake();

        _stashRewards(delegator, toValidatorID);

        Rewards storage stashed = getStashedLockupRewards[delegator][toValidatorID];
        uint256 lockedStake = ld.lockedStake;
        uint256 extraShare = (stashed.lockupExtraReward * amount) / lockedStake;
        uint256 baseShare = (stashed.lockupBaseReward * amount) / lockedStake;
        stashed.lockupExtraReward -= extraShare;
        stashed.lockupBaseReward -= baseShare;
        uint256 penalty = extraShare + baseShare / 2;
        if (penalty > amount) {
            penalty = amount;
        }

        ld.lockedStake = lockedStake - amount;
        if (penalty != 0) {
            _rawUndelegate(delegator, toValidatorID, penalty);
            _payReserve(penalty);
            _syncValidator(toValidatorID, false);
        }
        emit UnlockedStake(delegator, toValidatorID, amount, penalty);
        return penalty;
    }

    // ================================================================ owner (the Timelock)

    /// @notice Refunds part of a slashed validator's delegation confiscations (7 d class). Bounded by
    /// the ConstantsManager's maxSlashingRefundRatio (D6: 50%).
    function updateSlashingRefundRatio(uint256 validatorID, uint256 refundRatio) external onlyOwner {
        if (!isSlashed(validatorID)) revert ValidatorNotSlashed();
        if (refundRatio > _c(P_MAX_SLASHING_REFUND_RATIO)) revert RefundRatioTooHigh();
        slashingRefundRatio[validatorID] = refundRatio;
        emit UpdatedSlashingRefundRatio(validatorID, refundRatio);
    }

    function updateConsts(address addr) external onlyOwner {
        consts = IConstantsManager(_contract(addr));
        emit UpdatedModule("consts", addr);
    }

    function updateRewardsReserve(address addr) external onlyOwner {
        rewardsReserve = IRewardsReserve(_contract(addr));
        emit UpdatedModule("rewardsReserve", addr);
    }

    function updateTreasury(address addr) external onlyOwner {
        treasury = _contract(addr);
        emit UpdatedModule("treasury", addr);
    }

    function updateInsurancePool(address addr) external onlyOwner {
        insurancePool = _contract(addr);
        emit UpdatedModule("insurancePool", addr);
    }

    function updateHostBonds(address addr) external onlyOwner {
        hostBonds = IHostBonds(_contract(addr));
        emit UpdatedModule("hostBonds", addr);
    }

    function addExcludedFromCirculation(address vault) external onlyOwner {
        _contract(vault);
        for (uint256 i = 0; i < excludedFromCirculation.length; i++) {
            if (excludedFromCirculation[i] == vault) revert AlreadyExcluded();
        }
        excludedFromCirculation.push(vault);
        emit ExcludedFromCirculation(vault);
    }

    /// @notice Takes a vault back out of the list, so a wrong or retired entry is never permanent
    /// (the list is a rule like any other: the Timelock moves it both ways).
    function removeExcludedFromCirculation(address vault) external onlyOwner {
        uint256 n = excludedFromCirculation.length;
        for (uint256 i = 0; i < n; i++) {
            if (excludedFromCirculation[i] == vault) {
                excludedFromCirculation[i] = excludedFromCirculation[n - 1];
                excludedFromCirculation.pop();
                emit IncludedInCirculation(vault);
                return;
            }
        }
        revert NotExcluded();
    }

    // ================================================================ views

    function version() external pure returns (bytes3) {
        return "200";
    }

    function currentEpoch() public view returns (uint256) {
        return currentSealedEpoch + 1;
    }

    function constsAddress() external view returns (address) {
        return address(consts);
    }

    /// @notice Every native NEC outside the RewardsReserve and the excluded vaults (ECO-01a; design
    /// 6.1): totalSupply - reserve balance - sum of the excluded vaults' balances. An entry that is
    /// the reserve itself is counted once, so re-pointing the reserve at a listed vault cannot
    /// subtract the same NEC twice.
    function circulatingSupply() external view returns (uint256 s) {
        s = totalSupply;
        address reserve = address(rewardsReserve);
        uint256 locked = reserve.balance;
        for (uint256 i = 0; i < excludedFromCirculation.length; i++) {
            address vault = excludedFromCirculation[i];
            if (vault != reserve) {
                locked += vault.balance;
            }
        }
        return s > locked ? s - locked : 0;
    }

    function excludedFromCirculationCount() external view returns (uint256) {
        return excludedFromCirculation.length;
    }

    function getEpochValidatorIDs(uint256 epoch) external view returns (uint256[] memory) {
        return getEpochSnapshot[epoch].validatorIDs;
    }

    function getEpochReceivedStake(uint256 epoch, uint256 validatorID) external view returns (uint256) {
        return getEpochSnapshot[epoch].receivedStake[validatorID];
    }

    function getEpochAccumulatedRewardPerToken(uint256 epoch, uint256 validatorID) external view returns (uint256) {
        return getEpochSnapshot[epoch].accumulatedRewardPerToken[validatorID];
    }

    function getEpochAccumulatedUptime(uint256 epoch, uint256 validatorID) external view returns (uint256) {
        return getEpochSnapshot[epoch].accumulatedUptime[validatorID];
    }

    function getEpochAccumulatedOriginatedTxsFee(uint256 epoch, uint256 validatorID) external view returns (uint256) {
        return getEpochSnapshot[epoch].accumulatedOriginatedTxsFee[validatorID];
    }

    function getEpochOfflineTime(uint256 epoch, uint256 validatorID) external view returns (uint256) {
        return getEpochSnapshot[epoch].offlineTime[validatorID];
    }

    function getEpochOfflineBlocks(uint256 epoch, uint256 validatorID) external view returns (uint256) {
        return getEpochSnapshot[epoch].offlineBlocks[validatorID];
    }

    /// @notice The reward gaps recorded for a validator (D9): [fromEpoch, toEpoch] and the reward index
    /// carried across them.
    function getRewardGaps(uint256 validatorID) external view returns (RewardGap[] memory) {
        return _rewardGaps[validatorID];
    }

    function rewardsStash(address delegator, uint256 validatorID) external view returns (uint256) {
        Rewards memory stash = _rewardsStash[delegator][validatorID];
        return stash.lockupBaseReward + stash.lockupExtraReward + stash.unlockedReward;
    }

    function pendingRewards(address delegator, uint256 toValidatorID) external view returns (uint256) {
        Rewards memory reward = _sum(_rewardsStash[delegator][toValidatorID], _newRewards(delegator, toValidatorID));
        return reward.unlockedReward + reward.lockupBaseReward + reward.lockupExtraReward;
    }

    function getSelfStake(uint256 validatorID) public view returns (uint256) {
        return getStake[getValidator[validatorID].auth][validatorID];
    }

    function isSlashed(uint256 validatorID) public view returns (bool) {
        return getValidator[validatorID].status & CHEATER_MASK != 0;
    }

    function isLockedUp(address delegator, uint256 toValidatorID) public view returns (bool) {
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        return ld.endTime != 0 && ld.lockedStake != 0 && block.timestamp <= ld.endTime;
    }

    function getLockedStake(address delegator, uint256 toValidatorID) public view returns (uint256) {
        if (!isLockedUp(delegator, toValidatorID)) {
            return 0;
        }
        return getLockupInfo[delegator][toValidatorID].lockedStake;
    }

    function getUnlockedStake(address delegator, uint256 toValidatorID) public view returns (uint256) {
        return getStake[delegator][toValidatorID] - getLockedStake(delegator, toValidatorID);
    }

    // The v1 constants, kept as views over the ConstantsManager so callers of the v1 ABI keep working.

    function minSelfStake() external view returns (uint256) {
        return _c(P_MIN_SELF_STAKE);
    }

    function maxDelegatedRatio() external view returns (uint256) {
        return _c(P_MAX_DELEGATED_RATIO);
    }

    function validatorCommission() external view returns (uint256) {
        return _c(P_VALIDATOR_COMMISSION);
    }

    function unlockedRewardRatio() external view returns (uint256) {
        return _c(P_UNLOCKED_REWARD_RATIO);
    }

    function minLockupDuration() external view returns (uint256) {
        return _c(P_MIN_LOCKUP_DURATION);
    }

    function maxLockupDuration() external view returns (uint256) {
        return _c(P_MAX_LOCKUP_DURATION);
    }

    function withdrawalPeriodEpochs() external view returns (uint256) {
        return _c(P_WITHDRAWAL_PERIOD_EPOCHS);
    }

    function withdrawalPeriodTime() external view returns (uint256) {
        return _c(P_WITHDRAWAL_PERIOD_TIME);
    }

    /// @notice v1's getter, now the emission stub's per-second budget.
    function baseRewardPerSecond() external view returns (uint256) {
        return _emissionPerSecond();
    }

    function offlinePenaltyThreshold() external view returns (uint256 blocksNum, uint256 time) {
        return (_c(P_OFFLINE_PENALTY_THRESHOLD_BLOCKS_NUM), _c(P_OFFLINE_PENALTY_THRESHOLD_TIME));
    }

    // ================================================================ internals: validators and stake

    function _requirePubkey(bytes calldata pubkey) internal pure {
        if (pubkey.length != PUBKEY_LENGTH || pubkey[0] != PUBKEY_TYPE) revert MalformedPubkey();
    }

    function _contract(address addr) internal view returns (address) {
        if (addr.code.length == 0) revert NotContract();
        return addr;
    }

    function _validatorExists(uint256 validatorID) internal view returns (bool) {
        return getValidator[validatorID].createdTime != 0;
    }

    function _rawCreateValidator(
        address auth,
        uint256 validatorID,
        bytes calldata pubkey,
        uint256 status,
        uint256 createdEpoch,
        uint256 createdTime,
        uint256 deactivatedEpoch,
        uint256 deactivatedTime
    ) internal {
        if (getValidatorID[auth] != 0) revert ValidatorExists();
        getValidatorID[auth] = validatorID;
        Validator storage v = getValidator[validatorID];
        v.status = status;
        v.createdEpoch = createdEpoch;
        v.createdTime = createdTime;
        v.deactivatedTime = deactivatedTime;
        v.deactivatedEpoch = deactivatedEpoch;
        v.auth = auth;
        getValidatorPubkey[validatorID] = pubkey;

        emit CreatedValidator(validatorID, auth, createdEpoch, createdTime);
        if (deactivatedEpoch != 0) {
            emit DeactivatedValidator(validatorID, deactivatedEpoch, deactivatedTime);
        }
        if (status != 0) {
            emit ChangedValidatorStatus(validatorID, status);
        }
    }

    /// @dev A stake-increasing action on an active validator: the delegation ratio and the
    /// concentration cap must hold afterwards.
    function _delegate(address delegator, uint256 toValidatorID, uint256 amount) internal {
        if (!_validatorExists(toValidatorID)) revert ValidatorNotFound();
        if (getValidator[toValidatorID].status != OK_STATUS) revert ValidatorNotActive();
        _rawDelegate(delegator, toValidatorID, amount);
        _checkDelegatedStakeLimit(toValidatorID);
        _checkConcentration(toValidatorID);
    }

    function _rawDelegate(address delegator, uint256 toValidatorID, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        _stashRewards(delegator, toValidatorID);
        getStake[delegator][toValidatorID] += amount;
        Validator storage v = getValidator[toValidatorID];
        uint256 origStake = v.receivedStake;
        v.receivedStake = origStake + amount;
        totalStake += amount;
        if (v.status == OK_STATUS) {
            totalActiveStake += amount;
        }
        _syncValidator(toValidatorID, origStake == 0);
        emit Delegated(delegator, toValidatorID, amount);
    }

    /// @dev Removes stake. Only the validator's own address is bound by the self-stake rules, and only
    /// while the validator is active: a delegator can always leave, including a validator whose
    /// self-stake a confiscation took below minSelfStake.
    function _rawUndelegate(address delegator, uint256 toValidatorID, uint256 amount) internal {
        Validator storage v = getValidator[toValidatorID];
        getStake[delegator][toValidatorID] -= amount;
        v.receivedStake -= amount;
        totalStake -= amount;
        if (v.status == OK_STATUS) {
            totalActiveStake -= amount;
        }
        if (delegator == v.auth) {
            uint256 selfStakeAfterwards = getStake[delegator][toValidatorID];
            if (selfStakeAfterwards == 0) {
                _setValidatorDeactivated(toValidatorID, WITHDRAWN_BIT);
            } else if (v.status == OK_STATUS) {
                if (selfStakeAfterwards < _c(P_MIN_SELF_STAKE)) revert InsufficientSelfStake();
                _checkDelegatedStakeLimit(toValidatorID);
            }
        }
    }

    function _checkDelegatedStakeLimit(uint256 validatorID) internal view {
        if (getValidator[validatorID].receivedStake > (getSelfStake(validatorID) * _c(P_MAX_DELEGATED_RATIO)) / Decimal.unit()) {
            revert DelegationLimitExceeded();
        }
    }

    /// @dev The concentration cap (DECIDE-24, design D3): after a stake-increasing action a validator's
    /// weight may not exceed maxValidatorWeightShare of the total ACTIVE stake. A validator at or below
    /// minSelfStake is exempt, so a bare minimum validator can always join.
    function _checkConcentration(uint256 validatorID) internal view {
        uint256 weight = getValidator[validatorID].receivedStake;
        if (weight <= _c(P_MIN_SELF_STAKE)) {
            return;
        }
        if (weight * Decimal.unit() > _c(P_MAX_VALIDATOR_WEIGHT_SHARE) * totalActiveStake) revert ConcentrationCapExceeded();
    }

    function _setValidatorDeactivated(uint256 validatorID, uint256 status) internal {
        Validator storage v = getValidator[validatorID];
        if (v.status == OK_STATUS && status != OK_STATUS) {
            totalActiveStake -= v.receivedStake;
        }
        // status as a number is proportional to severity
        if (status > v.status) {
            v.status = status;
            if (v.deactivatedEpoch == 0) {
                v.deactivatedEpoch = currentEpoch();
                v.deactivatedTime = block.timestamp;
                emit DeactivatedValidator(validatorID, v.deactivatedEpoch, v.deactivatedTime);
            }
            emit ChangedValidatorStatus(validatorID, status);
        }
    }

    /// @dev Tells the node a validator's weight (0 unless active) and, when asked and the weight is
    /// not 0, its pubkey -- in that order (design 2.2 rule 1). Internal: v1 exposed it publicly (F9).
    function _syncValidator(uint256 validatorID, bool syncPubkey) internal {
        if (!_validatorExists(validatorID)) revert ValidatorNotFound();
        uint256 weight = getValidator[validatorID].receivedStake;
        if (getValidator[validatorID].status != OK_STATUS) {
            weight = 0;
        }
        node.updateValidatorWeight(validatorID, weight);
        if (syncPubkey && weight != 0) {
            node.updateValidatorPubkey(validatorID, getValidatorPubkey[validatorID]);
        }
    }

    /// @dev A double-sign: doubleSignSelfSlashRatio of the self-stake leaves the stake now and is
    /// routed (D6). A lockup larger than what is left shrinks to it.
    function _slashSelfStake(uint256 validatorID) internal {
        address auth = getValidator[validatorID].auth;
        _stashRewards(auth, validatorID);
        uint256 selfStake = getStake[auth][validatorID];
        uint256 amount = (selfStake * _c(P_DOUBLE_SIGN_SELF_SLASH_RATIO)) / Decimal.unit();
        if (amount == 0) {
            return;
        }
        uint256 left = selfStake - amount;
        getStake[auth][validatorID] = left;
        getValidator[validatorID].receivedStake -= amount;
        totalStake -= amount;
        LockedDelegation storage ld = getLockupInfo[auth][validatorID];
        if (ld.lockedStake > left) {
            ld.lockedStake = left;
        }
        totalSlashedStake += amount;
        _routeConfiscation(validatorID, auth, amount);
    }

    function _lockStake(address delegator, uint256 toValidatorID, uint256 lockupDuration, uint256 amount) internal {
        if (amount > getUnlockedStake(delegator, toValidatorID)) revert NotEnoughUnlockedStake();
        if (getValidator[toValidatorID].status != OK_STATUS) revert ValidatorNotActive();
        if (lockupDuration < _c(P_MIN_LOCKUP_DURATION) || lockupDuration > _c(P_MAX_LOCKUP_DURATION)) revert IncorrectDuration();
        uint256 endTime = block.timestamp + lockupDuration;
        address validatorAddr = getValidator[toValidatorID].auth;
        if (delegator != validatorAddr) {
            if (getLockupInfo[validatorAddr][toValidatorID].endTime < endTime) revert ValidatorLockupEndsEarlier();
        }
        _stashRewards(delegator, toValidatorID);
        // checked after _stashRewards, which has erased a previous lockup that has already ended
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        if (lockupDuration < ld.duration) revert LockupDurationDecreases();
        ld.lockedStake += amount;
        ld.fromEpoch = currentEpoch();
        ld.endTime = endTime;
        ld.duration = lockupDuration;
        emit LockedUpStake(delegator, toValidatorID, lockupDuration, amount);
    }

    // ================================================================ internals: money

    /// @dev The only mint (F1): new native NEC, and totalSupply moves with it.
    function _mint(uint256 amount) internal {
        node.incBalance(address(this), amount);
        totalSupply += amount;
        totalMinted += amount;
    }

    function _pay(address to, uint256 amount) internal {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    /// @dev Pays the RewardsReserve, and never reverts: the node-facing paths call it, and a revert
    /// there would lose an epoch's accounting or leave a double-signer in the set. Without a reserve
    /// (an install before initializeV2), or if it refuses, the NEC stays in the SFC: still inside
    /// totalSupply, never destroyed.
    function _payReserve(uint256 amount) internal returns (bool ok) {
        if (amount != 0 && address(rewardsReserve) != address(0)) {
            (ok, ) = address(rewardsReserve).call{value: amount}(abi.encodeCall(IRewardsReserve.deposit, ()));
        }
    }

    /// @dev Splits a confiscation between the RewardsReserve and the InsurancePool
    /// (confiscationReserveShare; D6: 50 / 50). An insurance pool that is unset or refuses the payment
    /// sends its part to the reserve instead. Nothing is destroyed.
    function _routeConfiscation(uint256 validatorID, address from, uint256 amount) internal {
        uint256 toReserve = (amount * _c(P_CONFISCATION_RESERVE_SHARE)) / Decimal.unit();
        uint256 toInsurance = amount - toReserve;
        if (toInsurance != 0) {
            bool ok = false;
            if (insurancePool != address(0)) {
                (ok, ) = payable(insurancePool).call{value: toInsurance}("");
            }
            if (!ok) {
                toReserve += toInsurance;
                toInsurance = 0;
            }
        }
        _payReserve(toReserve);
        emit Confiscated(validatorID, from, amount, toReserve, toInsurance);
    }

    /// @dev One ConstantsManager parameter, read now (F4).
    function _c(uint8 p) internal view returns (uint256) {
        return consts.value(p);
    }

    function _emissionPerSecond() internal view returns (uint256) {
        return address(consts) == address(0) ? 0 : _c(P_EMISSION_PER_SECOND);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ================================================================ internals: rewards

    function _claimRewards(address delegator, uint256 toValidatorID) internal returns (Rewards memory rewards) {
        _stashRewards(delegator, toValidatorID);
        rewards = _rewardsStash[delegator][toValidatorID];
        if (rewards.unlockedReward + rewards.lockupBaseReward + rewards.lockupExtraReward == 0) revert ZeroRewards();
        delete _rewardsStash[delegator][toValidatorID];
    }

    function _stashRewards(address delegator, uint256 toValidatorID) internal returns (bool updated) {
        Rewards memory nonStashedReward = _newRewards(delegator, toValidatorID);
        stashedRewardsUntilEpoch[delegator][toValidatorID] = _highestPayableEpoch(toValidatorID);
        _rewardsStash[delegator][toValidatorID] = _sum(_rewardsStash[delegator][toValidatorID], nonStashedReward);
        getStashedLockupRewards[delegator][toValidatorID] = _sum(getStashedLockupRewards[delegator][toValidatorID], nonStashedReward);
        if (!isLockedUp(delegator, toValidatorID)) {
            delete getLockupInfo[delegator][toValidatorID];
            delete getStashedLockupRewards[delegator][toValidatorID];
        }
        return nonStashedReward.lockupBaseReward != 0 || nonStashedReward.lockupExtraReward != 0 || nonStashedReward.unlockedReward != 0;
    }

    function _highestPayableEpoch(uint256 validatorID) internal view returns (uint256) {
        uint256 d = getValidator[validatorID].deactivatedEpoch;
        if (d != 0 && d < currentSealedEpoch) {
            return d;
        }
        return currentSealedEpoch;
    }

    function _isLockedUpAtEpoch(address delegator, uint256 toValidatorID, uint256 epoch) internal view returns (bool) {
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        return ld.fromEpoch <= epoch && getEpochSnapshot[epoch].endTime <= ld.endTime;
    }

    /// @dev The highest epoch at which the lockup was in force (binary search), as in v1.
    function _highestLockupEpoch(address delegator, uint256 validatorID) internal view returns (uint256) {
        uint256 l = getLockupInfo[delegator][validatorID].fromEpoch;
        uint256 r = currentSealedEpoch;
        if (_isLockedUpAtEpoch(delegator, validatorID, r)) {
            return r;
        }
        if (!_isLockedUpAtEpoch(delegator, validatorID, l) || l > r) {
            return 0;
        }
        while (l < r) {
            uint256 m = (l + r) / 2;
            if (_isLockedUpAtEpoch(delegator, validatorID, m)) {
                l = m + 1;
            } else {
                r = m;
            }
        }
        return r == 0 ? 0 : r - 1;
    }

    function _scaleLockupReward(uint256 fullReward, uint256 lockupDuration) internal view returns (Rewards memory reward) {
        uint256 unlockedRatio = _c(P_UNLOCKED_REWARD_RATIO);
        if (lockupDuration != 0) {
            uint256 lockupExtraRatio = ((Decimal.unit() - unlockedRatio) * lockupDuration) / _c(P_MAX_LOCKUP_DURATION);
            uint256 totalScaledReward = (fullReward * (unlockedRatio + lockupExtraRatio)) / Decimal.unit();
            reward.lockupBaseReward = (fullReward * unlockedRatio) / Decimal.unit();
            reward.lockupExtraReward = totalScaledReward - reward.lockupBaseReward;
        } else {
            reward.unlockedReward = (fullReward * unlockedRatio) / Decimal.unit();
        }
    }

    function _sum(Rewards memory a, Rewards memory b) internal pure returns (Rewards memory) {
        return Rewards(a.lockupExtraReward + b.lockupExtraReward, a.lockupBaseReward + b.lockupBaseReward, a.unlockedReward + b.unlockedReward);
    }

    function _newRewards(address delegator, uint256 toValidatorID) internal view returns (Rewards memory) {
        uint256 stashedUntil = stashedRewardsUntilEpoch[delegator][toValidatorID];
        uint256 payableUntil = _highestPayableEpoch(toValidatorID);
        uint256 lockedUntil = _highestLockupEpoch(delegator, toValidatorID);
        if (lockedUntil > payableUntil) {
            lockedUntil = payableUntil;
        }
        if (lockedUntil < stashedUntil) {
            lockedUntil = stashedUntil;
        }
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        uint256 wholeStake = getStake[delegator][toValidatorID];
        uint256 unlockedStake = wholeStake - ld.lockedStake;
        // locked stake during lockup epochs, unlocked stake during lockup epochs, the whole stake after
        Rewards memory plReward = _scaleLockupReward(_newRewardsOf(ld.lockedStake, toValidatorID, stashedUntil, lockedUntil), ld.duration);
        Rewards memory puReward = _scaleLockupReward(_newRewardsOf(unlockedStake, toValidatorID, stashedUntil, lockedUntil), 0);
        Rewards memory wuReward = _scaleLockupReward(_newRewardsOf(wholeStake, toValidatorID, lockedUntil, payableUntil), 0);
        return _sum(_sum(plReward, puReward), wuReward);
    }

    function _newRewardsOf(uint256 stakeAmount, uint256 toValidatorID, uint256 fromEpoch, uint256 toEpoch) internal view returns (uint256) {
        if (fromEpoch >= toEpoch || stakeAmount == 0) {
            return 0;
        }
        uint256 stashedRate = _rateAt(toValidatorID, fromEpoch);
        uint256 currentRate = _rateAt(toValidatorID, toEpoch);
        if (currentRate < stashedRate) revert RewardRateUnderflow();
        return ((currentRate - stashedRate) * stakeAmount) / Decimal.unit();
    }

    /// @dev The validator's reward index at `epoch`, carried across its reward gaps (D9). A validator
    /// is absent from the snapshots of the epochs it spent deactivated, which read as 0; inside a
    /// recorded gap the index is the one it left with, so a stash, lockup end or payable epoch falling
    /// in the gap neither underflows nor pays anything for it.
    function _rateAt(uint256 validatorID, uint256 epoch) internal view returns (uint256) {
        uint256 rate = getEpochSnapshot[epoch].accumulatedRewardPerToken[validatorID];
        if (rate != 0) {
            return rate;
        }
        RewardGap[] storage gaps = _rewardGaps[validatorID];
        for (uint256 i = gaps.length; i > 0; i--) {
            RewardGap storage g = gaps[i - 1];
            if (epoch > g.toEpoch) {
                break;
            }
            if (epoch >= g.fromEpoch) {
                return g.accumulatedRewardPerToken;
            }
        }
        return 0;
    }

    // ================================================================ internals: sealing

    function _sealEpochOffline(
        EpochSnapshot storage snapshot,
        uint256[] memory validatorIDs,
        uint256[] calldata offlineTimes,
        uint256[] calldata offlineBlocks
    ) internal {
        uint256 blocksNum = 0;
        uint256 time = 0;
        if (address(consts) != address(0)) {
            (blocksNum, time) = (_c(P_OFFLINE_PENALTY_THRESHOLD_BLOCKS_NUM), _c(P_OFFLINE_PENALTY_THRESHOLD_TIME));
        }
        for (uint256 i = 0; i < validatorIDs.length; i++) {
            uint256 id = validatorIDs[i];
            // not confiscated: an OFFLINE validator comes back with reactivateValidator (design 8)
            if (blocksNum != 0 && offlineBlocks[i] > blocksNum && offlineTimes[i] >= time) {
                _setValidatorDeactivated(id, OFFLINE_BIT);
                _syncValidator(id, false);
            }
            snapshot.offlineTime[id] = offlineTimes[i];
            snapshot.offlineBlocks[id] = offlineBlocks[i];
        }
    }

    struct SealCtx {
        uint256[] baseRewardWeights;
        uint256[] txRewardWeights;
        uint256 totalBaseRewardWeight;
        uint256 totalTxRewardWeight;
        uint256 prevEpoch;
        uint256 epochDuration;
        uint256 epochFee;
        uint256 basePool; // shared by base weight: stake x uptime^2
        uint256 txPool; // shared by tx weight: the validators' fee share and the utilisation track
    }

    function _sealEpochRewards(
        EpochSnapshot storage snapshot,
        uint256[] memory validatorIDs,
        uint256[] memory uptimes,
        uint256[] memory accumulatedOriginatedTxsFee
    ) internal {
        SealCtx memory ctx = SealCtx(new uint256[](validatorIDs.length), new uint256[](validatorIDs.length), 0, 0, currentEpoch() - 1, 1, 0, 0, 0);
        EpochSnapshot storage prevSnapshot = getEpochSnapshot[ctx.prevEpoch];
        if (block.timestamp > prevSnapshot.endTime) {
            ctx.epochDuration = block.timestamp - prevSnapshot.endTime;
        }
        for (uint256 i = 0; i < validatorIDs.length; i++) {
            uint256 prevFee = prevSnapshot.accumulatedOriginatedTxsFee[validatorIDs[i]];
            uint256 fee = accumulatedOriginatedTxsFee[i] > prevFee ? accumulatedOriginatedTxsFee[i] - prevFee : 0;
            _weigh(ctx, i, snapshot.receivedStake[validatorIDs[i]], fee, uptimes[i]);
        }

        _splitFees(ctx);
        _drawEmission(ctx);

        for (uint256 i = 0; i < validatorIDs.length; i++) {
            uint256 id = validatorIDs[i];
            _creditValidator(snapshot, id, _rawReward(ctx, i), ctx.prevEpoch);
            snapshot.accumulatedOriginatedTxsFee[id] = accumulatedOriginatedTxsFee[i];
            snapshot.accumulatedUptime[id] = prevSnapshot.accumulatedUptime[id] + uptimes[i];
        }

        snapshot.epochFee = ctx.epochFee;
        snapshot.totalBaseRewardWeight = ctx.totalBaseRewardWeight;
        snapshot.totalTxRewardWeight = ctx.totalTxRewardWeight;
    }

    function _rawReward(SealCtx memory ctx, uint256 i) internal pure returns (uint256 rawReward) {
        if (ctx.baseRewardWeights[i] != 0) {
            rawReward = (ctx.basePool * ctx.baseRewardWeights[i]) / ctx.totalBaseRewardWeight;
        }
        if (ctx.txRewardWeights[i] != 0) {
            rawReward += (ctx.txPool * ctx.txRewardWeights[i]) / ctx.totalTxRewardWeight;
        }
    }

    /// @dev A validator's two reward weights: txRewardWeight = originatedTxsFee x uptime, roughly
    /// stake x uptime^2; baseRewardWeight = stake x uptime^2 (as v1).
    function _weigh(SealCtx memory ctx, uint256 i, uint256 stake, uint256 fee, uint256 uptime) internal pure {
        uint256 d = ctx.epochDuration;
        ctx.epochFee += fee;
        ctx.txRewardWeights[i] = (fee * uptime) / d;
        ctx.totalTxRewardWeight += ctx.txRewardWeights[i];
        ctx.baseRewardWeights[i] = (((stake * uptime) / d) * uptime) / d;
        ctx.totalBaseRewardWeight += ctx.baseRewardWeights[i];
    }

    /// @dev Design 7 step 2 (F3). The node debited the epoch's gas at execution; 100% of it comes back
    /// here with incBalance (the debit and this credit net to zero, so totalSupply does not move), and
    /// is split: the reserve share into the RewardsReserve, the treasury share (sustainability carved
    /// out of it) to the Treasury, the rest to the validators by tx weight. A share whose recipient is
    /// not installed stays with the validators; with no validator weight at all it goes to the reserve.
    function _splitFees(SealCtx memory ctx) internal {
        uint256 fee = ctx.epochFee;
        if (fee == 0) {
            return;
        }
        node.incBalance(address(this), fee);
        uint256 toReserve = 0;
        uint256 toTreasury = 0;
        uint256 sustainability = 0;
        if (address(consts) != address(0)) {
            if (address(rewardsReserve) != address(0)) {
                toReserve = (fee * _c(P_GAS_FEE_RESERVE_SHARE)) / Decimal.unit();
            }
            if (treasury != address(0)) {
                toTreasury = (fee * _c(P_GAS_FEE_TREASURY_SHARE)) / Decimal.unit();
                sustainability = (fee * _c(P_SUSTAINABILITY_SHARE)) / Decimal.unit();
            }
        }
        uint256 toValidators = fee - toReserve - toTreasury;
        if (ctx.totalTxRewardWeight == 0 && ctx.totalBaseRewardWeight == 0 && address(rewardsReserve) != address(0)) {
            toReserve += toValidators;
            toValidators = 0;
        }
        // a recipient that refuses leaves its share with the validators: sealEpoch must not revert
        if (toReserve != 0 && !_payReserve(toReserve)) {
            toValidators += toReserve;
            toReserve = 0;
        }
        if (toTreasury != 0) {
            (bool ok, ) = payable(treasury).call{value: toTreasury}("");
            if (!ok) {
                toValidators += toTreasury;
                toTreasury = 0;
                sustainability = 0;
            }
        }
        ctx.txPool = toValidators;
        emit SplitEpochFees(currentEpoch(), toValidators, toReserve, toTreasury, sustainability);
    }

    /// @dev Design 7 step 3, as the fixed-budget STUB: emissionPerSecond x the epoch's duration, drawn
    /// from the RewardsReserve (supply-neutral) as far as it holds, split into the base track and the
    /// utilisation track (utilisationRewardShare, weighted by originated fees). Nothing is drawn when no
    /// validator has any weight to receive it. ECO-01b replaces this with the glide controller and the
    /// tail mint.
    function _drawEmission(SealCtx memory ctx) internal {
        if (address(rewardsReserve) == address(0) || (ctx.totalBaseRewardWeight == 0 && ctx.totalTxRewardWeight == 0)) {
            _poolsForWeights(ctx);
            return;
        }
        uint256 budget = _emissionPerSecond() * ctx.epochDuration;
        uint256 available = address(rewardsReserve).balance;
        if (budget > available) {
            budget = available;
        }
        // a reserve that refuses the draw pays nothing this epoch; sealEpoch must not revert
        if (budget != 0) {
            try rewardsReserve.draw(budget) {} catch {
                budget = 0;
            }
        }
        if (budget != 0) {
            totalReserveDrawn += budget;
            emit DrewRewards(currentEpoch(), budget);
            uint256 utilisation = (budget * _c(P_UTILISATION_REWARD_SHARE)) / Decimal.unit();
            ctx.basePool += budget - utilisation;
            ctx.txPool += utilisation;
        }
        _poolsForWeights(ctx);
    }

    /// @dev A pool with no weight to share it moves to the other track, so nothing drawn is stranded.
    function _poolsForWeights(SealCtx memory ctx) internal pure {
        if (ctx.totalTxRewardWeight == 0) {
            ctx.basePool += ctx.txPool;
            ctx.txPool = 0;
        }
        if (ctx.totalBaseRewardWeight == 0) {
            ctx.txPool += ctx.basePool;
            ctx.basePool = 0;
        }
    }

    /// @dev v1's commission and reward-per-token accounting for one validator, with the index taken
    /// across reward gaps (D9).
    function _creditValidator(EpochSnapshot storage snapshot, uint256 validatorID, uint256 rawReward, uint256 prevEpoch) internal {
        address validatorAddr = getValidator[validatorID].auth;
        uint256 commissionRewardFull = (rawReward * _c(P_VALIDATOR_COMMISSION)) / Decimal.unit();
        uint256 selfStake = getStake[validatorAddr][validatorID];
        if (selfStake != 0) {
            uint256 lCommissionRewardFull = (commissionRewardFull * getLockedStake(validatorAddr, validatorID)) / selfStake;
            Rewards memory lCommissionReward = _scaleLockupReward(lCommissionRewardFull, getLockupInfo[validatorAddr][validatorID].duration);
            Rewards memory uCommissionReward = _scaleLockupReward(commissionRewardFull - lCommissionRewardFull, 0);
            Rewards memory commission = _sum(lCommissionReward, uCommissionReward);
            _rewardsStash[validatorAddr][validatorID] = _sum(_rewardsStash[validatorAddr][validatorID], commission);
            getStashedLockupRewards[validatorAddr][validatorID] = _sum(getStashedLockupRewards[validatorAddr][validatorID], commission);
        }
        // the latest stake, not the snapshot's, for the accuracy of the distribution (as v1)
        uint256 receivedStake = getValidator[validatorID].receivedStake;
        uint256 rewardPerToken = 0;
        if (receivedStake != 0) {
            rewardPerToken = ((rawReward - commissionRewardFull) * Decimal.unit()) / receivedStake;
        }
        snapshot.accumulatedRewardPerToken[validatorID] = _rateAt(validatorID, prevEpoch) + rewardPerToken;
    }
}
