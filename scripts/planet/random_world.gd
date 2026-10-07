extends RefCounted
## Random planets (2026-10-05, "Single player'da bizim gezegen ile karşı gezegenin renkleri vb random
## olsun, aynı olmasın"): every match builds BOTH planets from one world seed. Each planet gets
##   - a curated palette family (FAMILIES: ground, rock, dust, maria, strata, rock tint, soil, the
##     detail layer and the footstep set), jittered a little (hue, saturation, value; the whole
##     family moves together so it keeps its contrast). Home and rival always come from different
##     colour groups (warm / cool / green), so they never look alike;
##   - its own relief inside ranges safe for a 60 m planet: continents, hills, ridged ranges and
##     craters always; maria, terraces, crevasses or volcano cones sometimes. The highest ground is
##     budgeted under RELIEF_MAX (the LOD band is Bodies BASE max_height = 18 m) and the lows stay a
##     few metres deep, so spawning, building, the bots and the core depth (~57 m) stay as tuned;
##   - its rock density, its noise seed (float32-exact on the GPU: < 2^24) and a Turkish-flavoured
##     name ("Kızıl Kum"), shown under "Yurt" / "Rakip" (cfg "world_name").
## The team core colours (Bodies PRESETS core_color: home violet, rival crimson) are never touched.
##
##   RandomWorld.match_seed() -> int        single player: a new one per match ("Yeniden başla" too;
##                                          the user arg --seed=N repeats one); multiplayer: the
##                                          host's match config (cfg "world_seed", else "match"), so
##                                          both machines agree and nothing new travels; -1 = none
##   RandomWorld.generate(seed) -> {"seed", "home": overrides, "rival": overrides}
##   RandomWorld.current                    the world of the running match ({} = fixed planets: the
##                                          Eğitim Alanı, which keeps its own planet)
## Deterministic: RandomNumberGenerator (PCG32) seeded once, a fixed draw order, no other source of
## randomness, so the same seed gives the same planets on every machine.
## Lighting rule (no crushed blacks, no blown whites): every colour's value stays in V_MIN..V_MAX.

const Bodies := preload("res://scripts/planet/bodies.gd")

const V_MIN := 0.15
const V_MAX := 0.84
const S_MAX := 0.72
const HUE_JIT := 0.022                 # ± hue turn of a whole family (0..1 = the full circle)
const SAT_JIT := Vector2(0.88, 1.12)   # × saturation
const VAL_JIT := Vector2(0.93, 1.07)   # × value (the family)...
const VAL_EACH := 0.03                 # ...and ± per colour
const RELIEF_MAX := 13.0               # m: budget for the highest ground above the base radius
                                       # (2026-10-06: 6.5 -> 13 with the radius 30 -> 60 m, a scale model)
const ROCKS := Vector2(0.0006, 0.0032) # surface rocks per m² (BASE 0.0015)

