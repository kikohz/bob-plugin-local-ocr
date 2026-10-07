// 打包 Bob 插件并更新 appcast.json。
// 用法: node scripts/release.mjs "本次更新说明"
// 版本号取自 plugin/info.json；打包结果在 dist/ 下，随后用 gh release create 上传。

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = 'kikohz/bob-plugin-local-ocr';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const desc = process.argv[2];
if (!desc) {
  console.error('用法: node scripts/release.mjs "本次更新说明"');
  process.exit(1);
}

const info = JSON.parse(readFileSync(join(root, 'plugin/info.json'), 'utf8'));
const tag = `v${info.version}`;
const fileName = `bob-plugin-local-ocr-${tag}.bobplugin`;
const pkgPath = join(root, 'dist', fileName);

mkdirSync(join(root, 'dist'), { recursive: true });
rmSync(pkgPath, { force: true });
// .bobplugin 是一个 zip，info.json 和 main.js 必须位于压缩包根目录
execFileSync('zip', ['-q', '-X', pkgPath, 'info.json', 'main.js'], { cwd: join(root, 'plugin') });
const sha256 = createHash('sha256').update(readFileSync(pkgPath)).digest('hex');

const appcastPath = join(root, 'appcast.json');
let appcast;
try {
  appcast = JSON.parse(readFileSync(appcastPath, 'utf8'));
} catch {
  appcast = { identifier: info.identifier, versions: [] };
}
appcast.identifier = info.identifier;
// 新版本放在最前面；重复发布同一版本时覆盖旧记录
appcast.versions = [
  {
    version: info.version,
    desc,
    sha256,
    url: `https://github.com/${REPO}/releases/download/${tag}/${fileName}`,
    minBobVersion: info.minBobVersion,
    timestamp: Date.now(),
  },
  ...appcast.versions.filter((v) => v.version !== info.version),
];
writeFileSync(appcastPath, `${JSON.stringify(appcast, null, 2)}\n`);

console.log(`已打包: dist/${fileName}`);
console.log(`sha256: ${sha256}`);
console.log('appcast.json 已更新。提交并推送后执行:');
console.log(`  gh release create ${tag} "dist/${fileName}" --title "${tag}" --notes "${desc}"`);
