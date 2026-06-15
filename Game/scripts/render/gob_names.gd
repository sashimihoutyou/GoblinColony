extends RefCounted
class_name GobNames
## 個体名の決定的生成 (演出層)。id から同じ名前が常に出るため保存不要。
## 音節表は res://data/dialogue.json の "names" (TextDB) から読む。データが無い/壊れて
## いる場合は下のフォールバック表を使う (名前は必ず出る)。TextDB はセッション中キャッシュ
## 固定なので、同じ id は同じ名前を返す。
## Web 版ダッシュボード (viz/dashboard_template.html) は独自の音節表を持つ (同期は任意)。

const M1_FALLBACK := ["ガ", "グ", "ゴ", "ザ", "ズ", "ド", "ブ", "ギ", "バ", "ゲ"]
const M2_FALLBACK := ["ルク", "ザク", "ナグ", "グル", "ボグ", "ラグ", "ジク", "ドズ", "ブズ", "ガク"]
const F1_FALLBACK := ["ニャ", "ミ", "リ", "シャ", "メ", "ヤ", "ル", "ピ"]
const F2_FALLBACK := ["ッカ", "ーラ", "ズミ", "ニェ", "ッタ", "ーシャ", "リン", "ュム"]

## 音節プール (JSON 優先・空ならフォールバック)。
static func _pool(key: String, fallback: Array) -> Array:
	var p := TextDB.names(key)
	return p if not p.is_empty() else fallback

static func hash_id(id: int) -> int:
	var s: int = (id * 2654435761) & 0xFFFFFFFF
	s = s ^ (s >> 13)
	s = (s * 1274126177) & 0xFFFFFFFF
	return s

static func name_of(id: int, sex: int, is_chief: bool = false) -> String:
	var h := hash_id(id)
	var n: String
	if sex == Goblin.Sex.FEMALE:
		var f1 := _pool("F1", F1_FALLBACK)
		var f2 := _pool("F2", F2_FALLBACK)
		n = String(f1[h % f1.size()]) + String(f2[(h >> 4) % f2.size()])
	else:
		var m1 := _pool("M1", M1_FALLBACK)
		var m2 := _pool("M2", M2_FALLBACK)
		n = String(m1[h % m1.size()]) + String(m2[(h >> 4) % m2.size()])
	return ("族長" + n) if is_chief else n

static func of(g: Goblin) -> String:
	return name_of(g.id, g.sex, g.role == Goblin.Role.CHIEF)