## Palette families (sRGB). group: "warm" / "cool" / "green" (home and rival never share one);
## layer: the close-range detail texture of open ground (terrain_textures.gd: 0 soil, 2 sand,
## 3 snow); step: the footstep set (sfx.gd).
const FAMILIES := [
	{"id": "pas", "group": "warm", "layer": 2.0, "step": "step_rock",
		"col_low": Color(0.60, 0.30, 0.18), "col_high": Color(0.74, 0.45, 0.27), "col_rock": Color(0.48, 0.25, 0.16),
		"col_dust": Color(0.80, 0.55, 0.36), "col_mare": Color(0.48, 0.25, 0.16), "col_pool": Color(0.50, 0.30, 0.20),
		"col_crack": Color(0.30, 0.13, 0.09), "rock_tint": Color(0.54, 0.29, 0.18), "soil_color": Color(0.58, 0.31, 0.18),
		"strata": [Color(0.70, 0.40, 0.22), Color(0.56, 0.28, 0.16), Color(0.36, 0.20, 0.16)],
		"names": ["Kızıl Kum", "Paslı Ova", "Kor Tepe", "Kızılyar", "Al Bayır"]},
	{"id": "hardal", "group": "warm", "layer": 2.0, "step": "step_dirt",
		"col_low": Color(0.60, 0.49, 0.25), "col_high": Color(0.73, 0.62, 0.36), "col_rock": Color(0.47, 0.39, 0.24),
		"col_dust": Color(0.80, 0.70, 0.47), "col_mare": Color(0.49, 0.40, 0.21), "col_pool": Color(0.50, 0.42, 0.25),
		"col_crack": Color(0.30, 0.24, 0.13), "rock_tint": Color(0.54, 0.46, 0.30), "soil_color": Color(0.59, 0.46, 0.25),
		"strata": [Color(0.66, 0.51, 0.28), Color(0.54, 0.40, 0.22), Color(0.37, 0.28, 0.18)],
		"names": ["Hardal Tepe", "Safran Ova", "Amber Yayla", "Sarı Bayır", "Kehribar Vadi"]},
	{"id": "gul", "group": "warm", "layer": 2.0, "step": "step_dirt",
		"col_low": Color(0.64, 0.45, 0.38), "col_high": Color(0.76, 0.59, 0.50), "col_rock": Color(0.51, 0.36, 0.31),
		"col_dust": Color(0.82, 0.67, 0.58), "col_mare": Color(0.54, 0.38, 0.33), "col_pool": Color(0.55, 0.40, 0.35),
		"col_crack": Color(0.32, 0.20, 0.17), "rock_tint": Color(0.59, 0.44, 0.38), "soil_color": Color(0.62, 0.44, 0.36),
		"strata": [Color(0.70, 0.49, 0.40), Color(0.57, 0.39, 0.33), Color(0.39, 0.28, 0.25)],
		"names": ["Gül Kaya", "Mercan Tepe", "Pembe Kum", "Kiremit Sırt", "Somon Vadi"]},
	{"id": "bakir", "group": "warm", "layer": 0.0, "step": "step_rock",
		"col_low": Color(0.50, 0.35, 0.25), "col_high": Color(0.62, 0.47, 0.34), "col_rock": Color(0.30, 0.44, 0.41),
		"col_dust": Color(0.66, 0.55, 0.42), "col_mare": Color(0.27, 0.40, 0.38), "col_pool": Color(0.25, 0.42, 0.40),
		"col_crack": Color(0.16, 0.26, 0.25), "rock_tint": Color(0.36, 0.48, 0.45), "soil_color": Color(0.55, 0.38, 0.26),
		"strata": [Color(0.58, 0.40, 0.27), Color(0.45, 0.33, 0.25), Color(0.30, 0.32, 0.30)],
		"names": ["Bakır Ova", "Tunç Tepe", "Pas Yaylası", "Bakırlı Vadi", "Tunç Kaya"]},
	{"id": "kul", "group": "cool", "layer": 0.0, "step": "step_rock",
		"col_low": Color(0.40, 0.40, 0.41), "col_high": Color(0.55, 0.55, 0.56), "col_rock": Color(0.34, 0.34, 0.36),
		"col_dust": Color(0.62, 0.61, 0.59), "col_mare": Color(0.31, 0.31, 0.33), "col_pool": Color(0.33, 0.33, 0.35),
		"col_crack": Color(0.20, 0.20, 0.21), "rock_tint": Color(0.46, 0.46, 0.47), "soil_color": Color(0.48, 0.46, 0.43),
		"strata": [Color(0.50, 0.48, 0.46), Color(0.40, 0.39, 0.39), Color(0.29, 0.29, 0.31)],
		"names": ["Kül Ovası", "Boz Kaya", "Dumanlı Yayla", "Kurşun Tepe", "Gri Sırt"]},
	{"id": "mor", "group": "cool", "layer": 0.0, "step": "step_rock",
		"col_low": Color(0.35, 0.30, 0.40), "col_high": Color(0.47, 0.41, 0.52), "col_rock": Color(0.28, 0.25, 0.32),
		"col_dust": Color(0.57, 0.52, 0.59), "col_mare": Color(0.26, 0.23, 0.31), "col_pool": Color(0.30, 0.25, 0.36),
		"col_crack": Color(0.17, 0.15, 0.21), "rock_tint": Color(0.40, 0.36, 0.44), "soil_color": Color(0.43, 0.35, 0.41),
		"strata": [Color(0.45, 0.37, 0.43), Color(0.36, 0.30, 0.37), Color(0.27, 0.24, 0.30)],
		"names": ["Mor Kaya", "Erguvan Sırt", "Leylak Ova", "Mor Bazalt", "Gece Yaylası"]},
	{"id": "buz", "group": "cool", "layer": 3.0, "step": "step_rock",
		"col_low": Color(0.60, 0.66, 0.72), "col_high": Color(0.72, 0.77, 0.82), "col_rock": Color(0.42, 0.47, 0.54),
		"col_dust": Color(0.76, 0.80, 0.84), "col_mare": Color(0.50, 0.58, 0.66), "col_pool": Color(0.55, 0.65, 0.75),
		"col_crack": Color(0.30, 0.40, 0.50), "rock_tint": Color(0.52, 0.57, 0.63), "soil_color": Color(0.62, 0.66, 0.70),
		"strata": [Color(0.58, 0.62, 0.67), Color(0.46, 0.50, 0.56), Color(0.33, 0.36, 0.42)],
		"names": ["Buzul", "Kırağı Ova", "Ayaz Tepe", "Ak Yayla", "Buzlu Vadi"]},
	{"id": "yosun", "group": "green", "layer": 0.0, "step": "step_dirt",
		"col_low": Color(0.25, 0.37, 0.33), "col_high": Color(0.37, 0.49, 0.41), "col_rock": Color(0.31, 0.34, 0.33),
		"col_dust": Color(0.49, 0.53, 0.43), "col_mare": Color(0.21, 0.32, 0.30), "col_pool": Color(0.20, 0.32, 0.32),
		"col_crack": Color(0.15, 0.21, 0.20), "rock_tint": Color(0.39, 0.43, 0.41), "soil_color": Color(0.40, 0.33, 0.24),
		"strata": [Color(0.42, 0.36, 0.27), Color(0.34, 0.31, 0.26), Color(0.26, 0.26, 0.26)],
		"names": ["Yosunlu Vadi", "Zümrüt Yamaç", "Yeşil Kaya", "Çamlı Sırt", "Küf Ovası"]},
	{"id": "toprak", "group": "green", "layer": 0.0, "step": "step_dirt",
		"col_low": Color(0.30, 0.34, 0.25), "col_high": Color(0.42, 0.45, 0.35), "col_rock": Color(0.34, 0.33, 0.31),
		"col_dust": Color(0.47, 0.45, 0.37), "col_mare": Color(0.27, 0.30, 0.23), "col_pool": Color(0.30, 0.30, 0.30),
		"col_crack": Color(0.20, 0.20, 0.20), "rock_tint": Color(0.42, 0.42, 0.40), "soil_color": Color(0.42, 0.33, 0.22),
		"strata": [Color(0.46, 0.37, 0.27), Color(0.37, 0.31, 0.25), Color(0.27, 0.25, 0.25)],
		"names": ["Zeytinlik", "Boz Toprak", "Yeşil Ova", "Kuru Vadi", "Kekik Tepe"]},
]
## Colour keys jittered per planet (a fixed order: the draws must be the same on every machine).
const COLOR_KEYS := ["col_low", "col_high", "col_rock", "col_dust", "col_mare", "col_pool", "col_crack",
		"rock_tint", "soil_color"]

