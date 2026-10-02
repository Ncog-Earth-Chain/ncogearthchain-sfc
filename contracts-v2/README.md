# `contracts-v2`: NCOG SFC v2 (GOV-01b)

This is the fresh solc-0.8.20 modular rewrite of the staking contract (DECIDE-21). It is **not** the
mechanical port in `../contracts-0.8.20`, which exists only to establish what the genesis blobs are.

The specification is `docs/design/sfc-v2.md` in the node repository (`ncogearthchain`). Read that
first. It gives the module layout, the append-only storage layout, the owner/Timelock topology,
every function's access rule and bound, and the exact node-surface table.

## What is here

| path | what | status |
|---|---|---|
| `contracts/sfc/ConstantsManager.sol` | every governable SFC v2 parameter, each with a hard bound and the ±20% per rolling 12 months rate limit; owner = the Timelock; no burn/destroy parameter | built, tested |
| `contracts/interfaces/ISFCNodeSurface.sol` | the SFC exactly as the node calls and reads it; SFC v2 core must inherit it | built, pinned by the node |
| `contracts/interfaces/INodeDriverAuth.sol` | the three calls the SFC makes into the deployed NodeDriverAuth | built, pinned by the node |
| `contracts/common/Initializable.sol` | `initializer` / `reinitializer(n)` / `onlyInitializing`, occupying v1's slot 0 bytes | built |
| `contracts/ownership/Ownable.sol` | owner in v1's slot 51; `renounceOwnership` always reverts | built |
| `contracts/common/Decimal.sol` | 1e18 == 100% | built |
| `contracts/sfc/SFC.sol` | SFC v2 core: the node surface, the v1 storage prefix (`SFCStorageV1`, slots 102..123) and v2's appended state (`SFCStorageV2`, from 124), the supply ledger, the fee split, the fixed-budget emission stub drawn from the RewardsReserve, slash-at-fault with routing, the linear unlock penalty, the concentration cap, `reactivateValidator` with the D9 reward gaps, `updateValidatorPubkey`, `call` + ReentrancyGuard, `version()` "200". Every economic figure is read from the ConstantsManager (`value(Param)`); reverts are custom errors (EIP-170: 24,010 B of 24,576); `circulatingSupply()` (totalSupply − reserve − the excluded vaults, a list the Timelock adds to and removes from) | built, run by the node's harness |
| `contracts/interfaces/IConstantsManager.sol`, `IRewardsReserve.sol`, `IHostBonds.sol` | the SFC's view of its modules (HostBonds: interface only) | built |
| RewardsReserve / Treasury / InsurancePool contracts, the install path (mainnet builder, testnet Timelock batch), the glide controller | design §11 items 4, 6; ECO-01b | **not yet** |

## Build

```sh
npm ci            # solc 0.8.20+commit.a1b79de6, pinned
npm run build     # -> out/<Contract>.{abi,bin,bin-runtime,storage.json}
npm run verify    # the CI gate (below)
node verify.js --node ../ncogearthchain   # also compare the node repo's testdata/v2 copies
```

The settings are in `build-lib.js` and apply to every module: optimizer on, **runs 200**,
**evmVersion shanghai**, **`metadata.bytecodeHash: none`**. Line endings are normalised before
compiling. With no metadata hash, the bytes depend only on the source and these settings, so `out/` is
committed and any checkout can reproduce it exactly. The four inherited predeploys could not be
reproduced, because each carries an IPFS hash of a working tree nobody has (GOV-01).

`npm run verify` fails unless:

1. a fresh build is byte-identical to the committed `out/`;
2. every storage layout is **append-only** against `layout/<Contract>.json`, **recursively**: no
   baseline variable changes slot, offset or type; inside every type, no struct member changes slot,
   offset or type, no array changes length and nothing stored inline changes size; the one growth
   allowed is members appended after every existing member of a struct that is a **mapping value**
   (SFC v1's `Validator`, `WithdrawalRequest`, `LockedDelegation`, `EpochSnapshot`); the only
   rename allowed is to `__deprecated_<name>`. A top-level `uint256[N] …gap` may be used only
   **from the front**: new variables in its first k slots, then `uint256[N-k]` with the same name,
   so it still ends where it did. Types are compared by what is stored: the contract that declares
   a struct or enum (`struct SFC.Validator` against `struct SFCStorageV1.Validator`) and the name of
   a contract type (`NodeDriverAuth` against `INodeDriverAuth`) do not count; a struct's own name,
   its members, sizes and encodings do. The one other exception is `LAYOUT_COMPAT`, a reviewed
   table in `build-lib.js`: today it allows exactly v1's slot 0 (`bool initialized`,
   `bool initializing`) under v2's `Initializable` (`uint8 _initialized`, `bool _initializing`), and
   nothing else. The rule is `checkAppendOnly` in `build-lib.js`, and the layouts in
   `out/*.storage.json` and `layout/` carry every struct member for it;
3. `layout/SFC.json`, once committed, is exactly the compiled layout of the v1 port in
   `../contracts-0.8.20` (SFC v2 core's baseline is v1's layout, design §5.2). Generate it with
   `node compile.js --port-baselines`; a hand-edited copy fails;
4. with `--node`, the node repository's `ncogearthchain/genesis/sfc/testdata/v2/` copies are
   byte-identical to `out/`;
5. the gate in 2 has teeth and is no stricter than the design: a **self-test** of 19 cases compiles
   broken variants (`History` reordered, a `Change` member retyped or resized, the ring resized, a
   member added to the inline `Change`, `_values` resized, v2's `_initialized` widened to `uint16`
   over v1's `bool`, the slot-0 exception used at slot 167, a gap grown, a gap moving its end, a
   struct renamed, a contract type turned into `address`) and requires each of the 13 to be refused
   at the named place; and it compiles the 6 legal changes (a member appended to `History`, v2's
   `Initializable`/`Ownable` over the port's v1 slots 0..101, `Ownable`'s gap used from the front, a
   trailing gap used from the front, `Change`/`History` declared in a base contract, a contract type
   retyped to another interface) and requires each to be accepted.

## Tests

The tests are in the node repository and execute the committed runtime in the EVM, so they need no
solc:

* `ncogearthchain/genesis/sfc/constants_v2_test.go`: the ConstantsManager against the decided parameter table;
* `ncogearthchain/genesis/sfc/nodesurface_test.go`: the node-surface harness, which runs SFC v2 core (`v2 SFC core` in `sfcImplementations`) next to the two v1 controls;
* `ncogearthchain/genesis/sfc/sfcv2_test.go`: SFC v2 core's behaviour: the linear unlock penalty (plan mutant (i)), the `sealEpoch` length check (mutant (ii)), the concentration cap, the D9 reward gaps and the supply identity.

After changing a contract, rebuild, copy the changed `out/` files into the node's `testdata/v2/`,
update the hash pins in `nodesurface_test.go`, and run both suites.
