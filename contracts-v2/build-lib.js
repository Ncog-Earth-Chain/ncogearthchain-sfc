// Shared by compile.js and verify.js: the ONE place the SFC v2 compiler settings live.
//
// Every artefact of SFC v2 is a function of the sources below and of these settings alone. That is
// the point of `metadata.bytecodeHash: 'none'` (solc's --metadata-hash none): with the default IPFS
// hash, the runtime code ends in a hash of the source metadata -- file names, comments, settings --
// so editing a comment moves the deployed bytes and nobody but the original working tree can ever
// reproduce them. That is exactly what happened to the four genesis predeploys (GOV-01;
// docs/findings/sfc-provenance-2026-09-10.md in the node repository). With it off, solc still
// appends a short CBOR trailer, but it carries only the compiler version (a164736f6c6343000814000a).
'use strict';
const fs = require('fs');
const path = require('path');
const solc = require('solc');

const ROOT = __dirname;

const SETTINGS = {
    // solc-js 0.8.20+commit.a1b79de6, pinned in package.json / package-lock.json. The same compiler
    // the chain already pins for the council blob and the four predeploys.
    compilerVersion: '0.8.20+commit.a1b79de6.Emscripten.clang',
    // runs 200, deliberately NOT the 10000 the four inherited predeploys were built with. 10000
    // optimises for call cost at the expense of size, and the v1 SFC built that way is already
    // 22,713 B of EIP-170's 24,576 B; SFC v2 core adds the supply ledger, fee split, concentration
    // cap, reactivation and pubkey rotation. Chosen for headroom; the default for every module, which
    // a TARGETS entry may override with its own `runs` (SFC v2 core does: see TARGETS).
    optimizer: { enabled: true, runs: 200 },
    // shanghai: PUSH0 (EIP-3855). The chain's interpreter enables it unconditionally
    // (ncogearthchain/rules.go DefaultVMConfig ExtraEips 3855), and the deployed predeploys already
    // use it, so there is nothing to gate. Nothing newer (no MCOPY/TSTORE-dependent codegen).
    evmVersion: 'shanghai',
    metadata: { bytecodeHash: 'none' },
};

// Contracts whose artefacts are produced, and which outputs each gets.
//   full: abi + creation code + runtime code + storage layout
//   abi:  interfaces, which have no code
// `runs`, where given, replaces SETTINGS.optimizer.runs for that contract alone. SFC v2 core is built
// with runs 1 (SEC-15b, "202"): the proof of possession and the key binding did not fit EIP-170 at
// runs 200, and runs 1 is the smallest code solc emits for the same source -- 403 B less on "201"'s
// source, at a little more gas per call (the measured table: docs/design/sfc-v2.md in the node
// repository, "v2.2"). Only the SFC: the ConstantsManager keeps runs 200 and its bytes (sha256
// af966a5c...), which a ConstantsManager already deployed on a chain must keep matching.
const TARGETS = [
    { file: 'contracts/sfc/ConstantsManager.sol', name: 'ConstantsManager', kind: 'full' },
    { file: 'contracts/sfc/SFC.sol', name: 'SFC', kind: 'full', runs: 1 },
    { file: 'contracts/interfaces/ISFCNodeSurface.sol', name: 'ISFCNodeSurface', kind: 'abi' },
    { file: 'contracts/interfaces/INodeDriverAuth.sol', name: 'INodeDriverAuth', kind: 'abi' },
];

// EIP-170: the largest runtime a contract may have.
const MAX_RUNTIME = 24576;

function walk(dir, acc) {
    for (const f of fs.readdirSync(dir).sort()) {
        const p = path.join(dir, f);
        if (fs.statSync(p).isDirectory()) walk(p, acc);
        else if (p.endsWith('.sol')) acc.push(p);
    }
    return acc;
}

// `patches` (used only by verify.js's self-test of the append-only gate) maps a source unit to a
// function that rewrites its (LF-normalised) text before compiling.
function sources(patches) {
    const out = {};
    for (const f of walk(path.join(ROOT, 'contracts'), [])) {
        const unit = path.relative(ROOT, f).split(path.sep).join('/');
        // Normalise line endings so a CRLF checkout builds the same bytes as an LF one. With
        // bytecodeHash none the source text does not reach the code anyway, but the AST ids and
        // hence nothing else should depend on the platform either.
        let content = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
        if (patches && patches[unit]) content = patches[unit](content);
        out[unit] = { content };
    }
    return out;
}

