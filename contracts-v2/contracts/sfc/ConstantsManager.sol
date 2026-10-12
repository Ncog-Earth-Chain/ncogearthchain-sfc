// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "../common/Initializable.sol";
import {Ownable} from "../ownership/Ownable.sol";
import {Decimal} from "../common/Decimal.sol";

/**
 * @title ConstantsManager (SFC v2, GOV-01b / GOV-05b)
 *
 * @dev Every governable staking and fee parameter of SFC v2, each behind two limits no owner can
 * cross:
 *
 *  1. a HARD BOUND, fixed in this code. Widening one is a change to this contract's code, which
 *     is the Timelock's 72 h class (DECIDE-19), never a parameter change.
 *  2. a RATE-OF-CHANGE LIMIT: over any rolling 365-day window a parameter may move by at most 20%
 *     of any value it held inside that window (B5's rule, adopted by DECIDE-15/-19 and GOV-05b).
 *
 * The owner is the Timelock (GOV-02), so every setter below is also queued and delayed (24 h
 * class). Nothing in v1 had any of this: its staking constants were `pure`, and its two owner
 * setters were instant and unbounded (audit SFC-5, SFC-8).
 *
 * NOTHING HERE DESTROYS TOKENS (DECIDE-25). The fee shares that earlier drafts called "burn" are
 * RESERVE shares, paid into the RewardsReserve; there is no burn share and no destroy parameter.
 *
 * ---------------------------------------------------------------------------------------------
 * Parameter table (units: Decimal = 1e18 is 100%; durations in seconds; stake in wei)
 *
 *   parameter                       initial      hard bound             min step*  source
 *   minSelfStake                    1,000,000 NEC [100,000, 10,000,000] -          DECIDE-17
 *   maxDelegatedRatio               16x          [1x, 31x]              -          DECIDE-24
 *   validatorCommission             15%          [0, 50%]               1 pp       DECIDE-24
 *   maxValidatorWeightShare (cap)   10%          [5%, 33%]              -          DECIDE-24
 *   unlockedRewardRatio             30%          [5%, 50%]              -          GOV-05b
 *   minLockupDuration               14 d         [1 d, 30 d]            -          GOV-05b
 *   maxLockupDuration               365 d        [30 d, 1460 d]         -          GOV-05b
 *   withdrawalPeriodEpochs          3            [2, 100]               1 epoch    GOV-05b
 *   withdrawalPeriodTime            7 d          [1 d, 30 d]            -          GOV-05b
 *   gasFeeReserveShare              30%          [10%, 50%]             -          DECIDE-15/25
 *   gasFeeTreasuryShare             20%          [0, 30%]               1 pp       DECIDE-15
 *   gasFeeValidatorShare (derived)  50%          [40%, 90%]             -          DECIDE-15, audit 3.2
 *   hostingReserveShare             10%          [0, 30%]               1 pp       DECIDE-15/25
 *   hostingTreasuryShare            5%           [0, 30%]               1 pp       DECIDE-15
 *   hostingInsuranceShare           5%           [0, 30%]               1 pp       DECIDE-15
 *   hostingHostShare (derived)      80%          [70%, 100%]            -          DECIDE-15
 *   sustainabilityShare             0            [0, 5%], <= treasury   1 pp       DECIDE-15/20
 *   utilisationRewardShare          20%          [0, 50%]               1 pp       GOV-05b (initial = audit 3.4 rec.)
 *   offlinePenaltyThresholdTime     3 d          [1 d, 10 d]            -          audit SFC-8; bound = upstream, OPEN
 *   offlinePenaltyThresholdBlocksNum 1000        [100, 1,000,000]       1 block    audit SFC-8; bound = upstream, OPEN
 *   doubleSignSelfSlashRatio        5%           [1%, 50%]              1 pp       audit 3.5 row 16 (design D6, OPEN)
 *   doubleSignDelegationSlashRatio  1%           [0, 5%]                1 pp       audit 3.5 row 19 (D6; the 5% per-delegator cap is the bound)
 *   confiscationReserveShare        50%          [0, 100%]              1 pp       audit 3.5 row 21 (D6; the rest goes to insurance)
 *   maxSlashingRefundRatio          50%          [0, 50%]               1 pp       audit 3.5 (D6: refunds <= 50%)
 *   emissionPerSecond (glide start) 0.634196 NEC [0, 0.792745 NEC]      0.01 NEC   DECIDE-07/13 year-1 glide; bound = the 2.5%/yr code ceiling on 1e9
 *   emissionFloorRate (glide end)   0.317098 NEC [0, 0.792745 NEC]      0.01 NEC   DECIDE-07 1.0%/yr of 1e9; bound = the same code ceiling
 *   emissionGlideDuration           8 x 365 d    [365 d, 7300 d]        1 d        DECIDE-07 (2.0% -> 1.0% over 8 years, then flat)
 *   tailEmissionRate                1%           [0.25%, 1.5%]          -          DECIDE-07/25 (per year of LIVE supply, once the reserve is empty)
 *   maxApy                          15%          [5%, 30%]              -          DECIDE-13 (the cap while stake is small)
 *   lockupBonusMultiplier           1.5x         [1.0x, 2.0x]           -          DECIDE-13 (redistributes within the budget, never above it)
 *
 * The slashing figures and the emission rate were appended by SFC v2 core (GOV-01b run 12) so that
 * no economic figure of the SFC is a constant in its code: the figures of design D6 and the
 * per-second emission budget are all governable here, inside their bounds, like every other
 * parameter. ECO-01b appended the last five (design 7 step 3) and moved the emission math itself
 * here -- see `epochEmissionBudget` at the end of this contract.
 *
 *   * "min step": the smallest move the rate limit always allows. 20% of 0 is 0, so a parameter
 *     whose hard floor is 0 (the sustainability share starts there) could otherwise never move;
 *     and 20% of 3 epochs rounds to 0 in integers. The floor is a DESIGN CHOICE of this contract,
 *     not a recorded decision; docs/design/sfc-v2.md in the node repository states it as such.
 *
 * Cross-parameter invariants, checked after every change:
 *   gasFeeReserveShare + gasFeeTreasuryShare + gasFeeValidatorShare == 100%
 *   hostingReserveShare + hostingTreasuryShare + hostingInsuranceShare + hostingHostShare == 100%
 *   sustainabilityShare <= gasFeeTreasuryShare  (the sustainability share is carved from treasury)
 *   minLockupDuration <= maxLockupDuration
 * ---------------------------------------------------------------------------------------------
 *
 * THE RATE LIMIT, precisely. For a proposed value v at time now, let W be every value the
 * parameter held at some instant of (now - 365 days, now]: the current value plus, for each change
 * recorded inside the window, the value it replaced. v is accepted only if, for every w in W,
 *
 *     |v - w| <= max(20% of w, minStep)
 *
 * which reduces to  max(W) - step(max(W)) <= v <= min(W) + step(min(W)). Checking every pair
 * against the EARLIER value at the time the later one is set makes the property hold for every pair
 * of values less than 365 days apart, so no sequence of small moves inside a year can add up to more
 * than 20%. The last HISTORY_SLOTS changes of each parameter are kept; a change that would push an
 * in-window record out of the ring is refused ("too many changes in 12 months") rather than allowed
 * to forget it, so the rule fails closed. With the Timelock's 24 h delay in front, eight changes of
 * one parameter inside a year is already far more than the governance process can use.
 *
 * STORAGE LAYOUT (append-only; `npm run verify` checks it against layout/ConstantsManager.json):
 *   slot 0        Initializable (_initialized, _initializing)
 *   slots 1..50   Initializable gap (v1-compatible)
 *   slot 51       Ownable._owner
 *   slots 52..101 Ownable gap (v1-compatible)
 *   slots 102..165 _values[64], indexed by Param; new parameters are appended to the enum
 *   slot 166      _history
 * New state goes after `_history`, and new parameters take the next enum index, never a reused one.
 */
