extends RefCounted
class_name FieldResource
## 巣外の出現物 (§11.5 昼の外征)。
##
## 日中に巣外 (EXTERIOR) へランダムに湧き、プレイヤーが派遣したゴブリンが往復して
## リターンを集積所へ持ち帰る (種別ごとにリターンが固定 / §11.5)。夜は暗くて外に
## 出られない (§11.5) ため、日没で未回収ぶんは消える。動かない・攻撃しないので
## 座標と残量・種別・距離だけを持つ。スナップショット保存対象 (KI-09)。

## 出現物の種別 (§11.5 表)。FORAGE が既存 (採取系)。値は固定し増減時も既存値を
## 変えない (snapshot に int で残るため)。
enum Kind {
	FORAGE = 0,    # 有用な植物 (採取・既存) → 食料
	ANIMAL = 1,    # 動物 (狩猟) → 食料(多め) + 低確率で捕虜(ゴブリン)
	TRAVELER = 2,  # 旅人 (交易) → 少量 gems/herb。B5 までの最小実装
	WANDERER = 3,  # ゴブリン放浪者 → 帰還で加入 (部族差)
	CAMP = 4,      # 敵性キャンプ (戦闘系) → gems+equipment+捕虜 or 負傷
	RUINS = 5,     # 廃墟 → 建材 mud + 低確率で gems
	MAIDEN = 6,    # 行き倒れの少女 (稀) → 人間雌捕虜 (アミナの種)
}

var id: int = 0
var x: int = 0
var y: int = 0
var amount: int = 0   # 残り作業量 (1 運搬/1 作業ぶん。採取・狩猟・廃墟系で消費)
var kind: int = Kind.FORAGE
var distance: int = 0  # 0=近い/1=遠い (§11.5: 遠いほどリターン良いが往復に時間がかかる)
# WANDERER 限定: 放浪者の出身部族 ("bunta"/"kugyo"/"" 他)。加入確率の部族差 (§11.5) に
# 使う。spawn 時に決定し、以降は読み取りのみ (RNG 消費はスポーン時の 1 回に固定)。
var tribe: String = ""

func pos() -> Vector2i:
	return Vector2i(x, y)

func snapshot() -> Dictionary:
	return {"id": id, "x": x, "y": y, "amount": amount, "kind": kind, "distance": distance, "tribe": tribe}

static func from_snapshot(d: Dictionary) -> FieldResource:
	var f := FieldResource.new()
	for k in d.keys():
		f.set(k, d[k])
	f.kind = int(f.kind)
	f.distance = int(f.distance)
	f.tribe = String(f.tribe)
	return f
