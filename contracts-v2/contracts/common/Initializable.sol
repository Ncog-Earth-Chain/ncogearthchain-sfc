// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title Initializable (SFC v2)
 *
 * @dev Initializer guard with versioned re-initialisation, for contracts that are never constructed:
 * every SFC v2 module is either a genesis predeploy (runtime code placed by the builder, so no
 * constructor ever runs) or code installed over an existing address by NodeDriverAuth.upgradeCode.
 *
 * STORAGE LAYOUT IS LOAD-BEARING. SFC v2 is installed on the testnet over the storage of the v1 SFC
 * (Fantom SFC v3.0.2-rc.2 lineage), whose Initializable was
 *
 *     bool private initialized;      // slot 0, byte 0
 *     bool private initializing;     // slot 0, byte 1
 *     uint256[50] private ______gap; // slots 1..50
 *
 * This contract occupies exactly the same bytes. `_initialized` is a uint8 in byte 0, so a v1
 * contract that has run its initializer reads back here as version 1, and `reinitializer(2)` is the
 * one-time hook for the v2 migration. Do not reorder, retype or remove any of these three
 * variables; append nothing to this contract.
 */
abstract contract Initializable {
    /// @dev The highest initializer version that has run. v1's `bool initialized == true` is 1.
    uint8 private _initialized;

    /// @dev True only while an initializer is executing.
    bool private _initializing;

    // Reserved: the v1 gap, kept so every slot after it lines up with the v1 SFC.
    uint256[50] private ______gap;

    event Initialized(uint8 version);

    /**
     * @dev The first initializer. Equivalent to `reinitializer(1)`: it runs once, ever, and cannot
     * be nested (parent contracts use `onlyInitializing` for their init functions instead).
     */
    modifier initializer() {
        _startInitializing(1);
        _;
        _stopInitializing(1);
    }

    /**
     * @dev A later initializer. Runs once, only if no initializer of this or a higher version has
     * run, and never inside another initializer.
     */
    modifier reinitializer(uint8 version) {
        _startInitializing(version);
        _;
        _stopInitializing(version);
    }

    /// @dev For the init functions of parent contracts, callable only from inside an initializer.
    modifier onlyInitializing() {
        require(_initializing, "Initializable: contract is not initializing");
        _;
    }

    /// @dev The highest initializer version that has run.
    function _getInitializedVersion() internal view returns (uint8) {
        return _initialized;
    }

    function _startInitializing(uint8 version) private {
        require(!_initializing && _initialized < version, "Initializable: contract is already initialized");
        _initialized = version;
        _initializing = true;
    }

    function _stopInitializing(uint8 version) private {
        _initializing = false;
        emit Initialized(version);
    }
}