## The running match's world (main.gd sets it): {"seed", "home", "rival"}; {} = fixed planets.
static var current := {}


## The seed of a new match (see the header); -1 = keep the fixed preset planets.
static func match_seed() -> int:
	if Net.active:
		var c: Dictionary = Net.cfg
		if c.has("world_seed"):
			return int(c["world_seed"])
		if c.has("match"):
			return int(c["match"])
		return -1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			return int(a.substr(7))
	var r := RandomNumberGenerator.new()
	r.randomize()
	return r.randi_range(100000, 999999)


## Both planets' overrides for Bodies.spawn (merged over the presets); {} for seed < 0.
static func generate(world_seed: int) -> Dictionary:
	if world_seed < 0:
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed
	var n := FAMILIES.size()
	var fh := rng.randi_range(0, n - 1)
	var cands: Array = []
	for i in n:
		if str(FAMILIES[i]["group"]) != str(FAMILIES[fh]["group"]):
			cands.append(i)
	var fr: int = cands[rng.randi_range(0, cands.size() - 1)]
	var home := _planet(rng, fh)
	var rival := _planet(rng, fr)
	if int(rival["seed"]) == int(home["seed"]):
		rival["seed"] = int(home["seed"]) % 999000 + 1001
	return {"seed": world_seed, "home": home, "rival": rival}


## "Yurt — Kızıl Kum   ·   Rakip — Kül Ovası" (own planet first), "" without a random world.
static func names_line(own: Node3D, other: Node3D) -> String:
	var parts: Array = []
	for b in [own, other]:
		if b == null or not is_instance_valid(b):
			continue
		var c = b.get("cfg")
		var wn := str((c as Dictionary).get("world_name", "")) if c is Dictionary else ""
		if wn != "":
			parts.append("%s — %s" % [str(b.get("display_name")), wn])
	return "   ·   ".join(PackedStringArray(parts))


