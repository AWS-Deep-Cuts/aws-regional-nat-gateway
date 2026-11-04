// AWS の公式アイコン（npm パッケージ aws-icons の SVG）を img/icons/ にコピーする
// 元は Kenta-Matsuda/slide-template の tools/icons.cjs
//   node icons.cjs AWSLambda AWSCloudShell   … 名前を指定してコピー
//   node icons.cjs --find lambda             … 名前を探す
const fs = require('fs');
const path = require('path');
const root = path.dirname(require.resolve('aws-icons/package.json'));
const dirs = ['architecture-service', 'resource', 'architecture-group', 'category'].map((d) => path.join(root, 'icons', d));
const out = path.resolve(__dirname, '..', 'icons');
const args = process.argv.slice(2);
if (args[0] === '--find') {
  const q = (args[1] || '').toLowerCase();
  for (const d of dirs) for (const f of fs.readdirSync(d)) if (f.toLowerCase().includes(q)) console.log(path.basename(d) + '/' + f.replace(/\.svg$/, ''));
  process.exit(0);
}
fs.mkdirSync(out, { recursive: true });
for (const name of args) {
  const src = dirs.map((d) => path.join(d, name + '.svg')).find((p) => fs.existsSync(p));
  if (!src) { console.error('見つからない:', name, '（--find で探せる）'); process.exitCode = 1; continue; }
  fs.copyFileSync(src, path.join(out, name + '.svg'));
  console.log('copied', name + '.svg');
}
