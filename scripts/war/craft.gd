extends RefCounted
## Crafting recipes of the Silahlık (scripts/war/armory.gd, panel scripts/war/craft_menu.gd): what
## can be made, its key, price (Balance.CRAFT_COST), time (Balance.CRAFT_TIME), the card text and
## stats, the gun script whose own model the card thumbnail renders (scripts/war/build_preview.gd).
##   Craft.recipes() -> Array of {id, name, key, cost, time, desc, stats: [[label, value], ...],
##                               item_script | grenade, thumb_id}
##   Craft.owned(id) -> bool        a gun the local player has (grenades: never "owned", a stack)
##   Craft.grant(id)                gives the finished craft to the local player (unlock + reserve,
##                                  or GRENADE_STACK grenades), with the "YENİ SİLAH" toast
## Guns are gated, not added: player.gd keeps every gun in `items` and select_item() refuses one
## you do not carry. A finished gun is yours (Game.unlock) and carried at once, with every other gun
## you have: its key comes from its place in Game.GUN_ORDER among the carried guns (3, 4, 5 …), so no
## recipe has a fixed key (key 0 -> ""). The drilling torpedo is no longer crafted (nor fired): it is built with the İnşa
## Aracı as a Sondaj Kulesi on the enemy planet (scripts/war/torpedo_rig.gd). Also: the Delici Raylı
## Tüfek ("rail", scripts/items/railgun.gd, Balance.RAIL_*) and the Hafif Makineli ("smg",
## scripts/items/smg.gd, Balance.SMG_*).
## Attachments (scripts/items/attachments.gd): recipe "att_<id>" per attachment (attachment_recipes(),
## not in recipes(): the gun grid stays guns; the EKLENTİLER tab, scripts/war/attachments_panel.gd,
## starts them), price / time Balance.ATT_CRAFT_COST / ATT_CRAFT_TIME; a finished one is
## Attachments.unlock(id) (owned for every compatible gun, fitted with the middle mouse radial).
## Drill upgrades (scripts/items/drill_tiers.gd): recipe "drill_mk2" / "drill_mk3" / "drill_mk4"
## (drill_recipes(), not in recipes(); each card has "drill_tier", "color", "requires"), price / time
## Balance.DRILL_CRAFT_COST / DRILL_CRAFT_TIME; each needs the tier before it (blocked() says so);
## a finished one is DrillTiers.unlock(tier) (the Kazı Aracı changes at once). drill_next() is the
## next one to make ({} at Mk IV).
## 2026-10-06 (the user: crafting guns slowed the game down): GUNS ARE NOT SOLD here any more (blocked()
## says so): everyone spawns with the loadout (Game.set_loadout: a primary, rifle / SMG / shotgun, + a
## sidearm, Tabanca / Altıpatlar / Makineli Tabanca, or the Toprak Topu)
## and power weapons come by İkmal kapsülü (scripts/war/supply_pod.gd, Tab). recipes() stays the guns'
## card data (name, role, stats, thumbnail: the loadout picker, the quickbar, the pod menu read it).
## The Silahlık sells PERMANENT upgrades (shop(): the next drill tier, İkmal İndirimi "upg_pod<n>",
## Bomba Kemeri "upg_pouch<n>": upgrade_recipes(), Balance.UPG_*, Game.set_upgrade) plus the grenade
## stack, and the attachments; every purchase is INSTANT (armory.gd start_craft pays and grants at
## once; the "time" fields are no longer used).

const Balance := preload("res://scripts/war/balance.gd")
const Attachments := preload("res://scripts/items/attachments.gd")
const DrillTiers := preload("res://scripts/items/drill_tiers.gd")


