// Reproduces this repository's OWN truffle build -- build/contracts/*.json, solc
// 0.5.17+commit.d19bba13, optimizer runs 10000, evmVersion istanbul -- byte for byte, without
// truffle and without node_modules for @openzeppelin.
//
// Why it exists: the port next door claims to be a port of THIS source. That claim is only worth
// something if this source still compiles to the artefacts committed beside it, i.e. if nobody has
// edited a .sol since the build was made. This is the check.
//
//   npm install --no-save solc@0.5.17
//   node reproduce-0.5.17.js ..            # .. = the repo root holding build/contracts
//
// Two details make it reproduce rather than merely compile:
//
//   * SOURCE UNIT NAMES. The metadata trailer at the end of every blob is a swarm hash of the
//     metadata JSON, and that JSON lists the source unit names. Truffle 5 recorded absolute paths --
//     "/C/Ncog/ncogearthchain-sfc/contracts/sfc/SFC.sol" -- so those are the names used here, read
//     back out of each artefact's own `sourcePath`. Use anything else and the code matches while the
//     last 43 bytes do not.
//   * SOURCES FROM THE ARTEFACTS. Every artefact carries the exact text it was compiled from in its
//     `source` field, @openzeppelin's SafeMath included. Reading them from there rather than from
//     disk means no dependency install, and it is also what lets the script report an edited .sol as
//     a mismatch instead of silently compiling the edited text.
'use strict';
const fs = require('fs');
const path = require('path');

const repo = path.resolve(process.argv[2] || '..');
const solc = require(process.env.SOLC_0517 || 'solc');
if (!solc.version().startsWith('0.5.17')) {
    console.error('need solc 0.5.17, got ' + solc.version() + '  (npm install --no-save solc@0.5.17)');
    process.exit(2);
}

const build = path.join(repo, 'build', 'contracts');
const sources = {};
for (const f of fs.readdirSync(build)) {
    if (!f.endsWith('.json')) continue;
    const j = JSON.parse(fs.readFileSync(path.join(build, f), 'utf8'));
    if (!j.source || !j.sourcePath) continue;
    const p = j.sourcePath.replace(new RegExp(String.fromCharCode(92, 92), 'g'), '/');
    const unit = p.startsWith('C:/Ncog/') ? '/C/Ncog/' + p.slice('C:/Ncog/'.length) : p;
    sources[unit] = { content: j.source };
}

const input = {
    language: 'Solidity',
    sources,
    settings: {
        optimizer: { enabled: true, runs: 10000 },
        evmVersion: 'istanbul',
        outputSelection: { '*': { '*': ['evm.bytecode.object', 'evm.deployedBytecode.object'] } },
    },
};

const out = JSON.parse(solc.compile(JSON.stringify(input)));
const errors = (out.errors || []).filter((e) => e.severity === 'error');
if (errors.length) {
    console.error(errors.map((e) => e.formattedMessage).join('\n'));
    process.exit(1);
}

console.log('solc-js', solc.version(), '| optimizer runs 10000 | evmVersion istanbul');
let bad = 0;
for (const name of ['SFC', 'NodeDriver', 'NodeDriverAuth', 'NetworkInitializer']) {
    const file = Object.keys(out.contracts).find((f) => out.contracts[f][name]);
    const got = '0x' + out.contracts[file][name].evm.deployedBytecode.object;
    const want = JSON.parse(fs.readFileSync(path.join(build, name + '.json'), 'utf8')).deployedBytecode;
    const ok = got === want;
    if (!ok) bad++;
    console.log(`${name.padEnd(19)} ${((got.length - 2) / 2).toString().padStart(6)} B  ` +
        (ok ? `BYTE-IDENTICAL to build/contracts/${name}.json` : `DIFFERS (expected ${(want.length - 2) / 2} B)`));
}
process.exit(bad ? 1 : 0);
