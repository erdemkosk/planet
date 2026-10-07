extends RefCounted
## The character roster (Kahramanlar, scripts/war/heroes/heroes.gd): names, the ultimate and the passive
## of each, its colour and a small vector icon drawn with CanvasItem primitives (no textures), shared by
## the HUD ring (hero_hud.gd), the picker (hero_picker.gd) and the alerts. Static data only.
##   HeroData.IDS                    the roster in picker order
##   HeroData.info(id) -> Dictionary {"name", "ult", "passive", "desc", "col", "aim" (hold E to aim),
##                                    "range" (m, aimed ones), "charge_k" (× HERO_CHARGE_TIME)}
##   HeroData.draw_icon(ci, id, centre, radius, col, w := 2.0)
## Numbers: balance.gd "Heroes / ultimates" (HERO_*).

const Balance := preload("res://scripts/war/balance.gd")

const IDS := ["topcu", "gozcu", "muhafiz", "kazici", "avci", "muhendis"]
const DEFAULT := "topcu"

const DATA := {
	"topcu": {"name": "Topçu", "ult": "Göktaşı Yağmuru", "col": Color(1.0, 0.5, 0.2), "aim": true,
		"desc": "Bir noktayı işaretle: 3 sn sonra 4-6 göktaşı yağar (hasar, krater, göçük).",
		"passive": "Oturduğun top %35 daha hızlı dolar."},
	"gozcu": {"name": "Gözcü", "ult": "Uydu Taraması", "col": Color(0.4, 0.9, 1.0), "aim": false,
		"desc": "7 sn boyunca gezegendeki bütün düşmanlar radarda ve duvar arkasında görünür.",
		"passive": "Tünel tarayıcı (Q) %50 daha hızlı dolar."},
	"muhafiz": {"name": "Muhafız", "ult": "Kalkan Kubbesi", "col": Color(0.55, 0.68, 1.0), "aim": false,
		"desc": "6 m'lik kubbe, 10 sn: dışarıdan gelen mermiyi ve bombayı durdurur, içeriden ateş edilir.",
		"passive": "Hızlı siper iki kat çabuk hazır; yaralıyı daha hızlı kaldırırsın."},
	"kazici": {"name": "Kazıcı", "ult": "Sismik Dalga", "col": Color(0.98, 0.72, 0.3), "aim": false,
		"desc": "Yere vur: 20 m'de düşman tünelleri çöker, düşmanlar sarsılır.",
		"passive": "Matkabın %30 daha hızlı kazar."},
	"avci": {"name": "Avcı", "ult": "Faz Pelerini", "col": Color(0.45, 1.0, 0.72), "aim": false,
		"desc": "7 sn neredeyse görünmez ve daha hızlısın; ateş edince bozulur.",
		"passive": "Botlar atışlarını daha yakından duyar."},
	"muhendis": {"name": "Mühendis", "ult": "Yerçekimi Kuyusu", "col": Color(0.8, 0.5, 1.0), "aim": true,
		"desc": "Bir tekillik fırlat: düşmanları ve enkazı çeker, sonra patlar.",
		"passive": "Her doğuşta bir fazla bomba."},
}


static func has(id: String) -> bool:
	return DATA.has(id)


static func info(id: String) -> Dictionary:
	var d: Dictionary = (DATA.get(id, DATA[DEFAULT]) as Dictionary).duplicate()
	d["id"] = id if DATA.has(id) else DEFAULT
	d["range"] = range_of(id)
	d["charge_k"] = charge_k(id)
	return d


static func hero_name(id: String) -> String:
	return str((DATA.get(id, {}) as Dictionary).get("name", id))


static func ult_name(id: String) -> String:
	return str((DATA.get(id, {}) as Dictionary).get("ult", ""))


static func color(id: String) -> Color:
	return (DATA.get(id, {}) as Dictionary).get("col", Color(1.0, 0.56, 0.2))


static func aims(id: String) -> bool:
	return bool((DATA.get(id, {}) as Dictionary).get("aim", false))


## Aim range (m) of a targeted ultimate (0: not aimed).
static func range_of(id: String) -> float:
	match id:
		"topcu":
			return Balance.HERO_METEOR_RANGE
		"muhendis":
			return Balance.HERO_WELL_RANGE
	return 0.0


## × HERO_CHARGE_TIME for this character's ultimate.
static func charge_k(id: String) -> float:
	match id:
		"topcu":
			return Balance.HERO_METEOR_CHARGE_K
		"gozcu":
			return Balance.HERO_SCAN_CHARGE_K
		"muhafiz":
			return Balance.HERO_DOME_CHARGE_K
		"kazici":
			return Balance.HERO_QUAKE_CHARGE_K
		"avci":
			return Balance.HERO_CLOAK_CHARGE_K
		"muhendis":
			return Balance.HERO_WELL_CHARGE_K
	return 1.0


