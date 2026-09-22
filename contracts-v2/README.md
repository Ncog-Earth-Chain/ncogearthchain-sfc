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
| SFC core, RewardsReserve / Treasury / InsurancePool wiring, HostBonds hooks | see §11 of the design | **not yet** |

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
   rename allowed is to `__deprecated_<name>`. The rule is `checkAppendOnly` in `build-lib.js`, and
   the layouts in `out/*.storage.json` and `layout/` carry every struct member for it;
3. with `--node`, the node repository's `ncogearthchain/genesis/sfc/testdata/v2/` copies are
   byte-identical to `out/`;
4. the gate in 2 still has teeth: a **self-test** compiles broken variants of `ConstantsManager`
   (its `History` struct reordered, a `Change` member retyped or resized, the ring resized, a member
   added to the inline `Change`, `_values` resized) and requires each to be refused, and one legal
   append (a member at the end of `History`) and requires it to be accepted.

## Tests

The tests are in the node repository and execute the committed runtime in the EVM, so they need no
solc:

* `ncogearthchain/genesis/sfc/constants_v2_test.go`: the ConstantsManager against the decided parameter table;
* `ncogearthchain/genesis/sfc/nodesurface_test.go`: the node-surface harness, which SFC v2 core joins when it is built.

After changing a contract, rebuild, copy the changed `out/` files into the node's `testdata/v2/`,
update the hash pins in `nodesurface_test.go`, and run both suites.
