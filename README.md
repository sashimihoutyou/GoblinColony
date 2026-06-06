# goblin-sim — 検証済みコア (第一期)

ゴブリン・コロニーシムの TypeScript 実装。第一期スコープは
**描画なしのシミュレーションコア**で、GDD §12 / known_issues の机上検証で
固めた力学を TS に正確に移植し、その一致を機械的に保証することに絞った。

いきなり画面を作らずコアを先行させたのは、確定済みの安定帯 (辛勝レンジ) と
ズレた実装を後から発見すると手戻りが大きいため。先に「力学が正しく乗っているか」
を保証する。

## 構成

```
src/sim/
  rng.ts            決定的 PRNG (xorshift128)。状態を完全に保存・復元 (KI-09)。
  params.ts         中心サイクルのパラメータ型 + 既定値 (v5 の base)。
  cycle.ts          集計モデル本体。単一 state を純粋 step で 1 日進める。
  tick_driver.ts    実時間→tick 変換層。実時間を触るのはここだけ (KI-09)。
  goblin.ts         個体ゴブリンの型 (§5 ステート/性格/役職/進行中フラグ)。
  state_machine.ts  §5 ステートマシン本体 (個体 1 体・1 tick の純粋遷移)。
parity/
  rng.py            rng.ts と同一アルゴリズムの Python 移植 (照合基準)。
  cycle.py          元 v5 のロジックを共有 Rng に差し替えた照合版。
  cycle_ts.ts       TS 版を同一シナリオで走らせる照合ハーネス。
  compare.mjs       両出力を比較 (CI 用、差分で exit 1)。
  snapshot_test.ts       KI-09 スナップショット往復テスト。
  state_machine_test.ts  §5/§8 の確定仕様が出るか検証。
  tick_driver_test.ts    速度倍率・端数持ち越し・暴走防止・実時間非依存。
```

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

```
npm run test:all          # 下記すべてを順に実行
npm run parity:check      # Python版とTS版の中心サイクル一致 (ALL_MATCH)
npm run test:snapshot     # セーブ/ロード往復が通しと一致 (KI-09)
npm run test:statemachine # §5/§8 ステートマシンの確定仕様
npm run test:tickdriver   # 速度倍率・実時間非依存 (KI-09)
```

現状: 全項目グリーン (ALL_MATCH / SNAPSHOT_ROUNDTRIP_OK /
STATEMACHINE_OK / TICKDRIVER_OK)。

## 次の一手 (未着手)

1. **World 層**: 個体集合 + 一括戦闘解決 (§8 簡易ランチェスター) + 事故死の
   離散イベント (§2.5) を tick で回し、その集計統計が cycle.ts の
   マクロ安定帯 (辛勝レンジ) に収まるか照合する。個体層とマクロ層の橋渡し。
2. **World のスナップショット往復**: 個体配列・進行中フラグが増えた状態で
   再度 KI-09 の往復テストを通す (フラグが増えるたびに足すだけ、の運用)。
3. **描画層 (Canvas 2D)**: state を描くだけの状態を持たない Renderer。
   個体数が増えて重くなったら PixiJS へ。frontend-design スキルを参照。
4. 簡易自動プレイヤー (§12 夜間バッチ) で多数プレイを回し実数調整 (§15)。