// ---------------------------------------------------------------------------------------------
// Storage layout, reduced to what the append-only rule is about.
//
// Every top-level variable is recorded with its slot, offset, name and type, and the type is
// described RECURSIVELY: the members of every struct (each with its own slot, offset, name and
// type), the key and value of every mapping, and the element of every array, with each type's size
// in bytes. A struct's type label ("struct ConstantsManager.History") does not change when its
// members are reordered, retyped or resized, so a check on labels alone cannot see any of that --
// and a struct stored inside a mapping (SFC v1's Validator, WithdrawalRequest, LockedDelegation,
// EpochSnapshot, all of which the testnet install of v2 over v1 storage depends on) is exactly
// where such a change would corrupt live state.
function describeType(types, id, stack) {
    const t = types[id];
    const d = { type: t.label, encoding: t.encoding, bytes: Number(t.numberOfBytes) };
    if (stack.includes(id)) {
        // A struct that reaches itself through a mapping or a dynamic array. Its members are
        // described where it first appears.
        d.recursive = true;
        return d;
    }
    const inner = stack.concat([id]);
    if (t.key) d.key = describeType(types, t.key, inner);
    if (t.value) d.value = describeType(types, t.value, inner);
    if (t.base) d.base = describeType(types, t.base, inner);
    if (t.members) {
        d.members = t.members.map((m) => ({
            slot: m.slot,
            offset: m.offset,
            label: m.label,
            ...describeType(types, m.type, inner),
        }));
    }
    return d;
}

function compactLayout(layout) {
    return layout.storage.map((s) => ({
        slot: s.slot,
        offset: s.offset,
        label: s.label,
        ...describeType(layout.types, s.type, []),
    }));
}

// ---------------------------------------------------------------------------------------------
// The append-only rule (verify.js step 2, and its self-test). Returns the list of violations of
// `now` against the committed baseline `base`; empty means the layout may be installed in place
// over storage written by the baseline.
//
//  - A top-level baseline variable keeps its slot, offset and type, recursively (below). It may be
//    renamed only to __deprecated_<name>. The two exceptions are LAYOUT_COMPAT (below), a reviewed
//    table that is the only way a top-level type or name may change, and a GAP used from the front
//    (below). New top-level variables may be added where no baseline variable is: after the last
//    one, or at the front of a baseline gap.
//  - A GAP is a top-level `uint256[N]` whose name ends in `gap` (v1's `______gap`, v2's `__gap`).
//    It may be used only from the FRONT: new variables in its first k slots, then `uint256[N-k]`
//    with the SAME name at slot s+k, so the gap still ends where it did and nothing after it moves.
//    A gap that grows, shrinks at the back, moves its end, changes its name or is used up entirely
//    is refused (to use its last slot, leave `uint256[1]`). Gap slots were never written, so the new
//    variables start from zero on an install over the baseline's storage.
//  - Inside a type, recursively:
//      * the type label and encoding never change (this also pins every array length, which is part
//        of the label, and every mapping's key and value type labels). Labels are compared by
//        typeKey (below): the contract that DECLARES a struct or enum, and the name of a
//        contract-typed variable's contract, are not part of the comparison;
//      * a type stored INLINE -- a top-level variable, a struct member, a static-array element, a
//        dynamic-array element (its size is the stride) or a mapping key -- keeps its exact size;
//      * the one place a size may grow is a STRUCT that is the value of a mapping: each of its
//        slots is reached by hashing, so members appended AFTER every baseline member touch no
//        existing data;
//      * every baseline struct member keeps its slot, offset and type (recursively), renamed only to
//        __deprecated_<name>; members are only ever appended, never inserted, removed or reordered.
//        Neither LAYOUT_COMPAT nor the gap rule applies inside a type.
//
// LAYOUT_COMPAT: the reviewed exceptions to "a top-level variable never changes type or name". Each
// entry names ONE top-level position and the exact baseline variable (type and name) and the exact
// variable that may replace it; nothing else is ever matched against it -- not another slot or
// offset, not another type, not another name, not a struct member. Adding an entry is a design
// change: it needs a reviewed argument that the new type reads the old bytes with the old meaning,
// recorded here and in docs/design/sfc-v2.md §5.2 of the node repository, and a verify.js self-test
// case. verify.js refuses to run with a malformed entry.
const LAYOUT_COMPAT = [
    {
        // v1 (Fantom) Initializable -> v2 Initializable (contracts/common/Initializable.sol). Both are
        // one byte stored in place at slot 0 byte 0. v1 writes it 0x01 when its initializer has run;
        // v2 reads the same byte as the initializer VERSION, so v1 `true` is version 1 and
        // `reinitializer(2)` runs exactly once over v1 storage (design §5.1 row 0).
        slot: '0',
        offset: 0,
        was: { type: 'bool', label: 'initialized' },
        now: { type: 'uint8', label: '_initialized' },
    },
    {
        // The same contract: slot 0 byte 1 keeps its type and meaning; only the name changes.
        slot: '0',
        offset: 1,
        was: { type: 'bool', label: 'initializing' },
        now: { type: 'bool', label: '_initializing' },
    },
];

