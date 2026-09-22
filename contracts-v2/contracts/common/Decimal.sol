// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev Fixed-point unit shared by every ratio in SFC v2: 1e18 == 100%. Same unit as v1, so the
/// carried-over reward accounting (accumulatedRewardPerToken, commission, lockup scaling) is
/// unchanged in meaning.
library Decimal {
    function unit() internal pure returns (uint256) {
        return 1e18;
    }
}
