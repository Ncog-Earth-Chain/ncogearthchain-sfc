// Compiles the solc-0.8.20 port of the four genesis predeploys with the exact settings the deployed
// blobs were built with (see README.md): solc-js 0.8.20, optimizer on, runs 10000, evmVersion
// shanghai, default metadata (CBOR trailer with an IPFS hash). Writes out/<Contract>.abi,
// out/<Contract>.bin (creation code) and out/<Contract>.bin-runtime (runtime code), hex without 0x.
//
//   npm install          # installs the solc pinned in package.json / package-lock.json
//   npm run build
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const solc = require('solc');

const root = __dirname;
const RUNS = 10000;
const EVM_VERSION = 'shanghai';
const CONTRACTS = ['SFC', 'NodeDriver', 'NodeDriverAuth', 'NetworkInitializer'];

function walk(dir, acc) {
    for (const f of fs.readdirSync(dir)) {
        const p = path.join(dir, f);
        if (fs.statSync(p).isDirectory()) walk(p, acc);
        else if (p.endsWith('.sol')) acc.push(p);
    }
    return acc;
}

// Source unit names mirror the 0.5.17 tree so the import statements are unchanged:
// contracts/... as-is, and lib/openzeppelin/... answers for @openzeppelin/contracts/... .
const sources = {};
for (const f of walk(path.join(root, 'contracts'), [])) {
    const unit = path.relative(root, f).split(path.sep).join('/');
    sources[unit] = { content: fs.readFileSync(f, 'utf8') };
}
for (const f of walk(path.join(root, 'lib', 'openzeppelin'), [])) {
    const unit = '@openzeppelin/contracts/' + path.relative(path.join(root, 'lib', 'openzeppelin'), f).split(path.sep).join('/');
    sources[unit] = { content: fs.readFileSync(f, 'utf8') };
}

const input = {
    language: 'Solidity',
    sources,
    settings: {
        optimizer: { enabled: true, runs: RUNS },
        evmVersion: EVM_VERSION,
        outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object'] } },
    },
};

function findImports(p) {
    return sources[p] ? { contents: sources[p].content } : { error: 'not found: ' + p };
}

const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
const errors = (out.errors || []).filter((e) => e.severity === 'error');
if (errors.length) {
    console.error(errors.map((e) => e.formattedMessage).join('\n'));
    process.exit(1);
}

const outDir = path.join(root, 'out');
fs.mkdirSync(outDir, { recursive: true });
console.log('solc-js', solc.version(), '| optimizer runs', RUNS, '| evmVersion', EVM_VERSION);
for (const file of Object.keys(out.contracts)) {
    for (const name of Object.keys(out.contracts[file])) {
        if (!CONTRACTS.includes(name)) continue;
        const c = out.contracts[file][name];
        const bin = c.evm.bytecode.object;
        const rt = c.evm.deployedBytecode.object;
        fs.writeFileSync(path.join(outDir, name + '.abi'), JSON.stringify(c.abi) + '\n');
        fs.writeFileSync(path.join(outDir, name + '.bin'), bin + '\n');
        fs.writeFileSync(path.join(outDir, name + '.bin-runtime'), rt + '\n');
        const sha = crypto.createHash('sha256').update(Buffer.from(rt, 'hex')).digest('hex');
        console.log(`${name.padEnd(19)} ${file}  bin ${bin.length / 2} B  bin-runtime ${rt.length / 2} B  sha256(bin-runtime) ${sha}`);
    }
}
