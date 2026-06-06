// ダッシュボードのビルド: 検証済みコアを esbuild でバンドルし、
// HTML テンプレートの <!--CORE_BUNDLE--> に注入して 1 ファイルの
// 自己完結 HTML を出力する。力学はコアのみが持ち、可視化は再実装しない (KI-01)。
import { build } from "esbuild";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const OUT_HTML = process.argv[2] || "viz/goblin_colony_dashboard.html";

// 1. コアを IIFE バンドル (globalThis.GoblinSim に載る browser_entry)。
const result = await build({
  entryPoints: ["src/browser_entry.ts"],
  bundle: true,
  format: "iife",
  target: "es2020",
  write: false,
  minify: false,
});
const bundleJs = result.outputFiles[0].text;

// 2. テンプレートへ注入。
const tpl = readFileSync("viz/dashboard_template.html", "utf8");
const html = tpl.replace("<!--CORE_BUNDLE-->", "<script>\n" + bundleJs + "\n</script>");

// 3. 出力。
mkdirSync(OUT_HTML.replace(/\/[^/]+$/, ""), { recursive: true });
writeFileSync(OUT_HTML, html, "utf8");
console.log(`built: ${OUT_HTML} (${html.length} bytes, bundle ${bundleJs.length} bytes)`);
