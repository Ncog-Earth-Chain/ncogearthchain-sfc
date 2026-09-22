// The CI gate for SFC v2 (GOV-01b "CI byte-compare"). Fails (exit 1) unless:
//
//  1. a fresh build is BYTE-IDENTICAL to the committed out/ -- every abi, bin, bin-runtime and
//     storage layout. Possible only because the build carries no metadata hash; see build-lib.js.
//  2. every storage layout is APPEND-ONLY against its committed baseline in layout/, RECURSIVELY:
//     each top-level variable of the baseline keeps its slot, offset and type; inside every type,
//     each struct member keeps its slot, offset and type, array lengths and inline sizes are
//     frozen, and the only growth allowed is members appended to a struct that is a mapping value.
//     Renaming is allowed only to __deprecated_<name>. The full rule is checkAppendOnly in
//     build-lib.js. It matters because SFC v2 modules are upgraded in place
//     (NodeDriverAuth.upgradeCode) over their own storage, and SFC v2 core over v1's.
//  3. optionally (--node <path to the node repo>), the node's committed copies under
//     ncogearthchain/genesis/sfc/testdata/v2/ are byte-identical to out/, so the artefact the node's
//     compatibility test pins is the artefact this repo builds.
//  4. the gate of step 2 still has teeth: a SELF-TEST compiles deliberately broken variants of the
//     committed sources (a reordered struct inside a mapping, a retyped member, a resized array, a
//     member added to an inline struct) and requires step 2's check to refuse each one, and compiles
//     a legal append (a member added at the end of a struct that is a mapping value) and requires it
//     to be accepted. A check that has gone blind fails verify instead of passing everything.
//
//   npm run verify
//   node verify.js --node ../ncogearthchain
'use strict';
const fs = require('fs');
const path = require('path');
const { ROOT, build, layoutOf, checkAppendOnly } = require('./build-lib');

let failed = false;
function fail(msg) {
    console.error('FAIL ' + msg);
    failed = true;
}

const { files } = build();
const outDir = path.join(ROOT, 'out');

// 1. fresh build == committed out/
for (const name of Object.keys(files).sort()) {
    const p = path.join(outDir, name);
    if (!fs.existsSync(p)) {
        fail(`out/${name} is not committed`);
        continue;
    }
    const committed = fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
    if (committed !== files[name]) fail(`out/${name} differs from a fresh build (run npm run build and commit)`);
    else console.log(`ok   out/${name}`);
}
for (const name of fs.readdirSync(outDir)) {
    if (!(name in files)) fail(`out/${name} is committed but no longer built`);
}

// 2. append-only storage
const layoutDir = path.join(ROOT, 'layout');
function baseline(contract) {
    const basePath = path.join(layoutDir, contract + '.json');
    if (!fs.existsSync(basePath)) {
        fail(`layout/${contract}.json missing: commit the current layout as the baseline`);
        return null;
    }
    const base = JSON.parse(fs.readFileSync(basePath, 'utf8'));
    if (base.some((b) => typeof b.bytes !== 'number' || typeof b.encoding !== 'string')) {
        fail(`layout/${contract}.json is in the old label-only format, which cannot see struct members: regenerate it from out/${contract}.storage.json`);
        return null;
    }
    return base;
}
for (const name of Object.keys(files).filter((n) => n.endsWith('.storage.json'))) {
    const contract = name.replace(/\.storage\.json$/, '');
    const base = baseline(contract);
    if (!base) continue;
    const errs = checkAppendOnly(contract, base, JSON.parse(files[name]));
    for (const e of errs) fail(e);
    if (!errs.length) {
        console.log(`ok   ${contract} storage is append-only against layout/${contract}.json (${base.length} baseline variables, struct members included)`);
    }
}

// 3. the node's committed copies
const nodeIdx = process.argv.indexOf('--node');
if (nodeIdx > 0) {
    const nodeDir = path.join(process.argv[nodeIdx + 1], 'ncogearthchain', 'genesis', 'sfc', 'testdata', 'v2');
    for (const name of fs.readdirSync(nodeDir).filter((n) => n.endsWith('.abi') || n.endsWith('.bin-runtime'))) {
        const theirs = fs.readFileSync(path.join(nodeDir, name), 'utf8').replace(/\r\n/g, '\n');
        if (!(name in files)) fail(`node testdata/v2/${name} is not an artefact of this build`);
        else if (theirs !== files[name]) fail(`node testdata/v2/${name} differs from this build`);
        else console.log(`ok   node testdata/v2/${name}`);
    }
}