static func recipes() -> Array:
	return [
		_r("rifle", "Tüfek", 0, "res://scripts/items/rifle.gd",
				"Çok yönlü otomatik tüfek: tek atış ya da 3'lü seri, delici mermi (T).",
				[["Hasar", "38 · delici 88"], ["Atış", "5,5/s"], ["Şarjör", "30 · 10"]]),
		_r("shotgun", "Pompalı", 0, "res://scripts/items/shotgun.gd",
				"Yakın mesafede yıkıcı: 9 saçma, her atıştan sonra pompalar.",
				[["Hasar", "9 × 17"], ["Atış", "1,35/s"], ["Şarjör", "6"]]),
		_r("sniper", "Keskin Nişancı", 0, "res://scripts/items/sniper.gd",
				"Sürgülü ağır tüfek, 4×/6× dürbün. Kafaya tek atış.",
				[["Hasar", "82 · kafa ×3"], ["Atış", "sürgü 1,3 s"], ["Şarjör", "5"]]),
		_r("pusher", "Kinetik İtici", 0, "res://scripts/items/kinetic_pusher.gd",
				"Şok dalgası: botları savurur, zemini söküp atar.",
				[["Menzil", "%d m" % int(Balance.PUSH_RANGE)], ["Şarj", ("%d · %s m³" % [Balance.PUSH_CHARGES, String.num(Balance.PUSH_COST, 0)])
						if Balance.PUSH_COST > 0.0 else "%d" % Balance.PUSH_CHARGES],
					["Hasar", "%d" % int(Balance.PUSH_DAMAGE)]]),
		_r("rocket", "Roketatar", 0, "res://scripts/items/rocket_launcher.gd",
				"Güdümsüz roket: geniş patlama, krater açar.",
				[["Hasar", "%d" % int(Balance.ROCKET_DAMAGE)], ["Yarıçap", "%s m" % String.num(Balance.ROCKET_RADIUS, 1)], ["Şarjör", "1"]]),
		_r("rail", "Delici Raylı Tüfek", 0, "res://scripts/items/railgun.gd",
				"Basılı tut: şarj, bırak: ateş. Işın toprağı deler, tünelde saklananı vurur.",
				[["Hasar", "%d" % int(Balance.RAIL_DAMAGE)], ["Toprak", "%d m" % int(Balance.RAIL_MAX_SOIL)], ["Şarjör", "%d" % Balance.RAIL_MAG]]),
		_r("smg", "Hafif Makineli", 0, "res://scripts/items/smg.gd",
				"Yakında çok hızlı ateş, uzakta zayıf. B: tek / seri atış.",
				[["Hasar", "%s" % String.num(Balance.SMG_DAMAGE, 1)], ["Atış", "%s/s" % String.num(Balance.SMG_RATE, 1)], ["Şarjör", "%d" % Balance.SMG_MAG]]),
		# Sidearms (loadout slot B; Balance SIDEARMS block).
		_r("pistol", "Tabanca", 0, "res://scripts/items/pistol.gd",
				"Yarı otomatik yedek silah: çok hızlı çekilir, isabetli, hafif teper.",
				[["Hasar", "%s" % String.num(Balance.PISTOL_DAMAGE, 0)], ["Atış", "%s/s" % String.num(Balance.PISTOL_RATE, 1)],
					["Şarjör", "%d" % Balance.PISTOL_MAG]]),
		_r("revolver", "Altıpatlar", 0, "res://scripts/items/revolver.gd",
				"Ağır magnum: yavaş ama yakında kafaya tek atış. Fişek fişek doldurulur.",
				[["Hasar", "%s" % String.num(Balance.REVOLVER_DAMAGE, 0)], ["Atış", "%s/s" % String.num(Balance.REVOLVER_RATE, 1)],
					["Şarjör", "%d" % Balance.REVOLVER_MAG]]),
		_r("mpistol", "Makineli Tabanca", 0, "res://scripts/items/mpistol.gd",
				"Tam otomatik tabanca: yakında mermi yağmuru, sert yukarı teper. B: tek / seri atış.",
				[["Hasar", "%s" % String.num(Balance.MPISTOL_DAMAGE, 0)], ["Atış", "%s/s" % String.num(Balance.MPISTOL_RATE, 0)],
					["Şarjör", "%d" % Balance.MPISTOL_MAG]]),
		_r("dirt", "Toprak Topu", 0, "res://scripts/items/dirt_launcher.gd",
				"Cephanesi kazdığın toprak. Sol tık: toprak gülle, tümsek yığar · sağ tık: toprak duvar, siper/tünel tıkacı. Düşmanı gömer.",
				[["Gülle", "5 m³"], ["Duvar", "30 m³"], ["Cephane", "toprak"]]),
		_r("mortar", "Havan", 0, "res://scripts/items/mortar.gd",
				"Eğri atış: tepenin, ufkun ardına. Tarayıcıyla işaretle (T), görmeden vur.",
				[["Hasar", "170"], ["Menzil", "15-140 m"], ["Şarjör", "1"]]),
		_r("plasma", "Plazma Kesici", 0, "res://scripts/items/plasma_cutter.gd",
				"Kısa menzilli ışın: yakında eritir, toprağı matkaptan 3 kat hızlı keser. Sağ tık: duvara kapı aç. Isınır; R: soğut.",
				[["Hasar", "90/s"], ["Menzil", "9 m"], ["Cephane", "yok · ısı"]]),
		{"id": "grenade", "name": "El Bombası ×%d" % Balance.GRENADE_STACK, "key": "G", "cost": float(Balance.CRAFT_COST["grenade"]),
			"time": float(Balance.CRAFT_TIME["grenade"]), "grenade": true, "thumb_id": "craft_grenade",
			"desc": "G basılı: pimi çek, pişir · bırak: fırlat. En çok %d taşınır." % Game.grenade_max(),
			"stats": [["Hasar", "%d" % int(Balance.GRENADE_DAMAGE)], ["Yarıçap", "%s m" % String.num(Balance.GRENADE_RADIUS, 1)],
				["Yığın", "+%d" % Balance.GRENADE_STACK]]},
	]


