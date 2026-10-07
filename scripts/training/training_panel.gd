extends CanvasLayer
## The Eğitim Alanı's screen (scripts/training/training.gd): a stats box top left, always shown,
## and the panel (H) under it. Registered in Game.ui_panels while open (the mouse is free, the
## player stands still); H or Esc closes it. J (panel closed) puts a dummy at the crosshair.
##   Stats: last hit (damage, range, target, "öldü"), DPS over the last second, the current burst
##          (damage · length · rate), hits / kills, last time to kill, total, last fling speed,
##          last core damage; a footer with the toggles and the dummy count.
##   Panel: HEDEF KOY (kind: Standart / Zırhlı / Ölümsüz; movement: Sabit / Yan adım / Daire / Koşu
##          / Zıplama; at the crosshair or 7 m in front), HAZIR DÜZENLER (range, crowd, far group
##          on the rival planet), HEDEFLER (revive, apply the choice to all, remove last / all),
##          AYARLAR (unlimited material + ammo + grenades, god mode, damage numbers, reset stats),
##          ALAN (reset the ground, start the real rival team, main menu).

const UI := preload("res://scripts/ui/ui_style.gd")
const Dummy := preload("res://scripts/training/training_dummy.gd")

const STATS_W := 340.0
const PANEL_W := 420.0

var trainer                              # training.gd
var _root: Control
var _stats: PanelContainer
var _vals := {}                          # stat key -> Label
var _foot: Label
var _panel: PanelContainer
var _open := false
var _kind_btns: Array = []
var _move_btns: Array = []
var _chk_inf: CheckButton
var _chk_god: CheckButton
var _chk_num: CheckButton
var _ai_btn: Button
var _upd := 0.0


func _ready() -> void:
	layer = 8
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UI.make_theme()
	add_child(_root)
	_build_stats()
	_build_panel()
	_panel.visible = false


func _exit_tree() -> void:
	Game.ui_panels.erase(self)


func is_open() -> bool:
	return _open and is_inside_tree()


func open() -> void:
	if _open:
		return
	_open = true
	_panel.visible = true
	_sync_controls()
	if not Game.ui_panels.has(self):
		Game.ui_panels.append(self)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	if not _open:
		return
	_open = false
	_panel.visible = false
	Game.ui_panels.erase(self)
	if not Game.ui_panel_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.is_echo():
		return
	if event.is_action_pressed("training_panel"):
		if _open:
			close()
		elif not Game.ui_panel_open():
			open()
		get_viewport().set_input_as_handled()
	elif _open and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("training_place") and not _open and not Game.ui_panel_open() \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		trainer.place_at_crosshair()
		get_viewport().set_input_as_handled()


# =================================================================================================
# Stats box
# =================================================================================================

func _build_stats() -> void:
	_stats = UI.panel(_root, UI.panel_box(12.0))
	_stats.position = Vector2(24, 24)
	_stats.custom_minimum_size = Vector2(STATS_W, 0)
	var col := UI.vbox(_stats, 4)
	var head := UI.hbox(col, 6)
	var t := UI.label(head, "EĞİTİM ALANI", 13, UI.CYAN, 700)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.keycap(head, "H", 11)
	UI.label(head, "panel", 11, UI.FAINT)
	UI.keycap(head, "J", 11)
	UI.label(head, "hedef koy", 11, UI.FAINT)
	UI.rule(col)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(grid)
	for row in [["last", "Son vuruş"], ["dps", "DPS (1 sn)"], ["burst", "Seri"], ["hits", "İsabet / öldürme"],
			["ttk", "Son öldürme süresi"], ["total", "Toplam hasar"], ["fling", "Son savurma"], ["core", "Çekirdek"]]:
		UI.label(grid, str(row[1]), 13, UI.DIM)
		var v := UI.label(grid, "—", 13, UI.TEXT, 600)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_vals[row[0]] = v
	UI.rule(col)
	_foot = UI.label(col, "", 11, UI.FAINT)