## The character's icon centred at c, fitting a circle of radius r.
static func draw_icon(ci: CanvasItem, id: String, c: Vector2, r: float, col: Color, w := 2.0) -> void:
	w = maxf(w, 1.0)
	match id:
		"topcu":
			# A meteor: a rock low-left, three streaks trailing up-right.
			var rock := c + Vector2(-0.22, 0.22) * r
			for i in 3:
				var off := Vector2(-0.18 + 0.18 * float(i), 0.18 - 0.18 * float(i)) * r * 0.9
				var a := rock + off + Vector2(0.34, -0.34) * r
				var b := a + Vector2(0.42, -0.42) * r * (1.0 - 0.18 * float(i))
				ci.draw_line(a, b, Color(col, 0.85 - 0.2 * float(i)), w, true)
			ci.draw_circle(rock, r * 0.36, col)
			ci.draw_circle(rock + Vector2(-0.1, 0.08) * r, r * 0.09, Color(0, 0, 0, 0.35))
		"gozcu":
			# A satellite sweep: three arcs and a dot.
			ci.draw_circle(c + Vector2(0.0, 0.32) * r, r * 0.14, col)
			for i in 3:
				var rr := r * (0.38 + 0.26 * float(i))
				ci.draw_arc(c + Vector2(0.0, 0.32) * r, rr, -PI * 0.8, -PI * 0.2, 14, Color(col, 1.0 - 0.22 * float(i)), w, true)
		"muhafiz":
			# A dome on the ground with a hex.
			var base := c + Vector2(0.0, 0.42) * r
			ci.draw_arc(base, r * 0.82, PI, TAU, 22, col, w * 1.2, true)
			ci.draw_line(base + Vector2(-0.95, 0.0) * r, base + Vector2(0.95, 0.0) * r, col, w, true)
			var hx := PackedVector2Array()
			for k in 7:
				var a := TAU * float(k) / 6.0 + PI / 6.0
				hx.append(base + Vector2(0.0, -0.4) * r + Vector2(cos(a), sin(a)) * r * 0.2)
			ci.draw_polyline(hx, Color(col, 0.8), maxf(w * 0.7, 1.0), true)
		"kazici":
			# A slam: a zigzag wave over the ground and a crack under it.
			var y := c.y + 0.22 * r
			var pts := PackedVector2Array()
			for k in 7:
				var x := c.x + (-0.9 + 0.3 * float(k)) * r
				pts.append(Vector2(x, y - (0.3 * r if k % 2 == 1 else 0.0)))
			ci.draw_polyline(pts, col, w, true)
			ci.draw_line(Vector2(c.x - 0.95 * r, y + 0.2 * r), Vector2(c.x + 0.95 * r, y + 0.2 * r), Color(col, 0.7), w, true)
			ci.draw_polyline(PackedVector2Array([Vector2(c.x, y + 0.2 * r), Vector2(c.x - 0.12 * r, y + 0.45 * r),
					Vector2(c.x + 0.08 * r, y + 0.62 * r)]), Color(col, 0.7), maxf(w * 0.8, 1.0), true)
			ci.draw_line(Vector2(c.x, c.y - 0.85 * r), Vector2(c.x, c.y - 0.3 * r), col, w * 1.3, true)
			ci.draw_polyline(PackedVector2Array([Vector2(c.x - 0.2 * r, c.y - 0.48 * r), Vector2(c.x, c.y - 0.26 * r),
					Vector2(c.x + 0.2 * r, c.y - 0.48 * r)]), col, w, true)
		"avci":
			# A broken outline (the shimmer) with two eye slits.
			for k in 8:
				var a0 := TAU * float(k) / 8.0
				ci.draw_arc(c, r * 0.78, a0, a0 + TAU / 8.0 * 0.55, 5, Color(col, 0.55 + 0.45 * float(k % 2)), w, true)
			ci.draw_line(c + Vector2(-0.42, -0.05) * r, c + Vector2(-0.12, 0.02) * r, col, w * 1.3, true)
			ci.draw_line(c + Vector2(0.12, 0.02) * r, c + Vector2(0.42, -0.05) * r, col, w * 1.3, true)
		"muhendis":
			# A singularity: a spiral into a dark core.
			var pts := PackedVector2Array()
			for k in 40:
				var t := float(k) / 39.0
				var a := t * TAU * 1.75
				pts.append(c + Vector2(cos(a), sin(a)) * r * (0.85 - 0.62 * t))
			ci.draw_polyline(pts, col, w, true)
			ci.draw_circle(c, r * 0.2, col)
			ci.draw_circle(c, r * 0.11, Color(0.02, 0.02, 0.04, 0.9))
		_:
			ci.draw_circle(c, r * 0.4, col)
