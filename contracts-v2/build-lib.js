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
    // cap, reactivation and pubkey rotation. One setting for every module, chosen for headroom.
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
const TARGETS = [
    { file: 'contracts/sfc/ConstantsManager.sol', name: 'ConstantsManager', kind: 'full' },
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
//    renamed only to __deprecated_<name>. New top-level variables may be added where no baseline
//    variable is (after the last one, or in place of a gap the author shrinks -- the gap rule is the
//    author's, this check only guarantees nothing baseline moved).
//  - Inside a type, recursively:
//      * the type label and encoding never change (this also pins every array length, which is part
//        of the label, and every mapping's key and value type labels);
//      * a type stored INLINE -- a top-level variable, a struct member, a static-array element, a
//        dynamic-array element (its size is the stride) or a mapping key -- keeps its exact size;
//      * the one place a size may grow is a STRUCT that is the value of a mapping: each of its
//        slots is reached by hashing, so members appended AFTER every baseline member touch no
//        existing data;
//      * every baseline struct member keeps its slot, offset and type (recursively), renamed only to
//        __deprecated_<name>; members are only ever appended, never inserted, removed or reordered.
function checkAppendOnly(contract, base, now) {
    const errs = [];
    for (const b of base) {
        const n = now.find((x) => x.slot === b.slot && x.offset === b.offset);
        if (!n) {
            errs.push(`${contract}: baseline variable ${b.label} at slot ${b.slot}+${b.offset} is gone`);
            continue;
        }
        comparePositioned(errs, contract, b, n);
    }
    return errs;
}

// A baseline variable or struct member `b` and whatever now sits at its slot and offset.
function comparePositioned(errs, where, b, n) {
    if (n.type !== b.type || n.encoding !== b.encoding) {
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
    if (n.type !== b.type || n.encoding !== b.encoding) {
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

function build() {
    if (solc.version() !== SETTINGS.compilerVersion) {
        throw new Error(`solc ${solc.version()} is installed; ${SETTINGS.compilerVersion} is pinned (npm ci)`);
    }
    const input = {
        language: 'Solidity',
        sources: sources(),
        settings: {
            optimizer: SETTINGS.optimizer,
            evmVersion: SETTINGS.evmVersion,
            metadata: SETTINGS.metadata,
            outputSelection: {
                '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'storageLayout'] },
            },
        },
    };
    const out = JSON.parse(solc.compile(JSON.stringify(input)));
    const errors = (out.errors || []).filter((e) => e.severity === 'error');
    if (errors.length) {
        throw new Error(errors.map((e) => e.formattedMessage).join('\n'));
    }
    const warnings = (out.errors || []).filter((e) => e.severity !== 'error');

    // name -> { filename: contents }
    const files = {};
    for (const t of TARGETS) {
        const c = out.contracts[t.file] && out.contracts[t.file][t.name];
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

// The compact storage layout of one contract compiled from patched sources, without code
// generation (storageLayout needs only analysis, so this is fast). For verify.js's self-test.
function layoutOf(file, name, patches) {
    const input = {
        language: 'Solidity',
        sources: sources(patches),
        settings: { evmVersion: SETTINGS.evmVersion, outputSelection: { [file]: { [name]: ['storageLayout'] } } },
    };
    const out = JSON.parse(solc.compile(JSON.stringify(input)));
    const errors = (out.errors || []).filter((e) => e.severity === 'error');
    if (errors.length) {
        throw new Error(errors.map((e) => e.formattedMessage).join('\n'));
    }
    return compactLayout(out.contracts[file][name].storageLayout);
}

module.exports = { ROOT, SETTINGS, TARGETS, build, layoutOf, checkAppendOnly };