// Elementary one-slot-or-less value types, the only ones LAYOUT_COMPAT may name.
const COMPAT_TYPE = /^(bool|address|uint\d+|int\d+|bytes\d+)$/;

function checkCompatTable() {
    const errs = [];
    for (const c of LAYOUT_COMPAT) {
        const ok =
            typeof c.slot === 'string' &&
            Number.isInteger(c.offset) &&
            COMPAT_TYPE.test(c.was.type) &&
            COMPAT_TYPE.test(c.now.type) &&
            typeof c.was.label === 'string' &&
            typeof c.now.label === 'string';
        if (!ok) errs.push(`LAYOUT_COMPAT entry at slot ${c.slot}+${c.offset} is malformed: ${JSON.stringify(c)}`);
    }
    return errs;
}

// Whether top-level `n` may replace top-level baseline `b` under LAYOUT_COMPAT.
function compatible(b, n) {
    return LAYOUT_COMPAT.some(
        (c) =>
            c.slot === b.slot &&
            c.offset === b.offset &&
            c.was.type === b.type &&
            c.was.label === b.label &&
            c.now.type === n.type &&
            c.now.label === n.label &&
            b.encoding === 'inplace' &&
            n.encoding === 'inplace' &&
            b.bytes === n.bytes,
    );
}

// N for a top-level gap `uint256[N] ...gap` at offset 0, else 0.
function gapLength(v) {
    const m = /^uint256\[(\d+)\]$/.exec(v.type);
    return m && v.encoding === 'inplace' && v.offset === 0 && /gap$/.test(v.label) ? Number(m[1]) : 0;
}

// Whether baseline gap `b` (N slots from s) is now used from the front: a gap with the same name,
// uint256[M] with 0 < M < N, at slot s + (N - M). Whatever sits in slots s .. s+N-M-1 is new.
function gapUsedFromFront(b, now) {
    const N = gapLength(b);
    return now.some((g) => {
        const M = g.label === b.label ? gapLength(g) : 0;
        return M > 0 && M < N && Number(g.slot) === Number(b.slot) + (N - M);
    });
}

function checkAppendOnly(contract, base, now) {
    const errs = [];
    for (const b of base) {
        const n = now.find((x) => x.slot === b.slot && x.offset === b.offset);
        const gap = gapLength(b);
        if (gap && (!n || !sameType(b, n))) {
            if (gapUsedFromFront(b, now)) continue;
            const s = Number(b.slot);
            errs.push(
                `${contract}: slot ${b.slot}+${b.offset} was ${b.type} ${b.label}, is now ${n ? `${n.type} ${n.label}` : 'nothing'}` +
                    ` (a gap is used only from the front: new variables in slots ${s}..${s}+k-1, then` +
                    ` uint256[${gap}-k] ${b.label} at slot ${s}+k, so it still ends at slot ${s + gap - 1})`,
            );
            continue;
        }
        if (!n) {
            errs.push(`${contract}: baseline variable ${b.label} at slot ${b.slot}+${b.offset} is gone`);
            continue;
        }
        if (compatible(b, n)) continue;
        comparePositioned(errs, contract, b, n);
    }
    return errs;
}

// The part of a solc type label that is about storage. solc qualifies a struct or enum with the
// contract that DECLARES it ("struct SFC.Validator"), and names a contract-typed variable by its
// contract ("contract NodeDriverAuth"). Neither is a property of the stored bytes: moving the v1
// declarations into a base contract, as design §5.2 does with SFCStorageV1, turns every
// "struct SFC.X" into "struct SFCStorageV1.X", and typing slot 102 as the INodeDriverAuth interface
// turns "contract NodeDriverAuth" into "contract INodeDriverAuth"; each is still the same members or
// the same 20-byte address. So the declaring contract is dropped (the struct's or enum's OWN name is
// kept, and its members, size and encoding are still checked recursively), and every contract or
// interface type compares equal to every other. A contract type does NOT compare equal to `address`.
// The labels in messages are solc's, unchanged.
function typeKey(label) {
    return label
        .replace(/\b(struct|enum) (?:[A-Za-z_$][\w$]*\.)+([A-Za-z_$][\w$]*)/g, '$1 $2')
        .replace(/\bcontract [A-Za-z_$][\w$]*/g, 'contract');
}

