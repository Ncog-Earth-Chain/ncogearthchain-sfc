// The CI gate for SFC v2 (GOV-01b "CI byte-compare"). Fails (exit 1) unless:
//
//  1. a fresh build is BYTE-IDENTICAL to the committed out/ -- every abi, bin, bin-runtime and
//     storage layout. Possible only because the build carries no metadata hash; see build-lib.js.
//  2. every storage layout is APPEND-ONLY against its committed baseline in layout/, RECURSIVELY:
//     each top-level variable of the baseline keeps its slot, offset and type; inside every type,
//     each struct member keeps its slot, offset and type, array lengths and inline sizes are
//     frozen, and the only growth allowed is members appended to a struct that is a mapping value.
//     Renaming is allowed only to __deprecated_<name>. A gap may be used only from the front,
//     keeping its end slot. The only other change allowed is a reviewed LAYOUT_COMPAT entry (today:
//     v1's slot 0 under v2's Initializable). Types are compared by storage identity (typeKey): the
//     contract that declares a struct or enum, and a contract type's name, may change. The full
//     rule is checkAppendOnly in build-lib.js. It matters because SFC v2 modules are upgraded in
//     place (NodeDriverAuth.upgradeCode) over their own storage, and SFC v2 core over v1's. A
//     baseline that is v1's layout (PORT_BASELINES: layout/SFC.json) must be exactly the port's
//     compiled layout, so it cannot be edited by hand.
//  3. optionally (--node <path to the node repo>), the node's committed copies under
//     ncogearthchain/genesis/sfc/testdata/v2/ are byte-identical to out/, so the artefact the node's
//     compatibility test pins is the artefact this repo builds.
//  4. the gate of step 2 still has teeth, and is not stricter than the design: a SELF-TEST compiles
//     deliberately broken variants of the committed sources (a reordered struct inside a mapping, a
//     retyped member, a resized array, a member added to an inline struct, v1's slot 0 widened or
//     the slot-0 exception used elsewhere, a gap grown or moving its end, a struct renamed, a
//     contract type turned into address) and requires step 2's check to refuse each one, and
//     compiles the legal changes (a member appended to a struct that is a mapping value, v2's
//     Initializable/Ownable over the port's v1 slots 0..101, a gap used from the front, structs
//     declared in a base contract, a contract type retyped to another interface) and requires each
//     to be accepted. A check that has gone blind, or that refuses what the design prescribes, fails
//     verify.
//
//   npm run verify
//   node verify.js --node ../ncogearthchain
'use strict';
const fs = require('fs');
const path = require('path');
const {
    ROOT,
    PORT_BASELINES,
    build,
    layoutOf,
    portLayout,
    portBaselineText,
    checkAppendOnly,
    checkCompatTable,
} = require('./build-lib');

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
        fail(
            contract in PORT_BASELINES
                ? `layout/${contract}.json missing: its baseline is the v1 port's layout; run node compile.js --port-baselines and commit it`
                : `layout/${contract}.json missing: commit the current layout as the baseline`,
        );
        return null;
    }
    const base = JSON.parse(fs.readFileSync(basePath, 'utf8'));
    if (base.some((b) => typeof b.bytes !== 'number' || typeof b.encoding !== 'string')) {
        fail(`layout/${contract}.json is in the old label-only format, which cannot see struct members: regenerate it from out/${contract}.storage.json`);
        return null;
    }
    return base;
}
for (const e of checkCompatTable()) fail(e);
// A baseline that is v1's layout (PORT_BASELINES, today the SFC) must be exactly what the port
// compiles to, so it can never be edited by hand to let a layout through.
for (const contract of Object.keys(PORT_BASELINES)) {
    const p = path.join(layoutDir, contract + '.json');
    if (!fs.existsSync(p)) {
        console.log(`--   layout/${contract}.json not committed yet (it arrives with SFC core; node compile.js --port-baselines)`);
        continue;
    }
    if (fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n') !== portBaselineText(contract)) {
        fail(`layout/${contract}.json is not the v1 port's compiled layout: regenerate it with node compile.js --port-baselines, never by hand`);
    } else {
        console.log(`ok   layout/${contract}.json is the v1 port's compiled layout`);
    }
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
// expression that uses them) in the committed sources and compiles only the storage layout of
// ConstantsManager. An edit is [from, to] in ConstantsManager.sol, or [from, to, unit] in another
// source unit. Every `from` must still be in its source, so a refactor that removes one fails here
// rather than quietly turning a case into a no-op. `refuse` is the place the gate must name (the
// start of one of its messages); null marks a legal case, which must pass.
//
// The baseline a case is checked against is, by `base`:
//   absent             the committed layout/ConstantsManager.json;
//   'v1'               the v1 SFC's slots 0..101 (Initializable and Ownable) from the port's compiled
//                      layout, the prefix SFC v2 core must be installed over (design §5.1);
//   { edits: [...] }   ConstantsManager compiled with those edits, for a rule that needs a variable
//                      the committed source does not have (a trailing gap, a contract-typed slot).
const CM_FILE = 'contracts/sfc/ConstantsManager.sol';
const INIT_FILE = 'contracts/common/Initializable.sol';
const OWN_FILE = 'contracts/ownership/Ownable.sol';
const NL = '\n';
const HISTORY_DECL = 'mapping(Param => History) private _history;';
// An edit that declares `decl` right after `_history`, the last variable (slot 167).
const afterHistory = (decl) => [HISTORY_DECL, HISTORY_DECL + NL + '    ' + decl];
const IMPORT_IFACES = [
    'import {Decimal} from "../common/Decimal.sol";',
    'import {Decimal} from "../common/Decimal.sol";' +
        NL +
        'import {INodeDriverAuth} from "../interfaces/INodeDriverAuth.sol";' +
        NL +
        'import {ISFCNodeSurface} from "../interfaces/ISFCNodeSurface.sol";',
];
const STRUCTS =
    '    struct Change {' + NL + '        uint64 time;' + NL + '        uint192 previous;' + NL + '    }' + NL + NL +
    '    /// @dev The last HISTORY_SLOTS changes of one parameter, oldest at `head`.' + NL +
    '    struct History {' + NL + '        Change[8] ring;' + NL + '        uint8 head;' + NL + '    }';
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

    // LAYOUT_COMPAT (build-lib.js): v1's slot 0 under v2's Initializable, and nothing else.
    {
        name: "LEGAL: v2 Initializable/Ownable over the v1 port's slots 0..101 (bool initialized -> uint8 _initialized, initializing -> _initializing)",
        base: 'v1',
        edits: [],
        refuse: null,
    },
    {
        name: "v2's _initialized widened to uint16 over v1's bool initialized (slot 0)",
        base: 'v1',
        edits: [
            ['uint8 private _initialized;', 'uint16 private _initialized;', INIT_FILE],
            ['return _initialized;', 'return uint8(_initialized);', INIT_FILE],
        ],
        refuse: 'SFC: slot 0+0 was bool initialized, is now uint16 _initialized',
    },
    {
        name: 'bool initialized -> uint8 _initialized at slot 167, not slot 0',
        base: { edits: [afterHistory('bool private initialized;')] },
        edits: [afterHistory('uint8 private _initialized;')],
        refuse: 'ConstantsManager: slot 167+0 was bool initialized, is now uint8 _initialized',
    },

    // Gaps are used only from the front, keeping their end slot.
    {
        name: "LEGAL: Ownable's gap used from the front (address _pendingOwner; uint256[49] ______gap)",
        edits: [['uint256[50] private ______gap;', 'address private _pendingOwner;' + NL + '    uint256[49] private ______gap;', OWN_FILE]],
        refuse: null,
    },
    {
        name: "Ownable's gap grown to uint256[51]",
        edits: [['uint256[50] private ______gap;', 'uint256[51] private ______gap;', OWN_FILE]],
        refuse: 'ConstantsManager: slot 52+0 was uint256[50] ______gap, is now uint256[51] ______gap (a gap is used only from the front',
    },
    {
        name: 'a trailing gap used from the front but shrunk one slot too many (its end moves from 176 to 175)',
        base: { edits: [afterHistory('uint256[10] private __gap;')] },
        edits: [afterHistory('address private _x;' + NL + '    uint256[8] private __gap;')],
        refuse: 'ConstantsManager: slot 167+0 was uint256[10] __gap, is now address _x (a gap is used only from the front',
    },
    {
        name: 'LEGAL: a trailing gap used from the front, keeping its end slot',
        base: { edits: [afterHistory('uint256[10] private __gap;')] },
        edits: [afterHistory('address private _x;' + NL + '    uint256[9] private __gap;')],
        refuse: null,
    },

    // Type identity is storage identity (typeKey in build-lib.js).
    {
        name: 'LEGAL: Change and History declared in a base contract instead (struct ConstantsManagerTypes.History), as SFCStorageV1 will hold v1\'s structs',
        edits: [
            [STRUCTS, ''],
            [
                'contract ConstantsManager is Initializable, Ownable {',
                'abstract contract ConstantsManagerTypes {' + NL + STRUCTS + NL + '}' + NL + NL +
                    'contract ConstantsManager is ConstantsManagerTypes, Initializable, Ownable {',
            ],
        ],
        refuse: null,
    },
    {
        name: 'History renamed Hist (a struct keeps its own name)',
        edits: [
            ['struct History {', 'struct Hist {'],
            [HISTORY_DECL, 'mapping(Param => Hist) private _history;'],
            ['History storage h = _history[p];', 'Hist storage h = _history[p];'],
            ['History storage h = _history[p];', 'Hist storage h = _history[p];'],
        ],
        refuse: 'ConstantsManager: slot 166+0 was mapping(enum ConstantsManager.Param => struct ConstantsManager.History) _history, is now mapping(enum ConstantsManager.Param => struct ConstantsManager.Hist) _history',
    },
    {
        name: 'LEGAL: a contract-typed variable retyped to another interface (INodeDriverAuth -> ISFCNodeSurface), as v1\'s NodeDriverAuth node becomes INodeDriverAuth',
        base: { edits: [IMPORT_IFACES, afterHistory('INodeDriverAuth private _driver;')] },
        edits: [IMPORT_IFACES, afterHistory('ISFCNodeSurface private _driver;')],
        refuse: null,
    },
    {
        name: 'a contract-typed variable retyped to address',
        base: { edits: [IMPORT_IFACES, afterHistory('INodeDriverAuth private _driver;')] },
        edits: [afterHistory('address private _driver;')],
        refuse: 'ConstantsManager: slot 167+0 was contract INodeDriverAuth _driver, is now address _driver',
    },
];

