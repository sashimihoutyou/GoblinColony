# GoblinColony — Godot α版 (P1: プロトタイプ)

`game_spec_v1.md` のフェーズ 1（プロトタイプ）を Godot 4.6 / GDScript で実装したもの。
TypeScript コア (`../src/sim/`) のロジックを GDScript へ書き直した版で、Godot からは
TypeScript には依存しない（コアは設計の参照資料として使用）。

## α版のスコープ（P1）

- グリッドマップ上でゴブリンが A* で移動・戦闘・増殖する画面を見る
- **プレイヤー操作なし・オートプレイで 30 日完走**（ラストバトル含む）
- 速度コントロール（停止 / 1x / 3x）
- 勝敗判定（全滅・トーテム破壊で敗北 / ラストバトル撃退で勝利）

> 次の実装（P2）でプレイヤー操作を入れられるよう、全ての干渉は
> `scripts/play/controller.gd` の Command キュー経由に統一済み。
> `AutoController` を `PlayerController` に差し替えるだけで操作版になる。

## ディレクトリ構成

```
scripts/
  sim/                  コア（純ロジック・ノード非依存の RefCounted）
    rng.gd                決定的 xorshift128 PRNG（KI-09。組み込み乱数は使わない）
    params.gd             力学定数の単一の真実源（KI-01）
    tile_map.gd           グリッドマップ（§3-0）
    map_template.gd       固定テンプレートの初期マップ生成（§3-0）
    goblin.gd             個体ゴブリン型 + 座標（§5 / §3-0）
    enemy.gd              敵ユニット（§3-14）
    state_machine.gd      §5 個体ステートマシン（1 体・1 tick）
    pathfinding.gd        A* 経路探索（§3-0）
    world.gd              World 層（全個体 1 tick・戦闘・増殖・襲撃・昼夜）
  play/
    controller.gd         プレイヤー/AI 干渉の抽象層（Command キュー）
    auto_controller.gd    α版オートプレイヤー
  render/
    renderer.gd           状態を持たない描画層（単色 + ラベル / 画像優先）
  main.gd                 実時間→tick→render のメインループ
  test_smoke.gd           ヘッドレス通しプレイ検証
scenes/
  Main.tscn               メインシーン
```

## 実行

Godot 4.6 で `Game/` を開き、メインシーン `scenes/Main.tscn` を実行。

ヘッドレス通しプレイ検証（描画なしで 30 日完走 + スナップショット往復）:

```
godot --headless --path Game --script res://scripts/test_smoke.gd
# 期待出力: SMOKE_OK
```

## ビジュアル

既定はエンジニアアート（単色タイル + 文字ラベル）。画像を使う場合は
`main.gd` の `_ready()` でパスを指定する（無ければ自動で単色フォールバック）:

```gdscript
renderer.tile_textures[TileMapData.TileType.FLOOR] = "res://art/floor.png"
renderer.goblin_texture_path = "res://art/goblin.png"
renderer.enemy_texture_path = "res://art/enemy.png"
```

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
