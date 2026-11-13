// Validate a GLB with the Khronos glTF validator.
// Usage: node render/validate.mjs MODEL.glb   -> prints a JSON summary, exit 1 on errors
import fs from 'node:fs';
import validator from 'gltf-validator';

const file = process.argv[2];
const data = new Uint8Array(fs.readFileSync(file));
const report = await validator.validateBytes(data, { maxIssues: 50 });
const i = report.issues;
const n = report.info || {};
console.log(JSON.stringify({
  validatorVersion: report.validatorVersion,
  errors: i.numErrors, warnings: i.numWarnings, infos: i.numInfos, hints: i.numHints,
  messages: i.messages.slice(0, 20).map((m) => ({
    severity: ['error', 'warning', 'info', 'hint'][m.severity], code: m.code, pointer: m.pointer, message: m.message })),
  drawCalls: n.drawCallCount, triangles: n.totalTriangleCount, vertices: n.totalVertexCount,
  materials: n.materialCount,
}, null, 1));
process.exit(i.numErrors ? 1 : 0);