static func _r(id: String, nm: String, key: int, path: String, desc: String, stats: Array) -> Dictionary:
	return {"id": id, "name": nm, "key": str(key) if key > 0 else "", "cost": float(Balance.CRAFT_COST.get(id, 100.0)),
			"time": float(Balance.CRAFT_TIME.get(id, 5.0)), "item_script": path, "thumb_id": "craft_" + id,
			"desc": desc, "stats": stats}


## One recipe per attachment ("att_<id>"; attachments.gd list()): its stats as card lines.
static func attachment_recipes() -> Array:
	var out: Array = []
	for e in Attachments.list():
		var aid := str(e["id"])
		var stats: Array = []
		for s in e.get("stats_text", []):
			stats.append([str(s[0]), str(s[1])])
		out.append({"id": "att_" + aid, "name": str(e["name"]), "key": "", "attachment": aid,
				"cost": float(Balance.ATT_CRAFT_COST.get("att_" + aid, e.get("cost", 60.0))),
				"time": float(Balance.ATT_CRAFT_TIME.get("att_" + aid, e.get("time", 4.0))),
				"thumb_id": "att_" + aid, "desc": str(e.get("desc", "")), "stats": stats})
	return out


## One recipe per drill upgrade ("drill_mk2" .. "drill_mk4"; drill_tiers.gd recipe_list()).
static func drill_recipes() -> Array:
	return DrillTiers.recipe_list()


## The next drill upgrade to make ({} when the drill is Mk IV).
static func drill_next() -> Dictionary:
	var t := DrillTiers.tier() + 1
	return recipe(DrillTiers.recipe_id(t)) if t <= DrillTiers.MAX_TIER else {}


