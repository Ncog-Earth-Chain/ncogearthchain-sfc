// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title INodeDriverAuth (the SFC's view of it)
 *
 * @dev The three calls the SFC makes back into the deployed NodeDriverAuth at
 * 0xd100ae0000000000000000000000000000000000. NodeDriverAuth is a genesis predeploy that SFC v2 does
 * NOT replace, so these must stay exactly the selectors that deployed blob dispatches; the node
 * repository's nodesurface_test.go checks that it does.
 *
 *  - updateValidatorWeight -> NodeDriver emits UpdateValidatorWeight(uint256,uint256), which the node
 *    turns into the next epoch's validator weight (weight 0 removes the validator).
 *  - updateValidatorPubkey -> NodeDriver emits UpdateValidatorPubkey(uint256,bytes). The node applies
 *    it ONLY to a validator that already has an entry in the block's NextValidatorProfiles, i.e.
 *    one whose weight was updated earlier in the same epoch; so a pubkey change must be preceded by
 *    a weight update for the same validator, exactly as v1's `_syncValidator(id, true)` does
 *    (gossip/blockproc/drivermodule/driver_txs.go, the UpdateValidatorPubkey branch).
 *  - incBalance -> NodeDriver.setBalance on the SFC itself (the recipient must be the SFC). This is
 *    the chain's only native mint path. In v2 it is used for the bounded tail mint only, and every
 *    use moves `totalSupply`.
 */
interface INodeDriverAuth {
    function incBalance(address acc, uint256 diff) external;

    function updateValidatorWeight(uint256 validatorID, uint256 value) external;

    function updateValidatorPubkey(uint256 validatorID, bytes calldata pubkey) external;
}
