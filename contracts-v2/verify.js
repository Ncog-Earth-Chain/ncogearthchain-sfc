// The CI gate for SFC v2 (GOV-01b "CI byte-compare"). Fails (exit 1) unless:
//
//  1. a fresh build is BYTE-IDENTICAL to the committed out/ -- every abi, bin, bin-runtime and
//     storage layout. Possible only because the build carries no metadata hash; see build-lib.js.
//  2. every storage layout is APPEND-ONLY against its committed baseline in layout/: each variable
//     of the baseline is still at the same slot and offset with the same type. Renaming is allowed
//     (a retired variable becomes __deprecated_<name>); moving, retyping or deleting is not, because
//     SFC v2 modules are upgraded in place (NodeDriverAuth.upgradeCode) over their own storage.
//  3. optionally (--node <path to the node repo>), the node's committed copies under
//     ncogearthchain/genesis/sfc/testdata/v2/ are byte-identical to out/, so the artefact the node's
//     compatibility test pins is the artefact this repo builds.
//
//   npm run verify
//   node verify.js --node ../ncogearthchain
'use strict';
const fs = require('fs');
const path = require('path');
const { ROOT, build } = require('./build-lib');

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
for (const name of Object.keys(files).filter((n) => n.endsWith('.storage.json'))) {
    const contract = name.replace(/\.storage\.json$/, '');
    const basePath = path.join(layoutDir, contract + '.json');
    if (!fs.existsSync(basePath)) {
        fail(`layout/${contract}.json missing: commit the current layout as the baseline`);
        continue;
    }
    const base = JSON.parse(fs.readFileSync(basePath, 'utf8'));
    const now = JSON.parse(files[name]);
    for (const b of base) {
        const n = now.find((x) => x.slot === b.slot && x.offset === b.offset);
        if (!n) {
            fail(`${contract}: baseline variable ${b.label} at slot ${b.slot}+${b.offset} is gone`);
        } else if (n.type !== b.type) {
            fail(`${contract}: slot ${b.slot}+${b.offset} was ${b.type} ${b.label}, is now ${n.type} ${n.label}`);
        } else if (n.label !== b.label && n.label !== '__deprecated_' + b.label) {
            fail(`${contract}: slot ${b.slot}+${b.offset} renamed ${b.label} -> ${n.label} (only __deprecated_${b.label} is allowed)`);
        }
    }
    console.log(`ok   ${contract} storage is append-only against layout/${contract}.json (${base.length} baseline variables)`);
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

if (failed) process.exit(1);
console.log('verify: OK');