function sameType(b, n) {
    return typeKey(n.type) === typeKey(b.type) && n.encoding === b.encoding;
}

// A baseline variable or struct member `b` and whatever now sits at its slot and offset.
function comparePositioned(errs, where, b, n) {
    if (!sameType(b, n)) {
        errs.push(`${where}: slot ${b.slot}+${b.offset} was ${b.type} ${b.label}, is now ${n.type} ${n.label}`);
        return;
    }
    if (n.label !== b.label && n.label !== '__deprecated_' + b.label) {
        errs.push(`${where}: slot ${b.slot}+${b.offset} renamed ${b.label} -> ${n.label} (only __deprecated_${b.label} is allowed)`);
    }
    compareType(errs, `${where}.${b.label}`, b, n, false);
}

function compareType(errs, where, b, n, growable) {
    if (!n) {
        errs.push(`${where}: ${b.type} is gone`);
        return;
    }
    if (!sameType(b, n)) {
        errs.push(`${where}: was ${b.type} (${b.encoding}), is now ${n.type} (${n.encoding})`);
        return;
    }
    if (growable ? n.bytes < b.bytes : n.bytes !== b.bytes) {
        errs.push(
            `${where}: ${b.type} was ${b.bytes} B, is now ${n.bytes} B` +
                (growable ? ' (a mapping value may only grow)' : ' (it is stored inline, so its size is frozen)'),
        );
    }
    if (b.recursive || n.recursive) return;
    if (b.key) compareType(errs, `${where} key`, b.key, n.key, false);
    if (b.value) compareType(errs, `${where}[key]`, b.value, n.value, b.value.members !== undefined);
    if (b.base) compareType(errs, `${where}[i]`, b.base, n.base, false);
    if (b.members) compareMembers(errs, where, b.members, n.members || [], growable);
}

function compareMembers(errs, where, bm, nm, growable) {
    const pos = (m) => Number(m.slot) * 32 + m.offset;
    let baseEnd = 0;
    const matched = new Set();
    for (const b of bm) {
        baseEnd = Math.max(baseEnd, pos(b) + b.bytes);
        const n = nm.find((x) => x.slot === b.slot && x.offset === b.offset);
        if (!n) {
            errs.push(`${where}: member ${b.label} (${b.type}) at slot ${b.slot}+${b.offset} is gone -- struct members may only be appended`);
            continue;
        }
        matched.add(n);
        comparePositioned(errs, where, b, n);
    }
    for (const n of nm) {
        if (matched.has(n)) continue;
        if (!growable) {
            errs.push(`${where}: member ${n.label} added to a struct stored inline (only a struct that is a mapping value may gain members)`);
        } else if (pos(n) < baseEnd) {
            errs.push(`${where}: member ${n.label} inserted at slot ${n.slot}+${n.offset}, inside the baseline members -- members may only be appended`);
        }
    }
}

// One compilation of every source with the optimizer at `runs`, producing the outputs of `targets`
// only (so solc's code-size warning speaks of the runs each contract is actually built with).
function compileFor(runs, targets) {
    const outputSelection = {};
    for (const t of targets) {
        outputSelection[t.file] = outputSelection[t.file] || {};
        outputSelection[t.file][t.name] = ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'storageLayout'];
    }
    const input = {
        language: 'Solidity',
        sources: sources(),
        settings: {
            optimizer: { ...SETTINGS.optimizer, runs },
            evmVersion: SETTINGS.evmVersion,
            metadata: SETTINGS.metadata,
            outputSelection,
        },
    };
    const out = JSON.parse(solc.compile(JSON.stringify(input)));
    const errors = (out.errors || []).filter((e) => e.severity === 'error');
    if (errors.length) {
        throw new Error(errors.map((e) => e.formattedMessage).join('\n'));
    }
    return out;
}

