// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title IConstantsManager (the SFC's view of it)
 *
 * @dev ../sfc/ConstantsManager.sol, as SFC v2 core reads it: `value(Param)` with the parameter's enum
 * index (an enum is a uint8 in the ABI). One getter rather than twenty keeps the core under EIP-170.
 * Every economic figure the SFC applies -- stake limits, the delegation ratio, commission, the
 * concentration cap, lockups, the withdrawal period, the fee split, the offline thresholds, the
 * slashing figures and the emission controller's parameters -- is read from here at the moment it is
 * applied, never copied into the SFC, so the Timelock's bounded, rate-limited setters on the
 * ConstantsManager are the one way to change any of them. The indices are the `P_*` constants in
 * SFC.sol.
 *
 * `epochEmissionBudget` is the EMISSION CONTROLLER itself (ECO-01b): the glide, the tail and the two
 * caps live with the parameters they read, not in the SFC, because the core has no EIP-170 room left
 * for them and because a separate module would be a second place that has to agree on the same
 * numbers (design 3's note on the fee splitter). The SFC passes the state the budget is measured on
 * and keeps the funding decision -- reserve first, then mint -- which is the part that needs its
 * storage.
 */
interface IConstantsManager {
    function value(uint8 p) external view returns (uint256);

    function epochEmissionBudget(
        uint256 elapsed,
        uint256 epochDuration,
        uint256 totalStake,
        uint256 liveSupply,
        uint256 reserveBalance
    ) external view returns (uint256);

    /// @dev ECO-05: one host's DDB revenue split by the hosting shares; host is the remainder.
    function hostingSplit(uint256 amount) external view returns (uint256 host, uint256 reserve, uint256 treasury, uint256 insurance);
}