// 4. self-test of step 2. Each case rewrites declarations (and, where the compiler needs it, the one
// expression that uses them) in the committed ConstantsManager source and compiles only its storage
// layout. Every `from` must still be in the source, so a refactor of ConstantsManager that removes
// one fails here rather than quietly turning a case into a no-op. `refuse` is the place the gate
// must name (the start of one of its messages); null marks the legal case, which must pass.
const CM_FILE = 'contracts/sfc/ConstantsManager.sol';
const NL = '\n';
const SELF_TEST = [
    {
        name: 'History members reordered (uint8 head moved in front of the ring)',
        edits: [['Change[8] ring;' + NL + '        uint8 head;', 'uint8 head;' + NL + '        Change[8] ring;']],
        refuse: 'ConstantsManager._history[key]: slot 0+0 was struct ConstantsManager.Change[8] ring, is now uint8 head',
    },
    {
        name: 'Change.previous retyped in place, uint192 -> uint160 (same slot, same offset)',
        edits: [
            ['uint192 previous;', 'uint160 previous;'],
            ['uint192(current)', 'uint160(current)'],
        ],
        refuse: 'ConstantsManager._history[key].ring[i]: slot 0+8 was uint192 previous, is now uint160 previous',
    },
    {
        name: 'Change.time resized uint64 -> uint32 (which also moves previous)',
        edits: [
            ['uint64 time;', 'uint32 time;'],
            ['uint64(block.timestamp)', 'uint32(block.timestamp)'],
        ],
        refuse: 'ConstantsManager._history[key].ring[i]: slot 0+0 was uint64 time, is now uint32 time',
    },
    {
        name: 'Change members reordered (previous in front of time)',
        edits: [
            ['uint64 time;' + NL + '        uint192 previous;', 'uint192 previous;' + NL + '        uint64 time;'],
            ['Change(uint64(block.timestamp), uint192(current))', 'Change({time: uint64(block.timestamp), previous: uint192(current)})'],
        ],
        refuse: 'ConstantsManager._history[key].ring[i]: slot 0+0 was uint64 time, is now uint192 previous',
    },
    {
        name: 'History.ring resized Change[8] -> Change[9]',
        edits: [['Change[8] ring;', 'Change[9] ring;']],
        refuse: 'ConstantsManager._history[key]: slot 0+0 was struct ConstantsManager.Change[8] ring, is now struct ConstantsManager.Change[9] ring',
    },
    {
        name: 'member appended to Change, which is stored inline in the ring',
        edits: [
            ['uint192 previous;' + NL + '    }', 'uint192 previous;' + NL + '        uint256 appended;' + NL + '    }'],
            ['Change(uint64(block.timestamp), uint192(current))', 'Change(uint64(block.timestamp), uint192(current), 0)'],
        ],
        refuse: 'ConstantsManager._history[key].ring[i]: member appended added to a struct stored inline',
    },
    {
        name: 'top-level _values resized uint256[64] -> uint256[65]',
        edits: [['uint256[64] private _values;', 'uint256[65] private _values;']],
        refuse: 'ConstantsManager: slot 102+0 was uint256[64] _values, is now uint256[65] _values',
    },
    {
        name: 'LEGAL: member appended at the end of History, a mapping value',
        edits: [['uint8 head;' + NL + '    }', 'uint8 head;' + NL + '        uint256 appended;' + NL + '    }']],
        refuse: null,
    },
];
const cmBase = baseline('ConstantsManager');
if (cmBase) {
    const src = fs.readFileSync(path.join(ROOT, CM_FILE), 'utf8').replace(/\r\n/g, NL);
    const unmodified = checkAppendOnly('ConstantsManager', cmBase, layoutOf(CM_FILE, 'ConstantsManager', {}));
    if (unmodified.length) fail(`self-test: the unmodified source is refused: ${unmodified.join('; ')}`);
    for (const c of SELF_TEST) {
        const missing = c.edits.filter(([from]) => !src.includes(from));
        if (missing.length) {
            fail(`self-test "${c.name}": ${CM_FILE} no longer contains ${JSON.stringify(missing[0][0])}; update the case`);
            continue;
        }
        const patched = { [CM_FILE]: (s) => c.edits.reduce((acc, [from, to]) => acc.replace(from, to), s) };
        let errs;
        try {
            errs = checkAppendOnly('ConstantsManager', cmBase, layoutOf(CM_FILE, 'ConstantsManager', patched));
        } catch (e) {
            fail(`self-test "${c.name}": the patched source does not compile, so the case tests nothing: ${e.message}`);
            continue;
        }
        if (c.refuse === null) {
            if (errs.length) fail(`self-test "${c.name}": a legal append was refused: ${errs.join('; ')}`);
            else console.log(`ok   self-test: accepted ${c.name}`);
        } else if (!errs.some((e) => e.startsWith(c.refuse))) {
            fail(`self-test "${c.name}": the append-only gate did not refuse it at ${c.refuse} (it reported ${JSON.stringify(errs)})`);
        } else {
            console.log(`ok   self-test: refused ${c.name}: ${errs.find((e) => e.startsWith(c.refuse))}`);
        }
    }
}

if (failed) process.exit(1);
console.log('verify: OK');
