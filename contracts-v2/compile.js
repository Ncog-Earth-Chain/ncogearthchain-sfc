// Builds SFC v2 into out/ (committed). See build-lib.js for the settings and README.md for why.
//
//   npm ci
//   npm run build
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { ROOT, SETTINGS, build } = require('./build-lib');

const { files, warnings } = build();
for (const w of warnings) console.error(w.formattedMessage);

const outDir = path.join(ROOT, 'out');
fs.mkdirSync(outDir, { recursive: true });
console.log(`solc-js ${SETTINGS.compilerVersion} | optimizer runs ${SETTINGS.optimizer.runs} | evmVersion ${SETTINGS.evmVersion} | metadata hash none`);
for (const name of Object.keys(files).sort()) {
    fs.writeFileSync(path.join(outDir, name), files[name]);
    if (name.endsWith('.bin-runtime')) {
        const hex = files[name].trim();
        const sha = crypto.createHash('sha256').update(Buffer.from(hex, 'hex')).digest('hex');
        console.log(`${name.padEnd(32)} ${String(hex.length / 2).padStart(6)} B  sha256 ${sha}`);
    }
}
