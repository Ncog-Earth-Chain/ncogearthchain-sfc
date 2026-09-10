# `contracts-0.8.20` — the solc-0.8.20 port of the four genesis predeploys

This is not a new contract. It is a **mechanical port** of `../contracts` from Solidity 0.5 to 0.8,
made for one purpose: to find out what the four blobs frozen into the NCOG genesis actually are.

The chain ships `SFC`, `NodeDriver`, `NodeDriverAuth` and `NetworkInitializer` as runtime bytecode
literals in `ncogearthchain/genesis/*/`. Their headers named a commit of this repository —
`c1d33c81f74abf82c0e22807f16e609578e10ad8` — and a compiler, and both were wrong in ways that made
the claim unfalsifiable: the commit is on no tree and not on this repo's remote
(`git ls-remote` gives `refs/heads/main = 4d9a6b50f4a2829699a5033adb5c1dbedc7c2aa9`), and the named
compiler could not have produced the blobs at all, because they contain `PUSH0` and carry a
`solc 0.8.20` version trailer while this repo builds under 0.5.17.

Porting the source forward to 0.8.20 and compiling it settles the question. The result:

| contract | deployed | this port | verdict |
|---|---|---|---|
| **NodeDriver** | 5,632 B | 5,632 B | **code section byte-identical** (5,579 B; only the metadata trailer differs) |
| NodeDriverAuth | 7,265 B | 7,271 B | 0.9889 opcode-stream similarity |
| NetworkInitializer | 702 B | 697 B | 0.9853; **one behavioural difference**, below |
| SFC | 22,713 B | 22,596 B | 0.9818; five added `require` guards, below |

The metadata trailer can never match: it is an IPFS hash of the source metadata, which includes file
names and comments, so only the original working tree could reproduce it. Every comparison above is
made on the code in front of that trailer.

The node keeps the compiled artefacts of this port as test data and re-checks the table on every
`go test`, without solc:
`ncogearthchain/genesis/sfc/testdata/port-0.8.20/` and `ncogearthchain/genesis/sfc/provenance_test.go`.
The full record is `docs/findings/sfc-provenance-2026-09-10.md` in the node repository.

## Compiler settings

Everything in the table depends on these exactly. Changing any of them changes the bytecode.

| setting | value |
|---|---|
| compiler | `solc-js 0.8.20+commit.a1b79de6.Emscripten.clang` (pinned in `package.json` / `package-lock.json`) |
| optimizer | enabled |
| optimizer runs | **10000** — *not* the 200 in `../truffle-config.js`, and not the "optimize-runs 200" the SFC predeploy header used to claim |
| evmVersion | **shanghai** — the deployed blobs use `PUSH0`, which is Shanghai's EIP-3855 |
| metadata hash | default (IPFS), i.e. **not** `--metadata-hash none` — matching the deployed blobs, which carry an `a26469706673…` trailer |
| output | `abi`, `evm.bytecode.object`, `evm.deployedBytecode.object` |

```sh
npm install       # solc 0.8.20, pinned
npm run build     # -> out/{SFC,NodeDriver,NodeDriverAuth,NetworkInitializer}.{abi,bin,bin-runtime}
```

The build is deterministic: two runs produce identical `out/`.

## What the port changed, and what it did not

`../contracts` and `contracts/` differ by 45 lines in `SFC.sol` and by four lines or fewer in every
other file. `diff -ru ../contracts contracts` is short enough to read in full, and should be read
before trusting anything here. In summary:

* **pragma** `^0.5.0` → `^0.8.0` in every file (this is most of the diff).
* **`msg.sender` → `payable(msg.sender)`** in `withdraw` and `claimRewards`, and
  `selfdestruct(address(0))` → `selfdestruct(payable(address(0)))`: 0.8 removed the implicit
  address→address-payable conversion. No behaviour change.
* **`SafeMath` becomes a thin wrapper** over the native checked operators (`lib/openzeppelin/math/SafeMath.sol`).
  0.8 checks arithmetic in the language, so OpenZeppelin 2.x's implementation would compile to
  double checks and a bytecode that resembles nothing. The wrapper keeps the call sites unchanged.
* **`StakeTokenizer.mintSNEC`/`redeemSNEC` removed**, with the ERC-20 imports they needed. They are
  not reachable from any of the four contracts compiled here; keeping them would have dragged the
  whole `contracts/erc20` tree into a port nobody will deploy.
* **Five `require(..., "underflow in ...")` guards added to `SFC.sol`** — at
  `_setValidatorDeactivated`, `_rawUndelegate` (three) and the reward-rate and unlocked-stake paths.
  These are **not** cosmetic and **not** the porter's invention: the deployed SFC blob contains those
  exact revert strings, and no version of `../contracts/sfc/SFC.sol` does. Under 0.5 the checks lived
  inside `SafeMath.sub`; whoever built the deployed blob wrote them out by hand with messages. They
  are the strongest evidence that the deployed source is a **modified** `c1d33c8` rather than a
  compiler-version difference, and they are asserted by the node's `provenance_test.go`.

## The one behavioural divergence

`NetworkInitializer.initializeAll` ends in `selfdestruct(address(0))` in this source, and this port
compiles that to a `SELFDESTRUCT`. **The deployed blob has no `0xff` opcode anywhere** — it ends the
function with `POP` ×7 / `JUMP` and returns normally. So on this chain the network initializer is a
permanent 649-byte contract at `0xd1005eed…`, not a one-shot one. Re-entering `initializeAll` reverts
(its first inner call is `NodeDriver.initialize`, which is `initializer`-guarded), so it is a
surprise rather than a hole — but anything that assumes that address is empty after block 1 is wrong.

## Verifying this repo's own 0.5.17 build

The port is only meaningful if `../contracts` still is what `../build/contracts` was compiled from.
`reproduce-0.5.17.js` checks that, reproducing the committed truffle artefacts byte for byte:

```sh
npm install --no-save solc@0.5.17
node reproduce-0.5.17.js ..
```

```
solc-js 0.5.17+commit.d19bba13.Emscripten.clang | optimizer runs 10000 | evmVersion istanbul
SFC                  22616 B  BYTE-IDENTICAL to build/contracts/SFC.json
NodeDriver            6360 B  BYTE-IDENTICAL to build/contracts/NodeDriver.json
NodeDriverAuth        7003 B  BYTE-IDENTICAL to build/contracts/NodeDriverAuth.json
NetworkInitializer     662 B  BYTE-IDENTICAL to build/contracts/NetworkInitializer.json
```

Note the settings: runs **10000** and evmVersion **istanbul**, which are what truffle recorded in the
artefacts' own metadata, not the `runs: 200` in `../truffle-config.js`.

## What this is not

It is **not** the replacement staking contract. That is a separate, fresh 0.8.20 rewrite (ticket
GOV-01b) with its own supply ledger, emission controller, fee split, timelock and delegation caps.
This tree exists so that rewrite starts from a settled account of what is deployed today, and so the
provenance claim in the node's genesis headers has something a machine can re-check.
