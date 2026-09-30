// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title IHostBonds (ECO-02a hook; interface only in SFC v2)
 *
 * @dev Design 6.6. SFC v2 only records the address (zero until ECO-02a installs HostBonds through the
 * Timelock) and calls nothing on it yet; the hosting economy lives outside the SFC (audit SFC-16).
 */
interface IHostBonds {
    function registerRole(uint256 validatorID, uint8 role, uint256 bond) external;

    function slashRole(uint256 validatorID, uint8 role, uint256 amount, bytes32 reason) external;

    function settle(uint8 role, address host, uint256 amount) external;
}
