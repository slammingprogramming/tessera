// SPDX-License-Identifier: AGPL-3.0-or-later
// Prints the text that `tsr-calibrate paste` expects: node tools/dev/calibration-text.mjs [length]
// Copy the line and paste it into the game with Ctrl+V when the tool asks.
const length = Number(process.argv[2] ?? 4000);
const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
let out = '';
for (let i = 0; i < length; i++) out += alphabet[i % alphabet.length];
console.log(out);
