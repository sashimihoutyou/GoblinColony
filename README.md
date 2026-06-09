# goblin-sim — 検証済みコア (第一期)

ゴブリン・コロニーシムの TypeScript 実装。第一期スコープは
**描画なしのシミュレーションコア**で、GDD §12 / known_issues の机上検証で
固めた力学を TS に正確に移植し、その一致を機械的に保証することに絞った。

いきなり画面を作らずコアを先行させたのは、確定済みの安定帯 (辛勝レンジ) と
ズレた実装を後から発見すると手戻りが大きいため。先に「力学が正しく乗っているか」
を保証する。

## 構成

```
src/
  browser_entry.ts  ブラウザ可視化用の薄い再エクスポート (コアを globalThis.GoblinSim に載せる)。
  sim/
    rng.ts            決定的 PRNG (xorshift128)。状態を完全に保存・復元 (KI-09)。
    params.ts         中心サイクルのパラメータ型 + 既定値 (v5 の base)。
    cycle.ts          集計モデル本体。単一 state を純粋 step で 1 日進める。
    tick_driver.ts    実時間→tick 変換層。実時間を触るのはここだけ (KI-09)。
    goblin.ts         個体ゴブリンの型 (§5 ステート/性格/役職/進行中フラグ)。
    state_machine.ts  §5 ステートマシン本体 (個体 1 体・1 tick の純粋遷移)。
    world_state.ts    World 層の状態スキーマ (個体ゴブリン配列 + レイド等)。
    world_params.ts   日次サイクルのパラメータを tick ベースへ変換する。
    world.ts          World 層。全個体を 1 tick 進め、戦闘解決・出生・事故死などを処理する。
parity/
  cycle.py          元 v5 のロジックを共有 Rng に差し替えた照合版。
  snapshot_test.ts       KI-09 スナップショット往復テスト。
  state_machine_test.ts  §5/§8 の確定仕様が出るか検証。
  tick_driver_test.ts    速度倍率・端数持ち越し・暴走防止・実時間非依存。
  world_test.ts          World 層の統合テスト。
viz/
  dashboard_template.html        <!--CORE_BUNDLE--> プレースホルダを持つテンプレート。
  goblin_colony_dashboard.html   build_dashboard.mjs が生成する自己完結 HTML。
build_dashboard.mjs   esbuild でコアをバンドルしテンプレートへ注入 (リポジトリ直下から実行)。
```

> 未実装: README が当初想定した `parity/rng.py` (cycle.py が `from rng import Rng` で要求) と
> 照合ハーネス `parity/cycle_ts.ts` / `parity/compare.mjs` はまだ存在しない。そのため
> `parity:check` (Python ↔ TS のビット一致) は未成立で、cycle.py 単体も現状は実行できない。

## 設計判断

- **集計モデルであって個体エージェント (§5) ではない。** これは机上検証が
  確かめた「マクロな安定帯が存在するか」を移したもの。個体ステートマシン層は
  このマクロ層が一致してから被せる。
- **乱数は決定的 Rng に統一した。** 元の検証は Python 標準 random だが、
  KI-09 がセーブ時の RNG 状態保存を要求するため、本実装も照合用 Python も
  共有 Rng に揃えた。結果として両者はビット単位で一致する。
- **state は単一オブジェクト + 純粋 step。** KI-01「力学を一箇所に」と
  KI-09「全状態を tick の関数として閉じよ」を構造で満たす。
- **難度を裏で動かすフックは作らない** (KI-10: DDA 不採用)。

## 検証コマンド

`package.json` は未整備のため、現状は Node ネイティブの型ストリップで直接実行する
(コアが `enum` を使うため `--experimental-transform-types` が必要)。リポジトリ直下から:

```
node --experimental-transform-types parity/snapshot_test.ts       # セーブ/ロード往復 (KI-09)
node --experimental-transform-types parity/state_machine_test.ts  # §5/§8 ステートマシンの確定仕様
node --experimental-transform-types parity/tick_driver_test.ts    # 速度倍率・実時間非依存 (KI-09)
node --experimental-transform-types parity/world_test.ts          # World 層の統合テスト
```

現状: snapshot / statemachine / tickdriver はグリーン (SNAPSHOT_ROUNDTRIP_OK /
STATEMACHINE_OK / TICKDRIVER_OK)。world_test は World 層の照合が未着手のため一部 FAIL する
(`次の一手` 1. を参照)。Python ↔ TS の `parity:check` (ALL_MATCH) は照合ハーネス未実装のため未成立。

## 次の一手 (未着手)

1. **World 層**: 個体集合 + 一括戦闘解決 (§8 簡易ランチェスター) + 事故死の
   離散イベント (§2.5) を tick で回し、その集計統計が cycle.ts の
   マクロ安定帯 (辛勝レンジ) に収まるか照合する。個体層とマクロ層の橋渡し。
2. **World のスナップショット往復**: 個体配列・進行中フラグが増えた状態で
   再度 KI-09 の往復テストを通す (フラグが増えるたびに足すだけ、の運用)。
3. **描画層 (Canvas 2D)**: state を描くだけの状態を持たない Renderer。
   個体数が増えて重くなったら PixiJS へ。frontend-design スキルを参照。
4. 簡易自動プレイヤー (§12 夜間バッチ) で多数プレイを回し実数調整 (§15)。
