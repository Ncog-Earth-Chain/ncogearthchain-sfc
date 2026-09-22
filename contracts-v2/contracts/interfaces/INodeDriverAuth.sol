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
 *    the chain's only way to credit native NEC. SFC v2 has exactly three uses for it, and only the
 *    third moves the supply ledger (docs/design/sfc-v2.md in the node repository, 6.1 and 7):
 *
 *      1. setGenesisDelegation, block 1: credits the genesis stake WITHOUT moving `totalSupply`,
 *         because the stake is already inside the declared supply `initialize` recorded
 *         (DECIDE-14; ECO-01a's `stakeInsideSupply`). Adding it again is the 4M double count
 *         ECO-01a found in v1.
 *      2. sealEpoch, fee re-credit: credits 100% of the epoch's gas fees WITHOUT moving
 *         `totalSupply`. The node debited exactly that amount from the senders at execution
 *         (buyGas / refundGas), so the debit and this credit net to zero (DECIDE-25: nothing is
 *         destroyed).
 *      3. the tail mint, through `_mint` only: the one use that moves `totalSupply` (and
 *         `totalMinted`) by the amount credited. Reward CLAIMS never call incBalance; they pay out
 *         NEC the SFC already holds.
 *
 *    Any other call is a supply-ledger bug.
 */
interface INodeDriverAuth {
    function incBalance(address acc, uint256 diff) external;

    function updateValidatorWeight(uint256 validatorID, uint256 value) external;

    function updateValidatorPubkey(uint256 validatorID, bytes calldata pubkey) external;
}
