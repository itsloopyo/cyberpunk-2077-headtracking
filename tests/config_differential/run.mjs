// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const defaults = {enabled:true, position_enabled:true, local_smoothing:0, remote_smoothing:0.15,
  clamp_yaw:120, clamp_pitch:80, clamp_roll:45, crosshair_enabled:true,
  position_limit_x:0.3, position_limit_y_up:0.2, position_limit_y_down:0.05,
  position_limit_z_fwd:0.4, position_limit_z_back:0.1, yaw_mode:'world',
  saved_tracking_mode:'both', chase_camera_tracking:true, TrueFreeLook:false};
const cases = [{}, defaults, JSON.parse(fs.readFileSync('config.json','utf8'))];
for (const name of fs.readdirSync('tests/config_differential/data')) {
  cases.push(JSON.parse(fs.readFileSync(`tests/config_differential/data/${name}`, 'utf8')));
}
for (const key of Object.keys(defaults)) {
  for (const value of [true,false,0,0.01,0.08,0.49,0.6,1,10,90,180,1000,-1,'world','local','rot','pos','both','wrong',null,[],{}]) {
    cases.push({...defaults,[key]:value});
  }
}
for (const key of ['smoothing_factor','position_smoothing','sensitivity_yaw','crosshair_fov_degrees','unknown'])
  cases.push({...defaults,[key]:42});
function lua(value) {
  if (value === null) return 'nil';
  if (typeof value === 'object') return '{'+Object.entries(value).map(([k,v])=>`[${JSON.stringify(k)}]=${lua(v)}`).join(',')+'}';
  return JSON.stringify(value);
}
function run(command,args,input) {
  const result = spawnSync(command,args,{input,encoding:'utf8',maxBuffer:8*1024*1024});
  if(result.error) throw result.error;
  if(result.status !== 0) throw new Error(result.stderr || result.stdout);
  return result.stdout;
}
const native = run('native/build/bin/legacy_reader.exe',[],cases.map(c=>JSON.stringify(c)).join('\n')+'\n')
  .trim().split(/\r?\n/).map(JSON.parse);
const folder=fs.mkdtempSync(path.join(os.tmpdir(),'cyberpunk-legacy-'));
try {
  const script=path.join(folder,'oracle.lua');
  fs.writeFileSync(script, `
local cases = ${lua(cases)}
local Settings = dofile(arg[1])
local input
json = { decode = function() return input end }
io.open = function() return { read = function() return "object" end, close = function() end } end
local output = print
print = function() end
local function encode(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local items = {}
  for k, value in pairs(v) do items[#items+1] = string.format("%q", k)..":"..encode(value) end
  return "{"..table.concat(items,",").."}"
end
for i=0,${cases.length-1} do
  input=cases[tostring(i)]
  local settings = Settings.new()
  settings.save = function() return true end
  settings:load()
  output(encode(settings:getAll()))
end
`);
  const oracle=run('lua',[script,'tests/config_differential/oracle/settings.lua']).trim().split(/\r?\n/).map(JSON.parse);
  assert.equal(oracle.length,cases.length);
  for(let i=0;i<cases.length;i++) assert.deepEqual(native[i],oracle[i],`Legacy case ${i}: ${JSON.stringify(cases[i])}`);
  const published=run('lua',[script,'tests/config_differential/oracle/published_settings.lua']).trim().split(/\r?\n/).map(JSON.parse);
  for(let i=0;i<cases.length;i++) {
    for(const key of Object.keys(defaults).filter(key=>key !== 'TrueFreeLook'))
      assert.deepEqual(native[i][key],published[i][key],`Published reader case ${i}, ${key}`);
  }
  const migrated=run('native/build/bin/config_tests.exe',['--migrate-json'],cases.map(c=>JSON.stringify(c)).join('\n')+'\n')
    .trim().split(/\r?\n/).map(JSON.parse);
  for(let i=0;i<cases.length;i++) {
    const expected={...oracle[i],enable_on_startup:true};
    if(!expected.enabled && !expected.position_enabled) {
      expected.enabled=expected.saved_tracking_mode !== 'pos';
      expected.position_enabled=expected.saved_tracking_mode !== 'rot';
    }
    delete expected.saved_tracking_mode;
    delete expected.crosshair_enabled;
    if(expected.position_limit_y_down === 0.05) expected.position_limit_y_down=0.2;
    assert.deepEqual(migrated[i],expected,`Migration case ${i}: ${JSON.stringify(cases[i])}`);
  }
  console.log(`Published Lua, frozen Lua, native import and read-only migration agree for ${cases.length} inputs (recorded changes applied)`);
} finally { fs.rmSync(folder,{recursive:true}); }
