extends RefCounted
## What the bots say and show over their heads (2026-10-06, "NPC tepkileri"): the small "!" glyph of a
## sighting and the callout lines (Turkish, a few variants each), shared by the host's bots
## (scripts/war/ai_rival.gd "Reactions and body language") and a multiplayer client's puppets
## (scripts/net/net_bot.gd mirrors RivalTeam.events() bot_alert / bot_callout through these).
##
##   BotCues.alert(node, kind)                  "!" over node's head: "seen" (red, ~1.1 s: it just saw
##                                              you), "marked" (amber, ~2 s: an ally points it out to you)
##   BotCues.line_text(line, variant, arg) -> String     the callout's text (arg: see pack_clock / names)
##   BotCues.say(node, text, ally)              the line over the speaker's head (BL_SAY_RANGE of the
##                                              camera), fading; ally: our side's colour
##   BotCues.pick(line) -> int                  a random variant of a line
##   BotCues.pack_clock(from, fwd, up, to) -> int    "saat N yönünde, M metre" packed for arg
##   BotCues.radio_kind(line) -> String         the radio_fx.gd bot_event kind that voices it ("" none)
##   BotCues.team_may_call(team, gap) -> bool   the team-wide gap between two callouts (and takes it)
## Both labels are children of the node (they follow it, die with it), billboarded, depth-tested
## (a hill hides them), fixed screen size; colours from scripts/ui/ui_style.gd.

const UI := preload("res://scripts/ui/ui_style.gd")
const Balance := preload("res://scripts/war/balance.gd")

const ALERT_H := 2.3                   # m over the node's origin (the feet)
const SAY_H := 2.62
const NAMES := ["Kazıcı", "Mühendis", "Akıncı", "Muhafız"]
## line -> variants. %s placeholders: "spot" / "ally_spot" (clock, distance words), "ally_down" (a name).
const LINES := {
	"spot": ["Düşman görüldü! Saat %s yönünde, %s!", "Temas! Saat %s, %s!", "Gördüm onu! Saat %s yönünde, %s!"],
	"move_up": ["İlerle! İlerle!", "Öne çıkıyoruz!", "Hadi, bastırın!"],
	"hold": ["Bekle! Pozisyonu koru!", "Yerinizde kalın!", "Tutun orayı!"],
	"cover_me": ["Beni koruyun, şarjör değiştiriyorum!", "Şarjör! Ört beni!", "Dolduruyorum, koruma ateşi!"],
	"grenade": ["El bombası atıyorum!", "Bomba geliyor, eğilin!", "El bombası!"],
	"retreat": ["Geri çekiliyorum!", "Çekiliyorum, ört beni!", "Geri! Geri!"],
	"raid_return": ["Mekiğe! Geri çekiliyoruz!", "Herkes mekiğe, dönüyoruz!"],
	"wounded": ["Yaralıyım!", "Vuruldum, yaralıyım!", "Yaralandım! Destek lazım!"],
	"pinned": ["Sıkıştırıldım!", "Kafamı kaldıramıyorum!", "Ateş altındayım, çıkamıyorum!", "Bastırıldım, ört beni!"],
	"ally_down": ["%s düştü!", "%s vuruldu!", "Kayıp var! %s düştü!"],
	"kill": ["Hedef etkisiz!", "Hedef düştü.", "Etkisiz hâle getirildi."],
	"cower": ["Siper al!", "Eğil!"],
	"heard": ["Silah sesi!", "Ateş var, dikkat!", "Sesi duydun mu?"],
	"ally_spot": ["Düşman! Saat %s yönünde, %s!", "Dikkat, saat %s! %s!", "Rakip var, saat %s, %s!"],
	"nice_shot": ["İyi atış!", "Tam isabet!", "Güzel vuruş!"],
	"greet": ["Selam komutan.", "Buradayım.", "Her şey yolunda."],
	"ack_follow": ["Anlaşıldı, peşindeyim!", "Tamam, seninleyim."],
	"ack_guard": ["Anlaşıldı, üssü koruyorum.", "Tamam, nöbetteyim."],
	"ack_dig": ["Anlaşıldı, kazmaya dönüyorum.", "Tamam, işe dönüyorum."],
}
## The radio_fx.gd kind that voices a line (the radio is wordless: the line shows as text). Lines
## the bot code already voices elsewhere (spot: _enter_combat "contact", cover_me: the reload,
## grenade: bot_action, ally_down: _die "down", pinned: the suppression section's "pinned") stay
## silent here.
const RADIO := {"move_up": "reply", "hold": "reply", "retreat": "alert", "raid_return": "alert",
		"wounded": "hit", "kill": "reply", "cower": "reply", "heard": "alert",
		"ally_spot": "contact", "nice_shot": "reply", "greet": "reply", "ack_follow": "reply",
		"ack_guard": "reply", "ack_dig": "reply"}
## Lines that are urgent (the label pops in larger, brighter).
const URGENT := ["spot", "grenade", "retreat", "wounded", "pinned", "ally_down", "ally_spot", "cower"]

static var _team_last := {}            # team -> msec of its last callout


