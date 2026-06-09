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

現状: 4 スイートとも グリーン (SNAPSHOT_ROUNDTRIP_OK / STATEMACHINE_OK /
TICKDRIVER_OK / WORLD_OK)。world_test の旧 FAIL (reproduction 未稼働) は KI-22 で解消。
Python ↔ TS の `parity:check` (ALL_MATCH) は照合ハーネス未実装のため未成立 (cycle 層)。

## 達成済み (World 層・KI-12〜25)

- 個体ステートマシンの群れ tick 駆動・平時安定帯・巣立ち安全弁・戦闘 (族長盾/surge)。
- 捕虜システム (苗床 / 生贄+召喚) と襲撃込み通し 30 日の安定帯 (KI-13/15)。
- 求愛→つがい→出産の reproduction 稼働 (KI-22)。初期 7:3・妊娠/成熟 1 日・一腹 1〜6。
- 人間母体の苗床 (多産・中立ルート封鎖 / KI-23)。
- 敵対度メーター + 自動襲撃スケジューラ (残虐→憎悪→報復の自走 / KI-24)。
- 二層襲撃の小規模 (恵み) 側 (§11/KI-05 / KI-25)。

## 次の一手 (未着手)

1. **§13 外交の双方向化**: 朝貢での敵対度低下・3 勢力分の敵対度メーター分離 (KI-24 残り)。
2. **§15 実数調整**: 簡易自動プレイヤー (§12 夜間バッチ) で多シードを回し、一腹分布 /
   人間母体倍率 / 敵対度係数 / 小規模報酬 をまとめてチューニング (KI-22/25 の相互作用が論点)。
3. **描画層 (Canvas 2D)**: state を描くだけの状態を持たない Renderer。
   個体数が増えて重くなったら PixiJS へ。frontend-design スキルを参照。
4. **食料生産**: 増殖の食料従属 (§2.5)・信仰のトーテムランク連動 (§3)。