static func _planet(rng: RandomNumberGenerator, fi: int) -> Dictionary:
	var f: Dictionary = FAMILIES[fi]
	var dh := rng.randf_range(-HUE_JIT, HUE_JIT)
	var ks := rng.randf_range(SAT_JIT.x, SAT_JIT.y)
	var kv := rng.randf_range(VAL_JIT.x, VAL_JIT.y)
	var o := {}
	for k in COLOR_KEYS:
		o[k] = _jit(f[k], dh, ks, kv, rng)
	var st: Array = []
	for c in f["strata"]:
		st.append(_jit(c, dh, ks, kv, rng))
	o["strata"] = st
	o["step"] = f["step"]
	o["detail_flat_layer"] = float(f["layer"])
	o.merge(_relief(rng), true)
	o["rock_density"] = rng.randf_range(ROCKS.x, ROCKS.y)
	o["seed"] = rng.randi_range(1000, 999999)
	var names: Array = f["names"]
	o["world_name"] = str(names[rng.randi_range(0, names.size() - 1)])
	o["family"] = f["id"]
	return o


static func _jit(c: Color, dh: float, ks: float, kv: float, rng: RandomNumberGenerator) -> Color:
	var v := clampf(c.v * kv * (1.0 + rng.randf_range(-VAL_EACH, VAL_EACH)), V_MIN, V_MAX)
	return Color.from_hsv(fposmod(c.h + dh, 1.0), clampf(c.s * ks, 0.0, S_MAX), v)


## The m_* relief keys (terrain_gen.gd / gpu_density.gd) around Bodies BASE, scaled with the radius.
static func _relief(rng: RandomNumberGenerator) -> Dictionary:
	var r := Bodies.PLANET_RADIUS
	var cont := r / 12.0 * rng.randf_range(0.6, 1.35)
	var hill := r / 30.0 * rng.randf_range(0.6, 1.5)
	var mount := r / 17.0 * rng.randf_range(0.35, 1.45)
	var c_amp := rng.randf_range(0.12, 0.34)
	var c_cell := r * rng.randf_range(0.22, 0.34)
	var c_den := rng.randf_range(0.12, 0.42)
	var f_cont := 1.0 / (r * rng.randf_range(1.0, 1.6))
	var f_hill := 1.0 / (r * rng.randf_range(0.28, 0.48))
	# Optional features (always drawn, so the draw order never changes).
	var u_mare := rng.randf()
	var mare := rng.randf_range(0.45, 0.9)
	var u_terr := rng.randf()
	var terr := rng.randf_range(1.4, 2.2)
	var u_crev := rng.randf()
	var crev := rng.randf_range(0.35, 0.8)
	var u_volc := rng.randf()
	var volc := r / 15.0 * rng.randf_range(0.5, 1.1)
	# Steepness caps (amplitude × frequency; BASE: continents 0.067, hills 0.09): walkable and
	# buildable slopes whatever the draw.
	cont = minf(cont, 0.09 / f_cont)
	hill = minf(hill, 0.11 / f_hill)
	mare = mare if u_mare < 0.45 else 0.0
	terr = terr if u_terr < 0.3 else 0.0
	crev = crev if u_crev < 0.25 else 0.0
	volc = volc if u_volc < 0.22 else 0.0
	# Budget the highest ground (fbm rarely passes ±0.8; the ranges' ridges peak at 1; a volcano
	# cone ~0.7 with its summit crater; crater rims ~0.15 × amp × cell).
	var top := 0.8 * cont + 0.8 * hill + mount + 0.8 * volc + 0.16 * c_amp * c_cell
	if top > RELIEF_MAX:
		var k := RELIEF_MAX / top
		cont *= k
		hill *= k
		mount *= k
		volc *= k
		top = RELIEF_MAX
	# (snapped to 2^-16: exact in the GPU sampler's float32 too, so CPU and GPU terrain agree)
	return {
		"m_amp_cont": _q(cont), "m_freq_cont": _q(f_cont), "m_amp_hill": _q(hill), "m_freq_hill": _q(f_hill),
		"m_amp_mount": _q(mount), "m_maria": _q(mare), "m_terrace": _q(terr), "m_crevasse": _q(crev),
		"m_crater_amp": _q(c_amp), "m_crater_cell": _q(c_cell), "m_crater_density": _q(c_den), "m_volcano": _q(volc),
		"height_range": clampf(top * 0.9, 6.4, 12.0),          # (colour ramp; 3.2..6.0 at R 30)
	}


static func _q(x: float) -> float:
	return snappedf(x, 1.0 / 65536.0)
