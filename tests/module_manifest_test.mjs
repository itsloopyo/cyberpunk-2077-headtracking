// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo

import fs from "node:fs";

function read(path) {
  return fs.readFileSync(path, "utf8");
}

function addMatches(set, content, pattern) {
  for (const match of content.matchAll(pattern)) set.add(match[1]);
}

function compare(label, expected, actual) {
  const missing = [...expected].filter((name) => !actual.has(name)).sort();
  const extra = [...actual].filter((name) => !expected.has(name)).sort();
  if (missing.length > 0) throw new Error(`${label} is missing: ${missing.join(", ")}`);
  if (extra.length > 0) {
    throw new Error(`${label} lists modules init.lua never requires: ${extra.join(", ")}`);
  }
}

const required = new Set();
const queue = [];

function scan(path) {
  const discovered = new Set();
  addMatches(discovered, read(path), /(?:safeRequire|require)\("modules\/([\w]+)"\)/g);
  for (const name of discovered) {
    const file = `${name}.lua`;
    if (!fs.existsSync(`modules/${file}`)) throw new Error(`${path} requires missing modules/${file}`);
    if (!required.has(file)) {
      required.add(file);
      queue.push(file);
    }
  }
}

scan("init.lua");
while (queue.length > 0) scan(`modules/${queue.pop()}`);
if (required.size === 0) throw new Error("parsed no module requires from init.lua");

const manifest = new Set(
  JSON.parse(read("launcher-manifest.json")).files
    .map((entry) => entry.source)
    .filter((source) => source.startsWith("modules/"))
    .map((source) => source.slice("modules/".length)),
);
compare("launcher-manifest.json files[]", required, manifest);

const packager = new Set();
addMatches(packager, read("scripts/package-release.ps1"), /"modules\\([\w]+\.lua)"/g);
compare("package-release.ps1 $requiredModFiles", required, packager);

console.log(`Module manifest OK: ${required.size} modules, all three lists agree`);
