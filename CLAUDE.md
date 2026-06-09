# CLAUDE.md

このファイルは、Claude Code（claude.ai/code）がこのリポジトリで作業する際の指針です。

## プロジェクト概要

**GoblinColony** はゴブリン・コロニーのターン/リアルタイム混在シミュレーションゲーム。
現在は**第一期 = 描画なしの「検証済みシミュレーションコア」**に絞っている。

設計思想は **力学先行・描画後回し**。GDD §12 と `known_issues` の机上検証で固めた力学を
TypeScript に正確に移植し、その一致を機械的に保証することがスコープ。確定済みの安定帯
（辛勝レンジ）とズレた実装を後から発見すると手戻りが大きいため、先に「力学が正しく乗っているか」
を保証してから可視化を被せる。Unity/Godot 等のゲームエンジンには依存しない純 TypeScript 実装。

## ディレクトリ構成（重要）

README が記す `src/sim/` `parity/` `viz/` の階層へ整理済み。各 import パスはこの階層を前提に
書かれている（コア同士は `./xxx.ts`、テストは `../src/sim/xxx.ts`、browser_entry は `./sim/xxx.ts`）。

```
src/
  browser_entry.ts          可視化用の薄い再エクスポート。
  sim/                      コア（純粋シミュレーション層。互いに ./xxx.ts で import）
    rng.ts params.ts cycle.ts goblin.ts state_machine.ts tick_driver.ts
    world_state.ts world_params.ts world.ts
parity/                     テスト + Python 照合基準（../src/sim/... を import）
  cycle.py snapshot_test.ts state_machine_test.ts tick_driver_test.ts world_test.ts
viz/                        可視化アセット
  dashboard_template.html goblin_colony_dashboard.html
build_dashboard.mjs         ビルドスクリプト（リポジトリ直下から実行。src/ と viz/ を参照）
```

| パス | 役割 |
|------|------|
| `src/sim/rng.ts` | 決定的 xorshift128 PRNG。状態を完全に保存・復元できる（KI-09）。`Math.random` は使わない。 |
| `src/sim/params.ts` | マクロ集計サイクルの定数型 + 既定値（v5 の base）。**力学定数の単一の真実源**。 |
| `src/sim/cycle.ts` | マクロ層。単一 state を純粋 step で 1 日進める。Python (`cycle.py`) と照合する基準。 |
| `src/sim/world_state.ts` | World 層の状態スキーマ（個体ゴブリン配列 + レイド等）。 |
| `src/sim/world_params.ts` | 日次サイクルのパラメータを tick ベースへ変換する。レートを再定義しない。 |
| `src/sim/world.ts` | World 層。全個体を 1 tick 進め、戦闘解決・出生・事故死などを処理する。 |
| `src/sim/goblin.ts` | 個体ゴブリンの型（§5 ステート / 性格 / 役職 / 進行中フラグ）。 |
| `src/sim/state_machine.ts` | §5 個体ステートマシン。個体 1 体・1 tick の純粋遷移（副作用なし）。 |
| `src/sim/tick_driver.ts` | 実時間→tick 変換層。**実時間に触れるのはここだけ**（KI-09）。速度倍率・端数持ち越し。 |
| `src/browser_entry.ts` | ブラウザ可視化用の薄い再エクスポート（コアを `globalThis.GoblinSim` に載せる）。 |
| `parity/cycle.py` | TS 版の照合基準（Python 移植）。共有 Rng でビット単位一致を狙う。※下記「落とし穴」参照。 |
| `parity/snapshot_test.ts` | KI-09 スナップショット往復テスト（セーブ/ロードがバイト一致するか）。 |
| `parity/state_machine_test.ts` | §5/§8 ステートマシンの確定仕様検証。 |
| `parity/tick_driver_test.ts` | 速度倍率・端数持ち越し・暴走防止・実時間非依存。 |
| `parity/world_test.ts` | World 層の統合テスト。 |
| `build_dashboard.mjs` | esbuild でコアを IIFE バンドルし HTML テンプレートへ注入、自己完結 HTML を出力。 |
| `viz/dashboard_template.html` | `<!--CORE_BUNDLE-->` プレースホルダを持つダッシュボードのテンプレート。 |

## アーキテクチャ（層構造）

各層は純粋関数 `step(state, params) → { state, log }` で、入力を破壊せず新しい state を返す。

```
マクロ層     cycle.ts        日単位。集計モデル。Python と照合済み（確定）。
   ↓
World 層     world.ts        tick 単位。個体集合 + 一括戦闘解決（§8 簡易ランチェスター）
   ↓                          + 事故死の離散イベント。マクロ層と個体層の橋渡し。
個体層       state_machine.ts 1 体・1 tick。欲求しきい値を評価し優先度順に遷移を出す。
   ↓
実時間層     tick_driver.ts  frame 単位。経過実時間を tick 数へ変換（速度 0/1x/3x）。
```

