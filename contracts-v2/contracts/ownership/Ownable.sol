// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "../common/Initializable.sol";

/**
 * @title Ownable (SFC v2)
 *
 * @dev Single-owner access control. In SFC v2 the owner of every module is the Timelock predeploy
 * (GOV-02), so "onlyOwner" means "queued through the Timelock and served its delay"; the delay
 * class of each call is the Timelock's business, not this contract's.
 *
 * Two deliberate differences from the v1 (Fantom) Ownable:
 *
 *  - `renounceOwnership` always reverts (audit SFC-8). An ownerless SFC can never again be
 *    governed, and every bounded setter in ConstantsManager would be frozen at whatever value it
 *    held. The selector is kept so a call fails loudly instead of falling through.
 *  - the init function is `__Ownable_init` and `onlyInitializing`, so it can only run inside the
 *    top-level initializer of the contract that inherits this.
 *
 * STORAGE LAYOUT IS LOAD-BEARING: `_owner` is slot 51 and the gap is slots 52..101, exactly as in the
 * v1 SFC, so SFC v2 installed over v1 storage keeps its owner. Do not reorder or append.
 */
abstract contract Ownable is Initializable {
    address private _owner;

    // Reserved: the v1 gap.
    uint256[50] private ______gap;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function __Ownable_init(address owner_) internal onlyInitializing {
        require(owner_ != address(0), "Ownable: new owner is the zero address");
        _owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @dev The current owner (the Timelock, in production).
    function owner() public view returns (address) {
        return _owner;
    }

    /// @dev Kept from the v1 ABI.
    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        _;
    }

    /// @dev Disabled: see the contract comment.
    function renounceOwnership() external pure {
        revert("Ownable: renouncing ownership is disabled");
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}