func _process(delta: float) -> void:
	_upd -= delta
	if _upd > 0.0 or trainer == null or not is_instance_valid(trainer):
		return
	_upd = 0.1
	var s: Dictionary = trainer.stats
	if int(s["hits"]) > 0:
		var last := "%s  ·  %s m  ·  %s" % [_num(float(s["last"]), 1), _num(float(s["last_d"]), 1), str(s["last_name"])]
		_put(_vals["last"], last + ("  ·  ÖLDÜ" if bool(s["last_kill"]) else ""), UI.BAD if bool(s["last_kill"]) else UI.TEXT)
		var b: Array = trainer.burst()
		if int(b[2]) >= 2 and float(b[1]) > 0.05:
			_put(_vals["burst"], "%s hasar  ·  %s s  ·  %s/s" % [_num(float(b[0]), 0), _num(float(b[1]), 2),
					_num(float(b[0]) / float(b[1]), 0)])
		else:
			_put(_vals["burst"], "%s hasar" % _num(float(b[0]), 0))
		_put(_vals["hits"], "%d  /  %d" % [int(s["hits"]), int(s["kills"])])
		_put(_vals["total"], _num(float(s["total"]), 0))
	else:
		for k in ["last", "burst", "hits", "total"]:
			_put(_vals[k], "—", UI.FAINT)
	var dps: float = trainer.dps()
	_put(_vals["dps"], _num(dps, 0) if dps > 0.0 else "—", UI.ACCENT if dps > 0.0 else UI.FAINT)
	_put(_vals["ttk"], ("%s s" % _num(float(s["ttk"]), 2)) if float(s["ttk"]) >= 0.0 else "—")
	_put(_vals["fling"], ("%s m/s" % _num(float(s["fling"]), 1)) if float(s["fling"]) > 0.0 else "—")
	_put(_vals["core"], ("−%s  (%s)" % [_num(float(s["core"]), 1), str(s["core_name"])]) if float(s["core"]) > 0.0 else "—")
	var flags: Array = []
	if trainer.infinite_on():
		flags.append("sınırsız malzeme")
	if trainer.god_on():
		flags.append("ölümsüz")
	flags.append("%d hedef" % trainer.dummy_count())
	_foot.text = "  ·  ".join(flags)


func _put(l: Label, text: String, col := UI.TEXT) -> void:
	l.text = text
	l.add_theme_color_override("font_color", col)


## A number with a Turkish decimal comma.
static func _num(v: float, decimals: int) -> String:
	return String.num(v, decimals).replace(".", ",")


# =================================================================================================
# Panel
# =================================================================================================