## The Silahlık's own upgrades, one card per level ("upg_pod1", "upg_pod2", "upg_pouch1", …: "upgrade"
## kind, "level", "icon", "color", "requires" the level before), kept until the match ends.
static func upgrade_recipes() -> Array:
	var out: Array = []
	var roman := ["", "I", "II", "III", "IV"]
	var lo := INF
	var hi := 0.0
	for g in Balance.SUPPLY_COST:
		lo = minf(lo, float(Balance.SUPPLY_COST[g]))
		hi = maxf(hi, float(Balance.SUPPLY_COST[g]))
	for lv in range(1, Balance.UPG_POD_COST.size()):
		var off := float(Balance.UPG_POD_DISCOUNT[lv])
		out.append({"id": "upg_pod%d" % lv, "name": "İkmal İndirimi %s" % roman[mini(lv, 4)], "key": "", "upgrade": "pod",
				"level": lv, "cost": float(Balance.UPG_POD_COST[lv]), "time": 0.0, "thumb_id": "upg_pod", "icon": "pod",
				"color": Color(1.0, 0.55, 0.18), "requires": ("upg_pod%d" % (lv - 1)) if lv > 1 else "",
				"desc": "İkmal kapsülleri (Tab) bu maç boyunca %%%d daha ucuz." % int(roundf(off * 100.0)),
				"stats": [["İndirim", "%%%d" % int(roundf(off * 100.0))],
					["Kapsül", "%d–%d m³" % [int(roundf(lo * (1.0 - off))), int(roundf(hi * (1.0 - off)))]],
					["Bekleme", "%d sn" % int(Balance.SUPPLY_COOLDOWN)]]})
	for lv in range(1, Balance.UPG_POUCH_COST.size()):
		var cap := Balance.GRENADE_MAX + int(Balance.UPG_POUCH[lv])
		out.append({"id": "upg_pouch%d" % lv, "name": "Bomba Kemeri %s" % roman[mini(lv, 4)], "key": "", "upgrade": "pouch",
				"level": lv, "cost": float(Balance.UPG_POUCH_COST[lv]), "time": 0.0, "thumb_id": "upg_pouch", "icon": "pouch",
				"color": Color(0.45, 0.95, 0.62), "requires": ("upg_pouch%d" % (lv - 1)) if lv > 1 else "",
				"desc": "Daha geniş kemer: bu maç boyunca en çok %d el bombası taşırsın." % cap,
				"stats": [["Taşıma", "%d" % cap], ["Ek", "+%d" % int(Balance.UPG_POUCH[lv])],
					["Doğuşta", "%d bomba" % Balance.LOADOUT_GRENADES]]})
	return out


## The next level of upgrade `kind` ("pod" / "pouch"; {} at the top).
static func upgrade_next(kind: String) -> Dictionary:
	for r in upgrade_recipes():
		if str(r["upgrade"]) == kind and int(r["level"]) == Game.upgrade_level(kind) + 1:
			return r
	return {}


## The KALICI GELİŞMELER cards (craft_menu.gd), in order: the next drill tier, the next İkmal İndirimi,
## the next Bomba Kemeri (each line's top level, owned, once it is maxed), then the grenade stack.
static func shop() -> Array:
	var out: Array = []
	var d := drill_next()
	if d.is_empty():
		var all := drill_recipes()
		if not all.is_empty():
			d = all[all.size() - 1]
	if not d.is_empty():
		out.append(d)
	for kind in ["pod", "pouch"]:
		var u := upgrade_next(kind)
		if u.is_empty():
			for r in upgrade_recipes():
				if str(r["upgrade"]) == kind:
					u = r                      # (the last level: owned)
		if not u.is_empty():
			out.append(u)
	out.append(recipe("grenade"))
	return out


static func recipe(id: String) -> Dictionary:
	for r in recipes():
		if str(r["id"]) == id:
			return r
	if id.begins_with("att_"):
		for r in attachment_recipes():
			if str(r["id"]) == id:
				return r
	if id.begins_with("drill_"):
		for r in drill_recipes():
			if str(r["id"]) == id:
				return r
	if id.begins_with("upg_"):
		for r in upgrade_recipes():
			if str(r["id"]) == id:
				return r
	return {}


static func owned(id: String) -> bool:
	if id == "grenade":
		return false
	if id.begins_with("att_"):
		return Attachments.owned(id.substr(4))
	if id.begins_with("drill_"):
		var t := DrillTiers.tier_of(id)
		return t > 0 and DrillTiers.tier() >= t
	if id.begins_with("upg_"):
		var u := recipe(id)
		return not u.is_empty() and Game.upgrade_level(str(u["upgrade"])) >= int(u["level"])
	return Game.owns(id)