function build() {
    if (solc.version() !== SETTINGS.compilerVersion) {
        throw new Error(`solc ${solc.version()} is installed; ${SETTINGS.compilerVersion} is pinned (npm ci)`);
    }
    const runsOf = (t) => (t.runs === undefined ? SETTINGS.optimizer.runs : t.runs);
    const outs = {};
    const warnings = [];
    for (const runs of [...new Set(TARGETS.map(runsOf))]) {
        outs[runs] = compileFor(runs, TARGETS.filter((t) => runsOf(t) === runs));
        warnings.push(...(outs[runs].errors || []).filter((e) => e.severity !== 'error'));
    }

    // name -> { filename: contents }
    const files = {};
    for (const t of TARGETS) {
        const o = outs[runsOf(t)];
        const c = o.contracts[t.file] && o.contracts[t.file][t.name];
        if (!c) throw new Error(`no output for ${t.file}:${t.name}`);
        files[`${t.name}.abi`] = JSON.stringify(c.abi) + '\n';
        if (t.kind === 'full') {
            const rt = c.evm.deployedBytecode.object;
            if (rt.length / 2 > MAX_RUNTIME) {
                throw new Error(`${t.name} runtime is ${rt.length / 2} B, above the EIP-170 limit of ${MAX_RUNTIME} B`);
            }
            files[`${t.name}.bin`] = c.evm.bytecode.object + '\n';
            files[`${t.name}.bin-runtime`] = rt + '\n';
            files[`${t.name}.storage.json`] = JSON.stringify(compactLayout(c.storageLayout), null, 1) + '\n';
        }
    }
    return { files, warnings };
}

// The compact storage layout of `file`:`name` compiled from `srcs`, without code generation
// (storageLayout needs only analysis, so this is fast).
function compileLayout(srcs, file, name) {
    const input = {
        language: 'Solidity',
        sources: srcs,
        settings: { evmVersion: SETTINGS.evmVersion, outputSelection: { [file]: { [name]: ['storageLayout'] } } },
    };
    const out = JSON.parse(solc.compile(JSON.stringify(input)));
    const errors = (out.errors || []).filter((e) => e.severity === 'error');
    if (errors.length) {
        throw new Error(errors.map((e) => e.formattedMessage).join('\n'));
    }
    return compactLayout(out.contracts[file][name].storageLayout);
}

// The compact storage layout of one SFC v2 contract compiled from patched sources. For verify.js's
// self-test.
function layoutOf(file, name, patches) {
    return compileLayout(sources(patches), file, name);
}

// ---------------------------------------------------------------------------------------------
// The v1 baseline. SFC v2 core is installed over the storage of the v1 SFC, so its append-only
// baseline is v1's layout, not v2's first build (docs/design/sfc-v2.md §5.2). The v1 layout comes
// from solc's storageLayout of the mechanical 0.8.20 port in ../contracts-0.8.20, which the node's
// TestV1StorageIsThePortLayout proves the deployed blob uses, slot by slot.
//
// PORT_BASELINES names the contracts whose layout/<name>.json must be EXACTLY the port's compiled
// layout: verify.js regenerates it and fails on any difference, so the baseline can never be a
// hand-edited file. `node compile.js --port-baselines` writes it.
const PORT_ROOT = path.join(ROOT, '..', 'contracts-0.8.20');
const PORT_BASELINES = { SFC: { file: 'contracts/sfc/SFC.sol', name: 'SFC' } };

function portSources() {
    const out = {};
    const read = (f) => ({ content: fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n') });
    // The port's unit names mirror the 0.5.17 tree (see ../contracts-0.8.20/compile.js):
    // contracts/... as-is, and lib/openzeppelin/... answers for @openzeppelin/contracts/... .
    for (const f of walk(path.join(PORT_ROOT, 'contracts'), [])) {
        out[path.relative(PORT_ROOT, f).split(path.sep).join('/')] = read(f);
    }
    const oz = path.join(PORT_ROOT, 'lib', 'openzeppelin');
    for (const f of walk(oz, [])) {
        out['@openzeppelin/contracts/' + path.relative(oz, f).split(path.sep).join('/')] = read(f);
    }
    return out;
}

// The compact storage layout of a contract of the v1 port.
function portLayout(file, name) {
    return compileLayout(portSources(), file, name);
}

// The exact text layout/<contract>.json must hold for a PORT_BASELINES contract.
function portBaselineText(contract) {
    const p = PORT_BASELINES[contract];
    return JSON.stringify(portLayout(p.file, p.name), null, 1) + '\n';
}

module.exports = {
    ROOT,
    SETTINGS,
    TARGETS,
    LAYOUT_COMPAT,
    PORT_BASELINES,
    build,
    layoutOf,
    portLayout,
    portBaselineText,
    checkAppendOnly,
    checkCompatTable,
};