func _build_panel() -> void:
	_panel = UI.panel(_root, UI.panel_box(14.0))
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_panel.offset_left = 24
	_panel.offset_right = 24 + PANEL_W
	_panel.offset_top = 300
	_panel.offset_bottom = -80
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(sc)
	var col := UI.vbox(sc, 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var head := UI.hbox(col, 6)
	var t := UI.label(head, "EĞİTİM PANELİ", 15, UI.TEXT, 700)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.keycap(head, "H", 11)
	UI.keycap(head, "Esc", 11)
	UI.label(head, "kapat", 11, UI.FAINT)

	UI.section_title(col, "HEDEF KOY")
	UI.label(col, "Tür", 12, UI.DIM)
	var kinds := _flow(col)
	var kg := ButtonGroup.new()
	var kind_sub := ["%d can" % int(Dummy.KIND_HP_STD), "%d can" % int(Dummy.KIND_HP_STD * Dummy.ARMOR_K), "DPS ölçer"]
	for i in Dummy.KIND_NAMES.size():
		var b := _toggle(kinds, "%s · %s" % [Dummy.KIND_NAMES[i], kind_sub[i]], kg)
		b.toggled.connect(func(on: bool) -> void:
			if on:
				trainer.set_place_choice(i, int(trainer.place_choice()[1])))
		_kind_btns.append(b)
	UI.label(col, "Hareket", 12, UI.DIM)
	var moves := _flow(col)
	var mg := ButtonGroup.new()
	for i in Dummy.MOVE_NAMES.size():
		var b := _toggle(moves, str(Dummy.MOVE_NAMES[i]), mg)
		b.toggled.connect(func(on: bool) -> void:
			if on:
				trainer.set_place_choice(int(trainer.place_choice()[0]), i))
		_move_btns.append(b)
	var pr := _flow(col)
	_btn(pr, "Nişangaha koy  [J]", func() -> void:
		close()
		trainer.place_at_crosshair())
	_btn(pr, "Önüme koy (7 m)", func() -> void: trainer.place_in_front(7.0))

	UI.section_title(col, "HAZIR DÜZENLER")
	var lr := _flow(col)
	_btn(lr, "Atış poligonu", func() -> void: trainer.layout_range())
	_btn(lr, "Kalabalık (patlayıcılar)", func() -> void: trainer.layout_crowd())
	_btn(lr, "Uzak hedefler (rakip gezegen)", func() -> void: trainer.layout_far())

	UI.section_title(col, "HEDEFLER")
	var tr := _flow(col)
	_btn(tr, "Hepsini dirilt", func() -> void: trainer.revive_all())
	_btn(tr, "Seçimi hepsine uygula", func() -> void:
		var c: Array = trainer.place_choice()
		trainer.apply_to_all(int(c[0]), int(c[1])))
	_btn(tr, "Sonuncuyu kaldır", func() -> void: trainer.remove_last())
	_red(_btn(tr, "Hepsini kaldır", func() -> void: trainer.clear_dummies()))

	UI.section_title(col, "AYARLAR")
	_chk_inf = _check(col, "Sınırsız malzeme, mermi ve bomba", func(on: bool) -> void: trainer.set_infinite(on))
	_chk_god = _check(col, "Ölümsüzlük (kendi patlamaların dahil)", func(on: bool) -> void: trainer.set_god_on(on))
	_chk_num = _check(col, "Hasar sayıları", func(on: bool) -> void: trainer.set_numbers(on))
	var sr := _flow(col)
	_btn(sr, "İstatistikleri sıfırla", func() -> void: trainer.reset_stats())

	UI.section_title(col, "ALAN")
	var ar := _flow(col)
	_btn(ar, "Alanı sıfırla (zemin yenilenir)", func() -> void: trainer.reset_field())
	_ai_btn = _btn(ar, "Rakip takımını başlat", func() -> void:
		trainer.start_rival_team()
		_ai_btn.disabled = true)
	_red(_btn(ar, "Ana menü", func() -> void: trainer.to_menu()))
	var note := UI.label(col, "Rakip takımı: gerçek botlar rakip gezegende kazar, top kurar ve bu gezegeni bombalar. Çekirdekler eğitimde yok edilemez.", 11, UI.FAINT)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = PANEL_W - 40.0


## The toggles and choices as they are now (static on the trainer: kept through a reset).
func _sync_controls() -> void:
	var c: Array = trainer.place_choice()
	for i in _kind_btns.size():
		(_kind_btns[i] as Button).set_pressed_no_signal(i == int(c[0]))
	for i in _move_btns.size():
		(_move_btns[i] as Button).set_pressed_no_signal(i == int(c[1]))
	_chk_inf.set_pressed_no_signal(trainer.infinite_on())
	_chk_god.set_pressed_no_signal(trainer.god_on())
	_chk_num.set_pressed_no_signal(trainer.numbers_on())
	_ai_btn.disabled = bool(trainer.ai_started)


func _flow(parent: Node) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 6)
	f.add_theme_constant_override("v_separation", 6)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.custom_minimum_size.x = PANEL_W - 40.0
	parent.add_child(f)
	return f


func _btn(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 32)
	b.add_theme_font_size_override("font_size", 13)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _red(b: Button) -> void:
	b.add_theme_color_override("font_color", UI.BAD)
	b.add_theme_color_override("font_hover_color", UI.BAD.lightened(0.2))


func _toggle(parent: Node, text: String, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 30)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_pressed_color", UI.ACCENT)
	parent.add_child(b)
	return b


func _check(parent: Node, text: String, cb: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.focus_mode = Control.FOCUS_NONE
	c.add_theme_font_size_override("font_size", 13)
	c.toggled.connect(cb)
	parent.add_child(c)
	return c
