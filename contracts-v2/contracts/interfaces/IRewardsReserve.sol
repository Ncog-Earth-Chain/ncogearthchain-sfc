// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title IRewardsReserve (the SFC's view of it)
 *
 * @dev The genesis RewardsReserve (ECO-04; node repository contracts/RewardsReserve.sol, design 6.3).
 * `draw` is callable by the SFC alone and pays the SFC by a plain value call, which SFC v2 accepts
 * from the reserve only. `deposit` takes the fee reserve share, unlock penalties and the reserve's
 * part of confiscations.
 */
interface IRewardsReserve {
    function draw(uint256 amount) external;

    function deposit() external payable;

    function balance() external view returns (uint256);
}