contract ConstantsManager is Initializable, Ownable {
    /// @dev Parameter identifiers. APPEND-ONLY: the index is the storage index into `_values` and
    /// the `param` topic of UpdatedConstant. Never reorder or remove a member.
    enum Param {
        MinSelfStake, //                 0
        MaxDelegatedRatio, //            1
        ValidatorCommission, //          2
        MaxValidatorWeightShare, //      3
        UnlockedRewardRatio, //          4
        MinLockupDuration, //            5
        MaxLockupDuration, //            6
        WithdrawalPeriodEpochs, //       7
        WithdrawalPeriodTime, //         8
        GasFeeReserveShare, //           9
        GasFeeTreasuryShare, //          10
        GasFeeValidatorShare, //         11 (derived: 100% - reserve - treasury)
        HostingReserveShare, //          12
        HostingTreasuryShare, //         13
        HostingInsuranceShare, //        14
        HostingHostShare, //             15 (derived: 100% - reserve - treasury - insurance)
        SustainabilityShare, //          16
        UtilisationRewardShare, //       17
        OfflinePenaltyThresholdTime, //  18
        OfflinePenaltyThresholdBlocksNum, // 19
        DoubleSignSelfSlashRatio, //     20
        DoubleSignDelegationSlashRatio, // 21
        ConfiscationReserveShare, //     22
        MaxSlashingRefundRatio, //       23
        EmissionPerSecond, //            24 (ECO-01b: the GLIDE'S START rate, not a fixed budget)
        EmissionFloorRate, //            25 the glide's end rate
        EmissionGlideDuration, //        26 how long the glide takes to reach it
        TailEmissionRate, //             27 per year of live supply, once the reserve is empty
        MaxApy, //                       28
        LockupBonusMultiplier //         29
    }

    /// @dev One recorded change: when it happened and the value it replaced.
    struct Change {
        uint64 time;
        uint192 previous;
    }

    /// @dev The last HISTORY_SLOTS changes of one parameter, oldest at `head`.
    struct History {
        Change[8] ring;
        uint8 head;
    }

    /// @notice The rate limit's window.
    uint256 public constant RATE_LIMIT_WINDOW = 365 days;

    /// @notice The rate limit: 20% (Decimal).
    uint256 public constant RATE_LIMIT = 0.2e18;

    /// @notice How many changes per parameter the rate limit remembers (the ring size above).
    uint256 public constant HISTORY_SLOTS = 8;

    /// @dev One percentage point (Decimal).
    uint256 private constant PERCENT = 1e16;

    /// @dev The glide's two ends: 2% of 1e9 NEC a year in year 1 and 1% of 1e9 NEC a year at the end
    /// of the glide (DECIDE-07's ratified 2.0% -> 1.0%), per second; and the hard ceiling both are
    /// bounded by, 2.5% of 1e9 NEC a year (the CODE CEILING of design 7 step 3).
    uint256 private constant EMISSION_YEAR1 = 634_195_839_675_291_730; // floor(20,000,000 NEC / 365 d)
    uint256 private constant EMISSION_FLOOR = 317_097_919_837_645_865; // floor(10,000,000 NEC / 365 d)
    uint256 private constant EMISSION_CEILING = 792_744_799_594_114_662; // floor(25,000,000 NEC / 365 d)

    /// @dev One year, the denominator of every annual rate here.
    uint256 private constant YEAR = 365 days;

    /// @notice The CODE CEILING of DECIDE-07: no epoch's emission budget may exceed 2.5% a year of
    /// live supply, whatever the parameters say. It is a constant, not a parameter: widening it is a
    /// change to this contract's code, which is the Timelock's 72 h class (design 4), and it is the
    /// hard upper bound of both glide rates as well (`_spec`).
    uint256 public constant EMISSION_CODE_CEILING = 2.5e16; // 2.5%

    uint256[64] private _values;
    mapping(Param => History) private _history;

    event UpdatedConstant(Param indexed param, uint256 previousValue, uint256 newValue);

    /**
     * @notice Sets the owner (the Timelock) and every parameter to its decided initial value.
     * @dev Runs once. A genesis predeploy of this contract has no constructor, so this is called in
     * the block that installs it (or its storage is written by the genesis builder to the same
     * result, which nodesurface_test.go-style behavioural tests must then prove).
     */
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        _setInitial(Param.MinSelfStake, 1_000_000 ether);
        _setInitial(Param.MaxDelegatedRatio, 16e18);
        _setInitial(Param.ValidatorCommission, 15 * PERCENT);
        _setInitial(Param.MaxValidatorWeightShare, 10 * PERCENT);
        _setInitial(Param.UnlockedRewardRatio, 30 * PERCENT);
        _setInitial(Param.MinLockupDuration, 14 days);
        _setInitial(Param.MaxLockupDuration, 365 days);
        _setInitial(Param.WithdrawalPeriodEpochs, 3);
        _setInitial(Param.WithdrawalPeriodTime, 7 days);
        _setInitial(Param.GasFeeReserveShare, 30 * PERCENT);
        _setInitial(Param.GasFeeTreasuryShare, 20 * PERCENT);
        _setInitial(Param.GasFeeValidatorShare, 50 * PERCENT);
        _setInitial(Param.HostingReserveShare, 10 * PERCENT);
        _setInitial(Param.HostingTreasuryShare, 5 * PERCENT);
        _setInitial(Param.HostingInsuranceShare, 5 * PERCENT);
        _setInitial(Param.HostingHostShare, 80 * PERCENT);
        _setInitial(Param.SustainabilityShare, 0);
        _setInitial(Param.UtilisationRewardShare, 20 * PERCENT);
        _setInitial(Param.OfflinePenaltyThresholdTime, 3 days);
        _setInitial(Param.OfflinePenaltyThresholdBlocksNum, 1000);
        _setInitial(Param.DoubleSignSelfSlashRatio, 5 * PERCENT);
        _setInitial(Param.DoubleSignDelegationSlashRatio, 1 * PERCENT);
        _setInitial(Param.ConfiscationReserveShare, 50 * PERCENT);
        _setInitial(Param.MaxSlashingRefundRatio, 50 * PERCENT);
        _setInitial(Param.EmissionPerSecond, EMISSION_YEAR1);
        _setInitial(Param.EmissionFloorRate, EMISSION_FLOOR);
        _setInitial(Param.EmissionGlideDuration, 8 * YEAR);
        _setInitial(Param.TailEmissionRate, 1 * PERCENT);
        _setInitial(Param.MaxApy, 15 * PERCENT);
        _setInitial(Param.LockupBonusMultiplier, 1.5e18);
        _checkInvariants();
    }

    // ------------------------------------------------------------------ getters

    function minSelfStake() external view returns (uint256) {
        return _values[uint256(Param.MinSelfStake)];
    }

    function maxDelegatedRatio() external view returns (uint256) {
        return _values[uint256(Param.MaxDelegatedRatio)];
    }

    function validatorCommission() external view returns (uint256) {
        return _values[uint256(Param.ValidatorCommission)];
    }

    /// @notice The concentration cap: a validator's total weight (self-stake plus delegations) as a
    /// share of the total active stake that SFC v2 refuses to let any stake-increasing action exceed.
    /// @dev The denominator is total ACTIVE stake, where DECIDE-24 says "10% of total stake". That
    /// is stricter whenever validators are offline, and it waits for the owner's confirmation
    /// (docs/design/sfc-v2.md 9, D3, in the node repository).
    function maxValidatorWeightShare() external view returns (uint256) {
        return _values[uint256(Param.MaxValidatorWeightShare)];
    }

    function unlockedRewardRatio() external view returns (uint256) {
        return _values[uint256(Param.UnlockedRewardRatio)];
    }

    function minLockupDuration() external view returns (uint256) {
        return _values[uint256(Param.MinLockupDuration)];
    }

    function maxLockupDuration() external view returns (uint256) {
        return _values[uint256(Param.MaxLockupDuration)];
    }

    function withdrawalPeriodEpochs() external view returns (uint256) {
        return _values[uint256(Param.WithdrawalPeriodEpochs)];
    }

    function withdrawalPeriodTime() external view returns (uint256) {
        return _values[uint256(Param.WithdrawalPeriodTime)];
    }

    function gasFeeReserveShare() external view returns (uint256) {
        return _values[uint256(Param.GasFeeReserveShare)];
    }

    function gasFeeTreasuryShare() external view returns (uint256) {
        return _values[uint256(Param.GasFeeTreasuryShare)];
    }

    function gasFeeValidatorShare() external view returns (uint256) {
        return _values[uint256(Param.GasFeeValidatorShare)];
    }

    function hostingReserveShare() external view returns (uint256) {
        return _values[uint256(Param.HostingReserveShare)];
    }

    function hostingTreasuryShare() external view returns (uint256) {
        return _values[uint256(Param.HostingTreasuryShare)];
    }

    function hostingInsuranceShare() external view returns (uint256) {
        return _values[uint256(Param.HostingInsuranceShare)];
    }

    function hostingHostShare() external view returns (uint256) {
        return _values[uint256(Param.HostingHostShare)];
    }

    function sustainabilityShare() external view returns (uint256) {
        return _values[uint256(Param.SustainabilityShare)];
    }

    function utilisationRewardShare() external view returns (uint256) {
        return _values[uint256(Param.UtilisationRewardShare)];
    }

    function offlinePenaltyThresholdTime() external view returns (uint256) {
        return _values[uint256(Param.OfflinePenaltyThresholdTime)];
    }

    function offlinePenaltyThresholdBlocksNum() external view returns (uint256) {
        return _values[uint256(Param.OfflinePenaltyThresholdBlocksNum)];
    }

    /// @notice The share of a double-signer's SELF-stake confiscated at fault time (design D6).
    function doubleSignSelfSlashRatio() external view returns (uint256) {
        return _values[uint256(Param.DoubleSignSelfSlashRatio)];
    }

    /// @notice The share of each DELEGATION to a double-signer confiscated when it exits (design D6).
    /// Its hard bound, 5%, is the per-delegator cap.
    function doubleSignDelegationSlashRatio() external view returns (uint256) {
        return _values[uint256(Param.DoubleSignDelegationSlashRatio)];
    }

    /// @notice The share of every confiscation paid into the RewardsReserve; the rest goes to the
    /// InsurancePool. Nothing is destroyed either way (DECIDE-25).
    function confiscationReserveShare() external view returns (uint256) {
        return _values[uint256(Param.ConfiscationReserveShare)];
    }

    /// @notice The highest slashing refund ratio the owner may grant a slashed validator (design D6).
    function maxSlashingRefundRatio() external view returns (uint256) {
        return _values[uint256(Param.MaxSlashingRefundRatio)];
    }

    /// @notice The GLIDE'S START rate, NEC-wei per second: DECIDE-07's year-1 budget, 2% a year of the
    /// fixed 1e9 base. The budget an epoch actually gets is `epochEmissionBudget`, which glides from
    /// here to `emissionFloorRate`; the v1 selector is kept (the SFC's `baseRewardPerSecond()`).
    function emissionPerSecond() external view returns (uint256) {
        return _values[uint256(Param.EmissionPerSecond)];
    }

    /// @notice The GLIDE'S END rate, NEC-wei per second: DECIDE-07's 1% a year of the fixed 1e9 base.
    function emissionFloorRate() external view returns (uint256) {
        return _values[uint256(Param.EmissionFloorRate)];
    }

    /// @notice How long the glide takes to walk from `emissionPerSecond` to `emissionFloorRate`
    /// (DECIDE-07: 8 years, after which it is flat until the reserve empties, ~17.6 years in).
    function emissionGlideDuration() external view returns (uint256) {
        return _values[uint256(Param.EmissionGlideDuration)];
    }

    /// @notice The TAIL rate: once the RewardsReserve is empty, emission is minted at this fraction of
    /// LIVE supply a year (DECIDE-07/-25: the only mechanism that ever moves totalSupply).
    function tailEmissionRate() external view returns (uint256) {
        return _values[uint256(Param.TailEmissionRate)];
    }

    /// @notice The cap on an epoch's emission as an annual yield on total stake (DECIDE-13: 15% while
    /// stake is small, so a tiny validator set cannot be paid the whole glide).
    function maxApy() external view returns (uint256) {
        return _values[uint256(Param.MaxApy)];
    }

    /// @notice The lock multiplier's maximum (DECIDE-13: 1.5x at the longest lockup). It
    /// REDISTRIBUTES the epoch's budget, never raises it: the SFC divides the epoch's reward index by
    /// the lock-weighted stake, so the epoch's total payout is the budget at any lock participation.
    function lockupBonusMultiplier() external view returns (uint256) {
        return _values[uint256(Param.LockupBonusMultiplier)];
    }

    /// @notice Any parameter by identifier.
    function value(Param p) external view returns (uint256) {
        return _values[uint256(p)];
    }

    /// @notice The hard bound and minimum step of a parameter, as enforced.
    function bounds(Param p) external pure returns (uint256 lo, uint256 hi, uint256 minStep) {
        return _spec(p);
    }

    /**
     * @notice What a setter would accept for `p` right now, considering the hard bound and the rate
     * limit (not the cross-parameter invariants), and how many recorded changes are inside the
     * window. For a Timelock proposer: the check is made again, at EXECUTION time.
     */
    function allowedRange(Param p) external view returns (uint256 lo, uint256 hi, uint256 changesInWindow) {
        (uint256 hardLo, uint256 hardHi, uint256 minStep) = _spec(p);
        uint256 current = _values[uint256(p)];
        uint256 rateLo;
        uint256 rateHi;
        (rateLo, rateHi, changesInWindow) = _rateRange(p, current, minStep);
        if (changesInWindow >= HISTORY_SLOTS) {
            return (current, current, changesInWindow);
        }
        lo = rateLo > hardLo ? rateLo : hardLo;
        hi = rateHi < hardHi ? rateHi : hardHi;
    }

    // ------------------------------------------------------------------ setters (owner = Timelock)

    function updateMinSelfStake(uint256 v) external onlyOwner {
        _update(Param.MinSelfStake, v);
    }

    function updateMaxDelegatedRatio(uint256 v) external onlyOwner {
        _update(Param.MaxDelegatedRatio, v);
    }

    function updateValidatorCommission(uint256 v) external onlyOwner {
        _update(Param.ValidatorCommission, v);
    }

    function updateMaxValidatorWeightShare(uint256 v) external onlyOwner {
        _update(Param.MaxValidatorWeightShare, v);
    }

    function updateUnlockedRewardRatio(uint256 v) external onlyOwner {
        _update(Param.UnlockedRewardRatio, v);
    }

    function updateMinLockupDuration(uint256 v) external onlyOwner {
        _update(Param.MinLockupDuration, v);
        _checkInvariants();
    }

    function updateMaxLockupDuration(uint256 v) external onlyOwner {
        _update(Param.MaxLockupDuration, v);
        _checkInvariants();
    }

    function updateWithdrawalPeriodEpochs(uint256 v) external onlyOwner {
        _update(Param.WithdrawalPeriodEpochs, v);
    }

    function updateWithdrawalPeriodTime(uint256 v) external onlyOwner {
        _update(Param.WithdrawalPeriodTime, v);
    }

    /**
     * @notice The epoch gas-fee split. The validator share is what remains and must stay >= 40%.
     * The reserve share is paid into the RewardsReserve; nothing is destroyed (DECIDE-25).
     */
    function updateGasFeeSplit(uint256 reserveShare, uint256 treasuryShare) external onlyOwner {
        _update(Param.GasFeeReserveShare, reserveShare);
        _update(Param.GasFeeTreasuryShare, treasuryShare);
        _update(Param.GasFeeValidatorShare, Decimal.unit() - reserveShare - treasuryShare);
        _checkInvariants();
    }

    /**
     * @notice The hosting-revenue split. The host share is what remains and must stay >= 70%.
     */
    function updateHostingFeeSplit(uint256 reserveShare, uint256 treasuryShare, uint256 insuranceShare) external onlyOwner {
        _update(Param.HostingReserveShare, reserveShare);
        _update(Param.HostingTreasuryShare, treasuryShare);
        _update(Param.HostingInsuranceShare, insuranceShare);
        _update(Param.HostingHostShare, Decimal.unit() - reserveShare - treasuryShare - insuranceShare);
        _checkInvariants();
    }

    /// @notice The sustainability share of fees, carved out of the gas-fee treasury share.
    function updateSustainabilityShare(uint256 v) external onlyOwner {
        _update(Param.SustainabilityShare, v);
        _checkInvariants();
    }

    function updateUtilisationRewardShare(uint256 v) external onlyOwner {
        _update(Param.UtilisationRewardShare, v);
    }

    function updateOfflinePenaltyThresholdTime(uint256 v) external onlyOwner {
        _update(Param.OfflinePenaltyThresholdTime, v);
    }

    function updateOfflinePenaltyThresholdBlocksNum(uint256 v) external onlyOwner {
        _update(Param.OfflinePenaltyThresholdBlocksNum, v);
    }

    function updateDoubleSignSelfSlashRatio(uint256 v) external onlyOwner {
        _update(Param.DoubleSignSelfSlashRatio, v);
    }

    function updateDoubleSignDelegationSlashRatio(uint256 v) external onlyOwner {
        _update(Param.DoubleSignDelegationSlashRatio, v);
    }

    function updateConfiscationReserveShare(uint256 v) external onlyOwner {
        _update(Param.ConfiscationReserveShare, v);
    }

    function updateMaxSlashingRefundRatio(uint256 v) external onlyOwner {
        _update(Param.MaxSlashingRefundRatio, v);
    }

    function updateEmissionPerSecond(uint256 v) external onlyOwner {
        _update(Param.EmissionPerSecond, v);
        _checkInvariants();
    }

    function updateEmissionFloorRate(uint256 v) external onlyOwner {
        _update(Param.EmissionFloorRate, v);
        _checkInvariants();
    }

    function updateEmissionGlideDuration(uint256 v) external onlyOwner {
        _update(Param.EmissionGlideDuration, v);
    }

    function updateTailEmissionRate(uint256 v) external onlyOwner {
        _update(Param.TailEmissionRate, v);
    }

    function updateMaxApy(uint256 v) external onlyOwner {
        _update(Param.MaxApy, v);
    }

    function updateLockupBonusMultiplier(uint256 v) external onlyOwner {
        _update(Param.LockupBonusMultiplier, v);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Hard bound and minimum step per parameter. The single source of every bound above.
    function _spec(Param p) internal pure returns (uint256 lo, uint256 hi, uint256 minStep) {
        if (p == Param.MinSelfStake) return (100_000 ether, 10_000_000 ether, 0);
        if (p == Param.MaxDelegatedRatio) return (1e18, 31e18, 0);
        if (p == Param.ValidatorCommission) return (0, 50 * PERCENT, PERCENT);
        if (p == Param.MaxValidatorWeightShare) return (5 * PERCENT, 33 * PERCENT, 0);
        if (p == Param.UnlockedRewardRatio) return (5 * PERCENT, 50 * PERCENT, 0);
        if (p == Param.MinLockupDuration) return (1 days, 30 days, 0);
        if (p == Param.MaxLockupDuration) return (30 days, 1460 days, 0);
        if (p == Param.WithdrawalPeriodEpochs) return (2, 100, 1);
        if (p == Param.WithdrawalPeriodTime) return (1 days, 30 days, 0);
        if (p == Param.GasFeeReserveShare) return (10 * PERCENT, 50 * PERCENT, 0);
        if (p == Param.GasFeeTreasuryShare) return (0, 30 * PERCENT, PERCENT);
        if (p == Param.GasFeeValidatorShare) return (40 * PERCENT, 90 * PERCENT, 0);
        if (p == Param.HostingReserveShare) return (0, 30 * PERCENT, PERCENT);
        if (p == Param.HostingTreasuryShare) return (0, 30 * PERCENT, PERCENT);
        if (p == Param.HostingInsuranceShare) return (0, 30 * PERCENT, PERCENT);
        if (p == Param.HostingHostShare) return (70 * PERCENT, 100 * PERCENT, 0);
        if (p == Param.SustainabilityShare) return (0, 5 * PERCENT, PERCENT);
        if (p == Param.UtilisationRewardShare) return (0, 50 * PERCENT, PERCENT);
        if (p == Param.OfflinePenaltyThresholdTime) return (1 days, 10 days, 0);
        if (p == Param.OfflinePenaltyThresholdBlocksNum) return (100, 1_000_000, 1);
        if (p == Param.DoubleSignSelfSlashRatio) return (PERCENT, 50 * PERCENT, PERCENT);
        if (p == Param.DoubleSignDelegationSlashRatio) return (0, 5 * PERCENT, PERCENT);
        if (p == Param.ConfiscationReserveShare) return (0, 100 * PERCENT, PERCENT);
        if (p == Param.MaxSlashingRefundRatio) return (0, 50 * PERCENT, PERCENT);
        // Both glide rates are bounded by the 2.5%/yr code ceiling on the fixed 1e9 base: no
        // Timelock operation can raise emission above it (ECO-01b, plan mutant (i)).
        if (p == Param.EmissionPerSecond) return (0, EMISSION_CEILING, PERCENT);
        if (p == Param.EmissionFloorRate) return (0, EMISSION_CEILING, PERCENT);
        if (p == Param.EmissionGlideDuration) return (YEAR, 20 * YEAR, 1 days);
        if (p == Param.TailEmissionRate) return (PERCENT / 4, (3 * PERCENT) / 2, 0);
        if (p == Param.MaxApy) return (5 * PERCENT, 30 * PERCENT, 0);
        // Param.LockupBonusMultiplier
        return (Decimal.unit(), 2 * Decimal.unit(), 0);
    }

    function _setInitial(Param p, uint256 v) private {
        (uint256 lo, uint256 hi, ) = _spec(p);
        require(v >= lo && v <= hi, "ConstantsManager: initial value outside the hard bound");
        _values[uint256(p)] = v;
    }

    /// @dev Moves one parameter to `v` through both limits and records the change.
    function _update(Param p, uint256 v) internal {
        (uint256 lo, uint256 hi, uint256 minStep) = _spec(p);
        require(v >= lo && v <= hi, "ConstantsManager: outside the hard bound");
        uint256 current = _values[uint256(p)];
        if (v == current) {
            return;
        }
        (uint256 rateLo, uint256 rateHi, uint256 used) = _rateRange(p, current, minStep);
        require(used < HISTORY_SLOTS, "ConstantsManager: too many changes in 12 months");
        require(v >= rateLo && v <= rateHi, "ConstantsManager: moves more than 20% in 12 months");

        History storage h = _history[p];
        h.ring[h.head] = Change(uint64(block.timestamp), uint192(current));
        h.head = uint8((uint256(h.head) + 1) % HISTORY_SLOTS);
        _values[uint256(p)] = v;
        emit UpdatedConstant(p, current, v);
    }

    /**
     * @dev The rate-limited range for `p` given its current value: every value held inside the
     * window is `current` or the `previous` of a change recorded inside it.
     */
    function _rateRange(Param p, uint256 current, uint256 minStep) internal view returns (uint256 lo, uint256 hi, uint256 used) {
        uint256 wMin = current;
        uint256 wMax = current;
        History storage h = _history[p];
        for (uint256 i = 0; i < HISTORY_SLOTS; i++) {
            Change memory c = h.ring[i];
            if (c.time != 0 && uint256(c.time) + RATE_LIMIT_WINDOW > block.timestamp) {
                used++;
                if (c.previous < wMin) wMin = c.previous;
                if (c.previous > wMax) wMax = c.previous;
            }
        }
        hi = wMin + _step(wMin, minStep);
        uint256 down = _step(wMax, minStep);
        lo = wMax > down ? wMax - down : 0;
    }

    function _step(uint256 ref, uint256 minStep) internal pure returns (uint256) {
        uint256 s = (ref * RATE_LIMIT) / Decimal.unit();
        return s > minStep ? s : minStep;
    }

    function _checkInvariants() internal view {
        uint256 u = Decimal.unit();
        require(
            _values[uint256(Param.GasFeeReserveShare)] + _values[uint256(Param.GasFeeTreasuryShare)] + _values[uint256(Param.GasFeeValidatorShare)] == u,
            "ConstantsManager: gas-fee split does not sum to 100%"
        );
        require(
            _values[uint256(Param.HostingReserveShare)] +
                _values[uint256(Param.HostingTreasuryShare)] +
                _values[uint256(Param.HostingInsuranceShare)] +
                _values[uint256(Param.HostingHostShare)] ==
                u,
            "ConstantsManager: hosting split does not sum to 100%"
        );
        require(
            _values[uint256(Param.SustainabilityShare)] <= _values[uint256(Param.GasFeeTreasuryShare)],
            "ConstantsManager: sustainability share exceeds the treasury share"
        );
        require(
            _values[uint256(Param.MinLockupDuration)] <= _values[uint256(Param.MaxLockupDuration)],
            "ConstantsManager: min lockup exceeds max lockup"
        );
        require(
            _values[uint256(Param.EmissionFloorRate)] <= _values[uint256(Param.EmissionPerSecond)],
            "ConstantsManager: the glide's end rate exceeds its start rate"
        );
    }

    // ------------------------------------------------------------- the emission controller (ECO-01b)

    /**
     * @notice The emission rate, NEC-wei per second, at `elapsed` seconds since emission started
     * (DECIDE-07, design 7 step 3). Two phases and ONE deterministic switch between them:
     *
     *  - while the RewardsReserve holds anything, the GLIDE, measured on the fixed 1e9 base: the rate
     *    walks linearly from `emissionPerSecond` (2%/yr) to `emissionFloorRate` (1%/yr) over
     *    `emissionGlideDuration`, then stays there. Every NEC of it is DRAWN from the reserve, so
     *    totalSupply does not move (DECIDE-25);
     *  - once the reserve is empty, the TAIL: `tailEmissionRate` a year of LIVE supply, minted. This
     *    is the only mechanism by which supply can ever change, and it exists from day one.
     *
     * The switch is `reserveBalance == 0`, which the SFC reads at the seal, so the phase is a function
     * of state and not of a stored flag that could disagree with it.
     */
    function emissionRatePerSecond(uint256 elapsed, uint256 liveSupply, uint256 reserveBalance) public view returns (uint256) {
        if (reserveBalance == 0) {
            return (_values[uint256(Param.TailEmissionRate)] * liveSupply) / (Decimal.unit() * YEAR);
        }
        uint256 start = _values[uint256(Param.EmissionPerSecond)];
        uint256 end = _values[uint256(Param.EmissionFloorRate)];
        uint256 glide = _values[uint256(Param.EmissionGlideDuration)];
        if (elapsed >= glide) {
            return end;
        }
        return start - ((start - end) * elapsed) / glide;
    }

    /**
     * @notice An epoch's whole emission budget: the rate above over the epoch's seconds, under both
     * caps DECIDE-07/13 require.
     *
     *  - `maxApy` x `totalStake`, prorated: while stake is small the glide would be an absurd yield,
     *    and the cap, not the glide, is what gets paid;
     *  - `EMISSION_CODE_CEILING` x `liveSupply`, prorated: 2.5% a year, a constant of this code that
     *    no parameter can cross.
     *
     * It is a view: the SFC decides how to fund the budget (reserve first, then mint) and the caller
     * passes the state it is measured on, so nothing here keeps a second copy of the chain's numbers.
     */
    function epochEmissionBudget(
        uint256 elapsed,
        uint256 epochDuration,
        uint256 totalStake,
        uint256 liveSupply,
        uint256 reserveBalance
    ) external view returns (uint256 budget) {
        budget = emissionRatePerSecond(elapsed, liveSupply, reserveBalance) * epochDuration;
        uint256 apyCap = (_values[uint256(Param.MaxApy)] * totalStake * epochDuration) / (Decimal.unit() * YEAR);
        if (budget > apyCap) {
            budget = apyCap;
        }
        uint256 ceiling = (EMISSION_CODE_CEILING * liveSupply * epochDuration) / (Decimal.unit() * YEAR);
        if (budget > ceiling) {
            budget = ceiling;
        }
    }
}
