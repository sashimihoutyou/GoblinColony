extends RefCounted
class_name FieldResource
## 巣外の出現物 (§11.5 昼の外征の縮小版: 採取系のみ)。
##
## 日中に巣外 (EXTERIOR) へランダムに湧き、プレイヤーが派遣したゴブリンが
## 往復して一食ずつ集積所へ持ち帰る。夜は暗くて外に出られない (§11.5) ため、
## 日没で未回収ぶんは消える。動かない・攻撃しないので座標と残量だけを持つ。
## スナップショット保存対象 (KI-09)。

var id: int = 0
var x: int = 0
var y: int = 0
var amount: int = 0   # 残り運搬回数 (1 運搬 = 一食分 = field_carry_value)

func pos() -> Vector2i:
	return Vector2i(x, y)

func snapshot() -> Dictionary:
	return {"id": id, "x": x, "y": y, "amount": amount}

static func from_snapshot(d: Dictionary) -> FieldResource:
	var f := FieldResource.new()
	for k in d.keys():
		f.set(k, d[k])
	return f
