extends RefCounted
class_name GobNames
## 個体名の決定的生成 (演出層)。id から同じ名前が常に出るため保存不要。
## Web 版ダッシュボード (viz/dashboard_template.html) と同じ音節テーブル。

const M1 := ["ガ", "グ", "ゴ", "ザ", "ズ", "ド", "ブ", "ギ", "バ", "ゲ"]
const M2 := ["ルク", "ザク", "ナグ", "グル", "ボグ", "ラグ", "ジク", "ドズ", "ブズ", "ガク"]
const F1 := ["ニャ", "ミ", "リ", "シャ", "メ", "ヤ", "ル", "ピ"]
const F2 := ["ッカ", "ーラ", "ズミ", "ニェ", "ッタ", "ーシャ", "リン", "ュム"]

static func hash_id(id: int) -> int:
	var s: int = (id * 2654435761) & 0xFFFFFFFF
	s = s ^ (s >> 13)
	s = (s * 1274126177) & 0xFFFFFFFF
	return s

static func name_of(id: int, sex: int, is_chief: bool = false) -> String:
	var h := hash_id(id)
	var n: String
	if sex == Goblin.Sex.FEMALE:
		n = F1[h % F1.size()] + F2[(h >> 4) % F2.size()]
	else:
		n = M1[h % M1.size()] + M2[(h >> 4) % M2.size()]
	return ("族長" + n) if is_chief else n

static func of(g: Goblin) -> String:
	return name_of(g.id, g.sex, g.role == Goblin.Role.CHIEF)
