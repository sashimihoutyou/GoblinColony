# GoblinColony — Godot α版 (P1: プロトタイプ)

`game_spec_v1.md` のフェーズ 1（プロトタイプ）を Godot 4.6 / GDScript で実装したもの。
TypeScript コア (`../src/sim/`) のロジックを GDScript へ書き直した版で、Godot からは
TypeScript には依存しない（コアは設計の参照資料として使用）。

## α版のスコープ（P1 + 観賞強化）

- グリッドマップ上でゴブリンが A* で移動・戦闘・増殖する画面を見る
- **プレイヤー操作なし・オートプレイで 30 日完走**（ラストバトル含む）
- 速度コントロール（停止 / 1x / 3x）
- 勝敗判定（全滅・トーテム破壊で敗北 / ラストバトル撃退で勝利）
- **タイムスケール: 1 日 = 実 60 秒**（1 tick = 1 秒 × 60 tick/日。3x で 20 秒）
- **観賞 UI**（Web 版ダッシュボードの移植）: 個体タップで名前・HP・欲求・妊娠などの
  インスペクタ、出生・死亡・襲撃・巣立ちが物語として流れる「巣の記録」フィード、
  次の大襲撃 ETA
- **ビジュアル**: 手続き描画の洞窟（岩肌・寝床のわら・キノコと骨の食料庫・金鉱脈・
  トーテムの炎）、耳と目を持つゴブリンスプライト（タイル間は補間で滑らかに移動）、
  パーティクル（睡眠の Z・恐怖の汗・採掘の破片・死亡の骨・火の粉）、昼夜の明暗トーン

> 次の実装（P2）でプレイヤー操作を入れられるよう、全ての干渉は
> `scripts/play/controller.gd` の Command キュー経由に統一済み。
> `AutoController` を `PlayerController` に差し替えるだけで操作版になる。

## ディレクトリ構成

```
scripts/
  sim/                  コア（純ロジック・ノード非依存の RefCounted）
    rng.gd                決定的 xorshift128 PRNG（KI-09。組み込み乱数は使わない）
    params.gd             力学定数の単一の真実源（KI-01）。日次レートを ticks_per_day で
                          per-tick へ変換する（KI-02。per-tick 定数を素で書かない）
    tile_map.gd           グリッドマップ（§3-0）
    map_template.gd       固定テンプレートの初期マップ生成（§3-0）
    goblin.gd             個体ゴブリン型 + 座標（§5 / §3-0）
    enemy.gd              敵ユニット（§3-14）
    state_machine.gd      §5 個体ステートマシン（1 体・1 tick）
    pathfinding.gd        A* 経路探索（§3-0）
    world.gd              World 層（全個体 1 tick・戦闘・増殖・襲撃・昼夜）。
                          UI 向けに構造化イベント（last_events: Dictionary 配列）を発行
  play/
    controller.gd         プレイヤー/AI 干渉の抽象層（Command キュー）
    auto_controller.gd    α版オートプレイヤー
  render/
    renderer.gd           描画層。タイル間の補間移動・パーティクル・昼夜トーンは
                          すべてこの層のローカル状態（シム状態に書き込まない / KI-09）
    gob_names.gd          個体名の決定的生成（id → 名前。Web 版と同じ音節）
  main.gd                 実時間→tick→render のメインループ + コード構築の UI
  test_smoke.gd           ヘッドレス通しプレイ検証（30 日完走 + スナップショット往復）
  test_scene_smoke.gd     メインシーンの起動スモーク（UI/描画層のエラー検出）
scenes/
  Main.tscn               メインシーン（骨組みのみ。UI は main.gd が構築）
```

## 実行

Godot 4.6 で `Game/` を開き、メインシーン `scenes/Main.tscn` を実行。
マップ上のゴブリンを左クリックすると右パネルにその個体の暮らしぶりが出る。

ヘッドレス検証（CI 相当。初回はキャッシュ生成のため `--import` を先に実行）:

```
godot --headless --path Game --import
godot --headless --path Game --script res://scripts/test_smoke.gd        # 期待: SMOKE_OK
godot --headless --path Game --script res://scripts/test_scene_smoke.gd  # 期待: SCENE_SMOKE_OK
```

## ビジュアル

手続き描画（画像アセット不要）。Web 版ダッシュボード `viz/dashboard_template.html` と
同じ配色言語（闇の岩 #1d150c・琥珀 #e8943a・ステート色 = 分布の色）。
個体スプライト・装飾・パーティクルはすべて `renderer.gd` の `_draw` で描いており、
ドット絵アセットへ差し替える場合もこのファイルだけが対象になる。

## 守っている不変条件（コアと共通）

- 組み込み乱数は使わず `Rng`（xorshift128）のみ。RNG 消費順序で決定性を担保（KI-09）
- 全状態を tick の関数として閉じる。`snapshot()`/`restore()` で往復（KI-09）
- 力学定数は `params.gd` が単一の真実源（KI-01）
- 難度を裏で動かすフックは作らない（KI-10）

## 既知の簡略化（P1 の意図的省略 / 今後）

- プレイヤー操作 UI（ダイヤル・任命・奇跡）は未実装（P2）
- 信仰経済・奇跡・苗床・外征・壁破壊・捕虜は未接続（P2〜P3）
- A* はキャッシュなしの単純実装（最適化は P2 で計測後）
- 敵対度メーターは固定（人間加害の接続は P3）

## 修正履歴（観賞強化時に潰したバグ）

- **敵がマップ範囲外にスポーンして一歩も動けない**: A* が範囲外を歩行不可と
  みなすため、襲撃が永遠に決着せず phase=COMBAT のまま増殖・勝敗も停止していた。
  スポーンをマップ縁（範囲内の外部地面）に修正。
- **最終日以降、日境界ごとにラストバトルが多重スポーン**: `day >= final_day` を
  `day == final_day` に修正（一度だけ）。
