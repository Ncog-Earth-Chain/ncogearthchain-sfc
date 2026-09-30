// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title IConstantsManager (the SFC's view of it)
 *
 * @dev ../sfc/ConstantsManager.sol, as SFC v2 core reads it: `value(Param)` with the parameter's enum
 * index (an enum is a uint8 in the ABI). One getter rather than twenty keeps the core under EIP-170.
 * Every economic figure the SFC applies -- stake limits, the delegation ratio, commission, the
 * concentration cap, lockups, the withdrawal period, the fee split, the offline thresholds, the
 * slashing figures and the emission stub's budget -- is read from here at the moment it is applied,
 * never copied into the SFC, so the Timelock's bounded, rate-limited setters on the ConstantsManager
 * are the one way to change any of them. The indices are the `P_*` constants in SFC.sol.
 */
interface IConstantsManager {
    function value(uint8 p) external view returns (uint256);
}