static func pick(line: String) -> int:
	var v: Array = LINES.get(line, [""])
	return randi() % maxi(v.size(), 1)


## The callout text. arg: "spot" / "ally_spot" = pack_clock(); "ally_down" = index into NAMES.
static func line_text(line: String, variant: int, arg := 0) -> String:
	var v: Array = LINES.get(line, [])
	if v.is_empty():
		return ""
	var s: String = v[posmod(variant, v.size())]
	match line:
		"spot", "ally_spot":
			var clock := clampi(arg / 1000, 1, 12)
			var dist := arg % 1000
			var dw := "çok yakın" if dist < 8 else "%d metre" % (roundi(float(dist) / 5.0) * 5)
			return s % [str(clock), dw]
		"ally_down":
			return s % str(NAMES[clampi(arg, 0, NAMES.size() - 1)])
	return s


## Where `to` is from `from` as a clock face around `fwd` (12 ahead, 3 to the right) and how far:
## clock × 1000 + metres (≤ 999).
static func pack_clock(from: Vector3, fwd: Vector3, up: Vector3, to: Vector3) -> int:
	var d := to - from
	var dist := clampi(roundi(d.length()), 0, 999)
	d -= up * d.dot(up)
	var f := fwd - up * fwd.dot(up)
	if d.length_squared() < 1e-4 or f.length_squared() < 1e-4:
		return 12000 + dist
	f = f.normalized()
	var right := f.cross(up).normalized()
	var a := atan2(d.dot(right), d.dot(f))
	var clock := posmod(roundi(a / (PI / 6.0)), 12)
	return (12 if clock == 0 else clock) * 1000 + dist


static func radio_kind(line: String) -> String:
	return str(RADIO.get(line, ""))


## True (and the gap starts) when `team` may make a callout now.
static func team_may_call(team: String, gap: float) -> bool:
	var now := Time.get_ticks_msec()
	if now - int(_team_last.get(team, -1000000)) < int(gap * 1000.0):
		return false
	_team_last[team] = now
	return true


static func _cam_dist(n: Node3D) -> float:
	var vp := n.get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	return cam.global_position.distance_to(n.global_position) if cam != null else INF


## A Label3D child of n (made once, kept under `key`): billboarded, fixed size, outlined.
static func _label(n: Node3D, key: String, h: float) -> Label3D:
	var l: Label3D = n.get_meta(key) if n.has_meta(key) else null
	if l != null and is_instance_valid(l):
		return l
	l = Label3D.new()
	l.name = key
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.shaded = false
	l.double_sided = true
	l.no_depth_test = false
	l.alpha_cut = Label3D.ALPHA_CUT_DISABLED
	l.outline_modulate = UI.OUTLINE
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	l.position = Vector3(0.0, h, 0.0)
	l.visible = false
	n.add_child(l)
	n.set_meta(key, l)
	return l


static func _tween_out(l: Label3D, hold: float, fade: float, pop: float) -> void:
	var tw0 = l.get_meta("cue_tw") if l.has_meta("cue_tw") else null
	if tw0 is Tween and (tw0 as Tween).is_valid():
		(tw0 as Tween).kill()
	l.visible = true
	l.modulate.a = 0.0
	l.scale = Vector3.ONE * pop
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "modulate:a", 1.0, 0.12)
	tw.tween_property(l, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(hold)
	tw.chain().tween_property(l, "modulate:a", 0.0, fade)
	tw.chain().tween_callback(l.hide)
	l.set_meta("cue_tw", tw)


## The "!" over a bot: "seen" (it just saw you, red) or "marked" (an ally points it out, amber).
static func alert(n: Node3D, kind: String) -> void:
	if n == null or not is_instance_valid(n) or not n.is_inside_tree() or not n.is_visible_in_tree():
		return
	if _cam_dist(n) > Balance.BL_RANGE + 10.0:
		return
	var l := _label(n, "cue_alert", ALERT_H)
	l.text = "!"
	l.font = UI.font(800)
	l.font_size = 46
	l.outline_size = 12
	l.pixel_size = 0.0011
	l.modulate = UI.CRIT if kind == "seen" else UI.WARN
	_tween_out(l, 0.75 if kind == "seen" else 1.7, 0.3, 1.8)


## The callout line over the speaker's head (only near the camera).
static func say(n: Node3D, text: String, ally := false, urgent := false) -> void:
	if text == "" or n == null or not is_instance_valid(n) or not n.is_inside_tree() or not n.is_visible_in_tree():
		return
	if _cam_dist(n) > Balance.BL_SAY_RANGE:
		return
	var l := _label(n, "cue_say", SAY_H)
	l.text = text
	l.font = UI.font(700)
	l.font_size = 22 if urgent else 19
	l.outline_size = 8
	l.pixel_size = 0.0009
	var c: Color = UI.ALLY if ally else (UI.BAD if urgent else Color(1.0, 0.72, 0.66))
	l.modulate = c
	_tween_out(l, 1.6 + 0.04 * float(text.length()), 0.45, 1.15 if urgent else 1.0)