## Why `id` cannot be crafted right now ("" = it can).
static func blocked(id: String) -> String:
	if id == "grenade":
		if Game.grenades >= Game.grenade_max():
			return "Bomba cebi dolu (%d)" % Game.grenade_max()
	elif owned(id):
		return "Sende var"
	elif recipe(id).has("item_script"):
		return "Silahlar İkmal kapsülüyle gelir (Tab)"
	elif id.begins_with("drill_") and DrillTiers.tier_of(id) > DrillTiers.tier() + 1:
		return "Önce Matkap %s gerekli" % DrillTiers.tier_name(DrillTiers.tier_of(id) - 1)
	elif id.begins_with("upg_") and str(recipe(id).get("requires", "")) != "" and not owned(str(recipe(id)["requires"])):
		return "Önce %s gerekli" % str(recipe(str(recipe(id)["requires"])).get("name", ""))
	var cost := float(Balance.CRAFT_COST.get(id, Balance.ATT_CRAFT_COST.get(id, Balance.DRILL_CRAFT_COST.get(id, 0.0))))
	if id.begins_with("upg_"):
		cost = float(recipe(id).get("cost", 0.0))
	if Game.material + 0.001 < cost:
		return "Yetersiz malzeme: %d m³ eksik" % int(ceilf(cost - Game.material))
	return ""


## The finished craft goes to the local player: the gun (with its starter reserve) or a grenade stack.
static func grant(id: String) -> void:
	var r := recipe(id)
	if id == "grenade":
		Game.grenades = mini(Game.grenades + Balance.GRENADE_STACK, Game.grenade_max())
		Game.loadout_changed.emit()
		if Game.hud:
			Game.hud.alert("EL BOMBASI +%d  (%d)  ·  G" % [Balance.GRENADE_STACK, Game.grenades], 1, "craft", 3.0)
	elif id.begins_with("att_"):
		Attachments.unlock(id.substr(4))   # owned for every compatible gun
		if Game.hud:
			Game.hud.alert("YENİ EKLENTİ: %s  ·  oyunda orta tuşu basılı tut, tak" % str(r.get("name", id)), 1, "craft", 3.5)
	elif id.begins_with("drill_"):
		var t := DrillTiers.tier_of(id)
		DrillTiers.unlock(t)               # the Kazı Aracı changes at once (drill_tiers.gd events)
		if Game.hud:
			var extra := ""
			if t == 2:
				extra = "  ·  yakındaki kraterlerin toprağı da toplanır"
			elif t == 3:
				extra = "  ·  E basılı: delici sonda"
			Game.hud.alert("MATKAP YÜKSELTİLDİ: %s%s" % [DrillTiers.tier_name(t), extra], 1, "craft", 3.5)
	elif id.begins_with("upg_"):
		if not r.is_empty():
			Game.set_upgrade(str(r["upgrade"]), int(r["level"]))
			if Game.hud:
				Game.hud.alert("KALICI GELİŞME: %s  ·  %s" % [str(r.get("name", id)), str(r.get("desc", ""))], 1, "craft", 3.5)
	else:
		var res: Dictionary = Balance.CRAFT_RESERVE.get(id, {})
		for a in res:
			Game.ammo[a] = Game.ammo_reserve(str(a)) + int(res[a])
		Game.ammo_changed.emit()
		Game.unlock(id)                    # (carried from now on: keys 3 … by Game.GUN_ORDER)
		if Game.hud:
			Game.hud.alert("YENİ SİLAH: %s  ·  tuş %s" % [str(r.get("name", id)), Game.key_label(Game.gun_index(id))], 1, "craft", 3.5)
	if Game.sfx:
		Game.sfx.play("craft", -4.0, 1.0)
		Game.sfx.play("ding", -10.0, 1.2)
