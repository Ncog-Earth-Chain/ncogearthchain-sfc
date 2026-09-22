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

function sources() {
    const out = {};
    for (const f of walk(path.join(ROOT, 'contracts'), [])) {
        const unit = path.relative(ROOT, f).split(path.sep).join('/');
        // Normalise line endings so a CRLF checkout builds the same bytes as an LF one. With
        // bytecodeHash none the source text does not reach the code anyway, but the AST ids and
        // hence nothing else should depend on the platform either.
        out[unit] = { content: fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n') };
    }
    return out;
}

// Storage layout reduced to what the append-only rule is about.
function compactLayout(layout) {
    return layout.storage.map((s) => ({
        slot: s.slot,
        offset: s.offset,
        label: s.label,
        type: layout.types[s.type].label,
    }));
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

module.exports = { ROOT, SETTINGS, TARGETS, build };
