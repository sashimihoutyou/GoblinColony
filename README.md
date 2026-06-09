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
  timescale_test.ts      tick 解像度変換の不変性 (日次レート/所要日数 / KI-02)。
  world_test.ts          World 層の統合テスト。
viz/
  dashboard_template.html        <!--CORE_BUNDLE--> プレースホルダを持つテンプレート (編集はこちら)。
  goblin_colony_dashboard.html   build_dashboard.mjs が生成する自己完結 HTML (生成物)。
  dashboard_smoke.mjs            ダッシュボードの DOM スタブ実行スモーク。
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

## 検証 / ビルドコマンド

初回は `npm install` (esbuild のみ)。リポジトリ直下から:

```
npm test                       # 5 スイート (個別は npm run test:world など)
npm run build                  # 自己完結 HTML → viz/goblin_colony_dashboard.html
node viz/dashboard_smoke.mjs   # ビルド後、可視化ロジックのスモーク
```

テストは Node ネイティブの型ストリップで直接実行する (コアが `enum` を使うため
`--experimental-transform-types` が必要)。

現状: 5 スイートとも グリーン (SNAPSHOT_ROUNDTRIP_OK / STATEMACHINE_OK /
TICKDRIVER_OK / TIMESCALE_OK / WORLD_OK)。world_test の旧 FAIL (reproduction 未稼働) は
KI-22 で解消。Python ↔ TS の `parity:check` (ALL_MATCH) は照合ハーネス未実装のため未成立 (cycle 層)。

## 観測ダッシュボード (viz)

`npm run build` で生成される `viz/goblin_colony_dashboard.html` をブラウザで開くだけで動く。

- **タイムスケール: 1 日 = 実時間約 60 秒** (`ticksPerDay=120` × 2 tick/秒。3x で 20 秒)。
  per-tick 力学定数は基準解像度 10 tick/日 で校正し、`makeWorldParams` が日次レート不変のまま
  変換する (timescale_test が保証 / KI-02)。
- **演出層の移動**: 個体はステートを行き先 (寝床/食料庫/採掘場/巣口/奥) に翻訳して
  毎フレーム補間で動く。位置はすべて可視化ローカルで、シム状態・RNG・スナップショットに
  一切触れない (KI-09 セーフ)。
- **個体インスペクタ**: 俯瞰図のゴブリンをタップで名前 (id から決定的に生成)・HP・欲求・
  つがい・出自を観察。
- **イベントフィード**: stepWorld 前後の差分 + deathLog (KI-20) から出生・死亡・つがい成立・
  妊娠・襲撃・小競り合いの恵みを物語として流す。
- **自動襲撃オン**: 敵対度連動の大規模襲撃 + 小規模の恵み (§11/§13) が自走する。
  捕虜の自然つがい化 (KI-21) は承認/引き離しバナーで可否を判断できる。

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
3. **描画層 (Canvas 2D)**: ダッシュボードに演出層 (ゾーン + 補間移動・インスペクタ・
   イベントフィード) を実装済み。本物の位置 (GDD §12 タイルマップ + パスファインディング) は
   第二期。個体数が増えて重くなったら PixiJS へ。
4. **食料生産**: 増殖の食料従属 (§2.5)・信仰のトーテムランク連動 (§3)。