## 守るべき不変条件 / コーディング規約

- **決定的 Rng に統一**。`Math.random` 禁止。RNG 状態は `SimState.rng`（xorshift128 の 4-tuple）に
  保存する。RNG の**消費順序を変えない**こと（Python とのビット一致が崩れる）。
- **全状態を tick の関数として閉じる（KI-09）**。セーブ/ロード往復はバイト一致が必須。
  セーブ状態に実時間を含めない（保持するのは `tick` / `day` のみ）。
- **力学定数は `params.ts` の base が単一の真実源（KI-01）**。World 層は日次レートを tick レートへ
  *変換*するのみで、レートをその場で再定義しない。
- **純粋関数 + 不変オブジェクト**。step は入力 state を破壊せず新しいオブジェクトを返す。
- 比率は小数で表現する（0.15 = 15%）。`tick` と `day` のスケールを混同しない（KI-02）。
- **裏で難度を動かすフックは作らない**（KI-10: DDA 不採用。固定のレイドスケジュール）。
- 既存ファイルのコメント密度・JSDoc スタイル・命名（`cap`=容量, `cum`=累積, `pop`=人口 等）に合わせる。
- ステートは優先度順の数値 enum（値が小さいほど高優先）。コア層では文字列ステート名を使わない。

## ビルド / テストコマンド

`package.json` は未整備のため、現状は Node ネイティブの型ストリップで直接実行する。
コアが `enum`（`GoblinState` 等）を使うため **`--experimental-transform-types` が必須**
（素の `--experimental-strip-types` だと enum で失敗する）。リポジトリ直下から:

```
node --experimental-transform-types parity/snapshot_test.ts       # SNAPSHOT_ROUNDTRIP_OK
node --experimental-transform-types parity/state_machine_test.ts  # STATEMACHINE_OK
node --experimental-transform-types parity/tick_driver_test.ts    # TICKDRIVER_OK
node --experimental-transform-types parity/world_test.ts          # World 層統合テスト（現状一部 FAIL）
```

ビルド: `node build_dashboard.mjs viz/goblin_colony_dashboard.html` で自己完結 HTML を生成
（esbuild 利用。esbuild は未インストールのため別途 `npm i -D esbuild` 等が必要）。

### ⚠ 既知の落とし穴（着手前に必読）

ファイル階層は README どおり `src/sim/` `parity/` `viz/` へ整理済みで、import パスの不整合は解消した。
ただし以下はまだ残っている:

- **`package.json` / `tsconfig.json` が無い。** `npm run ...` スクリプトは存在せず、上記のとおり
  `node --experimental-transform-types` で直接実行する。テストランナーを整えるなら Node ネイティブ前提で。
- **Python パリティ照合ハーネスが未実装。** `parity/cycle.py` は `from rng import Rng` を import するが
  `parity/rng.py` が無く、単体では実行できない。照合ハーネス `cycle_ts.ts` / `compare.mjs` も未作成のため
  `parity:check`（Python ↔ TS のビット一致 = ALL_MATCH）は未成立。実装するなら rng.ts を Python へ移植し、
  RNG 消費順序を TS と完全に揃えること。
- **World 層の照合が未着手。** `parity/world_test.ts` は現状一部 FAIL する（`次の一手` 1 を参照）。
  これは World 層ロジックの未検証事項であり、力学の確定前提を崩さないよう安易に塞がないこと。

## 設計資料への入口（最初に読むべき順）

1. `README.md` — 第一期サマリ・設計判断・次の一手。
2. `known_issues.md` — KI-01〜KI-21 の設計教訓（過去の検証で潰したバグと解決策）。
3. `goblin_colony_gdd_v10.md` — GDD 全文（§1〜§15 のメカニクス・バランスループ）。
4. `goblin_world_bible_v2.md` — 世界観 / ロア。
5. `known_issues_world.md` — World 層の設計教訓。

## 次の一手（未着手 / README より）

1. **World 層の照合** — 個体 tick + 一括戦闘の集計統計が `cycle.ts` のマクロ安定帯に収まるか検証。
2. **World のスナップショット往復** — 個体配列・進行中フラグが増えた状態で再度 KI-09 往復を通す。
3. **描画層（Canvas 2D）** — state を描くだけの状態を持たない Renderer。重くなれば PixiJS へ。
4. **簡易自動プレイヤー（§12 夜間バッチ）** で多数プレイを回し実数調整（§15）。