const sourceText = {};
const readUnit = (unit) => (sourceText[unit] ??= fs.readFileSync(path.join(ROOT, unit), 'utf8').replace(/\r\n/g, NL));
// Edits grouped by source unit, as build-lib's `patches`. Each edit replaces the first occurrence,
// in order, so two identical edits replace two occurrences.
function patchesFor(edits) {
    const byUnit = {};
    for (const [from, to, unit = CM_FILE] of edits) (byUnit[unit] ??= []).push([from, to]);
    const patches = {};
    for (const [unit, list] of Object.entries(byUnit)) {
        patches[unit] = (s) => list.reduce((acc, [from, to]) => acc.replace(from, to), s);
    }
    return patches;
}
const missingEdit = (edits) => edits.find(([from, , unit = CM_FILE]) => !readUnit(unit).includes(from));

// v1's Initializable and Ownable, as the port compiles them. Pinned, so the 'v1' cases can never
// pass against an empty or shifted baseline.
const V1_PREFIX = 'initialized@0+0,initializing@0+1,______gap@1+0,_owner@51+0,______gap@52+0';
function v1Prefix() {
    const p = portLayout(PORT_BASELINES.SFC.file, PORT_BASELINES.SFC.name).filter((v) => Number(v.slot) <= 101);
    const got = p.map((v) => `${v.label}@${v.slot}+${v.offset}`).join(',');
    if (got !== V1_PREFIX) {
        fail(`self-test: the port's slots 0..101 are ${got}, expected ${V1_PREFIX}`);
        return null;
    }
    return p;
}

const cmBase = baseline('ConstantsManager');
if (cmBase) {
    const unmodified = checkAppendOnly('ConstantsManager', cmBase, layoutOf(CM_FILE, 'ConstantsManager', {}));
    if (unmodified.length) fail(`self-test: the unmodified source is refused: ${unmodified.join('; ')}`);
    let v1;
    let accepted = 0;
    let refused = 0;
    for (const c of SELF_TEST) {
        const missing = missingEdit(c.edits.concat(c.base && c.base.edits ? c.base.edits : []));
        if (missing) {
            fail(`self-test "${c.name}": ${missing[2] || CM_FILE} no longer contains ${JSON.stringify(missing[0])}; update the case`);
            continue;
        }
        let contract = 'ConstantsManager';
        let errs;
        try {
            let base = cmBase;
            if (c.base === 'v1') {
                if (v1 === undefined) v1 = v1Prefix();
                if (!v1) continue;
                base = v1;
                contract = 'SFC';
            } else if (c.base) {
                base = layoutOf(CM_FILE, 'ConstantsManager', patchesFor(c.base.edits));
            }
            errs = checkAppendOnly(contract, base, layoutOf(CM_FILE, 'ConstantsManager', patchesFor(c.edits)));
        } catch (e) {
            fail(`self-test "${c.name}": a patched source does not compile, so the case tests nothing: ${e.message}`);
            continue;
        }
        if (c.refuse === null) {
            if (errs.length) fail(`self-test "${c.name}": a legal layout was refused: ${errs.join('; ')}`);
            else {
                accepted++;
                console.log(`ok   self-test: accepted ${c.name}`);
            }
        } else if (!errs.some((e) => e.startsWith(c.refuse))) {
            fail(`self-test "${c.name}": the append-only gate did not refuse it at ${c.refuse} (it reported ${JSON.stringify(errs)})`);
        } else {
            refused++;
            console.log(`ok   self-test: refused ${c.name}: ${errs.find((e) => e.startsWith(c.refuse))}`);
        }
    }
    console.log(`--   self-test: ${refused} refused and ${accepted} accepted, of ${SELF_TEST.length} cases`);
}

if (failed) process.exit(1);
console.log('verify: OK');
