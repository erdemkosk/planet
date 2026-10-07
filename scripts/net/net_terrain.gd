extends Node
## Terrain sync (child "Terrain" of the Net autoload). planet.gd hands every edit to on_brush() /
## on_crater() (static Planet.net_hook, set only in multiplayer) BEFORE applying it.
##
## Ops: {kind (0 brush / 1 crater), body (0 Yurt / 1 Rakip), mode, centre (body-local), radius,
## amount (or crater depth), plane point (body-local) + normal for FLATTEN}, all rounded to float32
## and applied in that rounded form on EVERY peer (the origin too), so the voxel math is identical.
## 23 bytes per op (47 for a flatten), batched at 15 Hz.
##   Host: every local edit (its drill, the bots' digs, shell craters, explosions) gets the next
##     global seq and goes to the client in order; the client's ops are applied as they arrive (the
##     host's order is the truth).
##   Client: its own drill ops apply at once (prediction) and go to the host; craters only ever
##     come from the host (local crater() calls are dropped). Host ops apply in seq order.
## Drift check (host, every 2 s): hashes of the 16³ edit regions touched in the last 8 s, tagged with
## the seq and the number of client ops already applied. The client compares once it has no own
## ops in flight and no crater still carving; mismatching regions are re-sent by the host
## (zstd-compressed float32 grids) and replace the client's.
## Snapshot (late join, rejoin, restart): the host waits for its craters to finish, captures every
## edit region of both planets (int32 keys + zstd float32 grid), streams it in 12 KB parts (2 per
## frame), and only then the world snapshot; ops after the capture seq are buffered on the client
## and applied after loading.

const Planet := preload("res://scripts/planet/planet.gd")

const BATCH_PERIOD := 1.0 / 15.0
const CHECK_PERIOD := 2.0
const TOUCH_KEEP_MS := 8000
const CHECK_MAX := 400
const RESYNC_MAX := 24
const CHUNK := 12000
const SNAP_PARTS_PER_FRAME := 2
const SNAP_WAIT_MAX := 4.0
const MAX_BATCH_BYTES := 12000
const FLATTEN := 2

var seq := 0                       # host: last global seq given out; client: last host seq applied
var stat_ops_out := 0
var stat_bytes_out := 0
var stat_resyncs := 0

var _out := PackedByteArray()
var _out_first := 0
var _out_n := 0
var _send_t := 0.0
var _applying := false
var _dig_script = null             # scripts/player/dig.gd (net_team)
var _log_script = null             # scripts/war/tunnel_log.gd
var _local_id := 0                 # client: own ops recorded
var _peer_applied := 0             # host: client ops applied
var _touched := {}                 # Vector4i(body, kx, ky, kz) -> msec (host)
var _check_t := 0.0
var _streaming := false            # host: ops go to the client
var _buffer: Array = []            # client: [first, n, bytes] received before the snapshot
# Snapshot (host side).
var _snap_peer := 0
var _snap_wait := -1.0
var _snap_queue: Array = []        # [body, index, bytes]
# Snapshot (client side).
var _snap_seq := -1
var _snap_meta := {}               # body -> {"n", "raw", "klen", "parts"}
var _snap_parts := {}              # body -> Array of PackedByteArray
var _snap_done := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## The game scene is up: install the planet hook.
func begin() -> void:
	reset()
	Planet.net_hook = self


func reset() -> void:
	Planet.net_hook = null if not (Net.active and Net.in_game) else self
	seq = 0
	_out = PackedByteArray()
	_out_n = 0
	_out_first = 0
	_local_id = 0
	_peer_applied = 0
	_touched.clear()
	_streaming = false
	_buffer.clear()
	_snap_peer = 0
	_snap_wait = -1.0
	_snap_queue.clear()
	_snap_seq = -1
	_snap_meta.clear()
	_snap_parts.clear()
	_snap_done = false
	_applying = false


func on_peer_gone() -> void:
	_streaming = false
	_snap_queue.clear()
	_snap_wait = -1.0
	_peer_applied = 0


# =================================================================================================
# Hooks (planet.gd)
# =================================================================================================

static func _q(x: float) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, x)
	return b.decode_float(0)


static func _q3(v: Vector3) -> Vector3:
	return Vector3(_q(v.x), _q(v.y), _q(v.z))


## planet.apply_brush: returns the (rounded) arguments to apply, or [] to drop the edit.
func on_brush(planet: Node3D, center: Vector3, radius: float, mode: int, amount: float,
		plane_point: Vector3, plane_normal: Vector3) -> Array:
	if _applying or not Net.active or not Net.in_game:
		return [center, radius, amount, plane_point, plane_normal]
	var bpos: Vector3 = planet.global_position
	var lc := _q3(center - bpos)
	var lpp := _q3(plane_point - bpos)
	var pn := _q3(plane_normal)
	var r := _q(radius)
	var a := _q(amount)
	# The digger's side rides in the high bits of the mode byte (the Tünel tarayıcı log).
	var tc := 0
	if _dig_script == null:
		_dig_script = load("res://scripts/player/dig.gd")
	var tm := str(_dig_script.get("net_team")) if _dig_script != null else ""
	if tm != "" and tm != "<null>":
		tc = 1 + Net.abs_side(tm)
	_record(0, Net.body_index(planet), mode | (tc << 4), lc, r, a, lpp, pn)
	return [bpos + lc, r, a, bpos + lpp, pn]


## planet.crater: returns [center, radius, depth] to carve, or [] (clients: craters come from the host).
func on_crater(planet: Node3D, center: Vector3, radius: float, depth: float) -> Array:
	if _applying or not Net.active or not Net.in_game:
		return [center, radius, depth]
	if not Net.is_server:
		return []
	var bpos: Vector3 = planet.global_position
	var lc := _q3(center - bpos)
	var r := _q(radius)
	var d := _q(depth)
	_record(1, Net.body_index(planet), 0, lc, r, d, Vector3.ZERO, Vector3.UP)
	return [bpos + lc, r, d]


func _record(kind: int, bi: int, mode: int, lc: Vector3, r: float, a: float, lpp: Vector3, pn: Vector3) -> void:
	if Net.is_server:
		seq += 1
		_touch(bi, lc, r)
		if not _streaming:
			return
		if _out_n == 0:
			_out_first = seq
	else:
		_local_id += 1
		if _out_n == 0:
			_out_first = _local_id
	_encode(_out, kind, bi, mode, lc, r, a, lpp, pn)
	_out_n += 1
	if _out.size() > MAX_BATCH_BYTES:
		flush()


static func _encode(buf: PackedByteArray, kind: int, bi: int, mode: int, lc: Vector3, r: float, a: float,
		lpp: Vector3, pn: Vector3) -> void:
	var flat := kind == 0 and (mode & 15) == FLATTEN
	var o := buf.size()
	buf.resize(o + (47 if flat else 23))
	buf.encode_u8(o, kind)
	buf.encode_u8(o + 1, bi)
	buf.encode_u8(o + 2, mode)
	buf.encode_float(o + 3, lc.x)
	buf.encode_float(o + 7, lc.y)
	buf.encode_float(o + 11, lc.z)
	buf.encode_float(o + 15, r)
	buf.encode_float(o + 19, a)
	if flat:
		buf.encode_float(o + 23, lpp.x)
		buf.encode_float(o + 27, lpp.y)
		buf.encode_float(o + 31, lpp.z)
		buf.encode_float(o + 35, pn.x)
		buf.encode_float(o + 39, pn.y)
		buf.encode_float(o + 43, pn.z)


static func _op_len(buf: PackedByteArray, o: int) -> int:
	return 47 if (buf[o] == 0 and (buf[o + 2] & 15) == FLATTEN) else 23


## Applies one encoded op at offset o (no hook recording). Returns the op length.
func _apply_op(buf: PackedByteArray, o: int) -> int:
	var n := _op_len(buf, o)
	if o + n > buf.size():
		return buf.size() - o
	var kind := buf[o]
	var bi := buf[o + 1]
	var mode := buf[o + 2] & 15
	var tcode := buf[o + 2] >> 4
	var lc := Vector3(buf.decode_float(o + 3), buf.decode_float(o + 7), buf.decode_float(o + 11))
	var r := buf.decode_float(o + 15)
	var a := buf.decode_float(o + 19)
	var planet := Net.body_by_index(bi)
	if planet == null or not is_finite(r) or not is_finite(a) or r <= 0.0 or r > 40.0:
		return n
	var bpos: Vector3 = planet.global_position
	_applying = true
	if kind == 1:
		planet.crater(bpos + lc, r, a)
	else:
		var pp := bpos
		var pn := Vector3.UP
		if mode == FLATTEN:
			pp = bpos + Vector3(buf.decode_float(o + 23), buf.decode_float(o + 27), buf.decode_float(o + 31))
			pn = Vector3(buf.decode_float(o + 35), buf.decode_float(o + 39), buf.decode_float(o + 43))
		planet.apply_brush(bpos + lc, r, clampi(mode, 0, 2), a, pp, pn)
		if mode == 0 and tcode > 0:
			if _log_script == null:
				_log_script = load("res://scripts/war/tunnel_log.gd")
			if _log_script != null:
				_log_script.call("record", planet, bpos + lc, r, Net.local_team(tcode - 1))
	_applying = false
	if Net.is_server:
		_touch(bi, lc, r)
	return n


func _touch(bi: int, lc: Vector3, r: float) -> void:
	var now := Time.get_ticks_msec()
	var lo := Vector3i((lc - Vector3.ONE * (r + 2.0)).floor())
	var hi := Vector3i((lc + Vector3.ONE * (r + 2.0)).ceil())
	for z in range(lo.z >> 4, (hi.z >> 4) + 1):
		for y in range(lo.y >> 4, (hi.y >> 4) + 1):
			for x in range(lo.x >> 4, (hi.x >> 4) + 1):
				_touched[Vector4i(bi, x, y, z)] = now


# =================================================================================================
# Batching
# =================================================================================================

func _process(delta: float) -> void:
	if not Net.active or not Net.in_game:
		return
	_send_t += delta
	if _send_t >= BATCH_PERIOD:
		_send_t = 0.0
		flush()
	if Net.is_server:
		_tick_snapshot(delta)
		_check_t += delta
		if _check_t >= CHECK_PERIOD:
			_check_t = 0.0
			_send_check()


func flush() -> void:
	if _out_n == 0:
		return
	var data := _out
	var first := _out_first
	var n := _out_n
	_out = PackedByteArray()
	_out_n = 0
	if Net.is_server:
		if _streaming and Net.other_id != 0:
			_rx_ops.rpc_id(Net.other_id, first, n, data)
			stat_ops_out += n
			stat_bytes_out += data.size() + 12
	elif Net.live():
		_rx_client_ops.rpc_id(1, first, n, data)
		stat_ops_out += n
		stat_bytes_out += data.size() + 12


## Client: host ops in seq order.
@rpc("authority", "call_remote", "reliable")
func _rx_ops(first: int, n: int, data: PackedByteArray) -> void:
	if Net.is_server or not Net.in_game:
		return
	if not Net.world_ready:
		_buffer.append([first, n, data])
		return
	_apply_batch(first, n, data)


func _apply_batch(first: int, n: int, data: PackedByteArray) -> void:
	var o := 0
	for i in n:
		if o >= data.size():
			break
		var s := first + i
		if s > seq:
			o += _apply_op(data, o)
			seq = s
		else:
			o += _op_len(data, o)


## Host: the client's own drill ops (already applied on its side).
@rpc("any_peer", "call_remote", "reliable")
func _rx_client_ops(first: int, n: int, data: PackedByteArray) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id or not Net.peer_ready:
		return
	var o := 0
	for i in n:
		if o >= data.size():
			break
		if data[o] != 0:
			o += _op_len(data, o)
			continue
		o += _apply_op(data, o)
	_peer_applied = first + n - 1


# =================================================================================================
# Drift check
# =================================================================================================

func _craters_busy() -> bool:
	for i in 2:
		var p := Net.body_by_index(i)
		if p != null and not (p.get("_craters") as Array).is_empty():
			return true
	return false


static func region_hash(planet: Node, k: Vector3i) -> int:
	var arr = (planet.get("edits") as Dictionary).get(k)
	if arr == null:
		return 0
	return hash(arr) & 0xFFFFFFFF


func _send_check() -> void:
	if not Net.live() or not _streaming or _craters_busy():
		return
	flush()
	var now := Time.get_ticks_msec()
	var buf := PackedByteArray()
	buf.resize(10)
	buf.encode_u32(0, seq)
	buf.encode_u32(4, _peer_applied)
	var n := 0
	for key: Vector4i in _touched.keys():
		if now - int(_touched[key]) > TOUCH_KEEP_MS:
			_touched.erase(key)
			continue
		if n >= CHECK_MAX:
			continue
		var planet := Net.body_by_index(key.x)
		if planet == null:
			continue
		var o := buf.size()
		buf.resize(o + 11)
		buf.encode_u8(o, key.x)
		buf.encode_s16(o + 1, key.y)
		buf.encode_s16(o + 3, key.z)
		buf.encode_s16(o + 5, key.w)
		buf.encode_u32(o + 7, region_hash(planet, Vector3i(key.y, key.z, key.w)))
		n += 1
	if n == 0:
		return
	buf.encode_u16(8, n)
	_rx_check.rpc_id(Net.other_id, buf)


@rpc("authority", "call_remote", "reliable")
func _rx_check(buf: PackedByteArray) -> void:
	if Net.is_server or not Net.world_ready or buf.size() < 10:
		return
	if int(buf.decode_u32(0)) != seq or int(buf.decode_u32(4)) != _local_id or _out_n > 0:
		return            # own ops in flight (or not caught up): next round
	if _craters_busy():
		return
	var n := buf.decode_u16(8)
	var bad := PackedByteArray()
	var nb := 0
	for i in n:
		var o := 10 + i * 11
		if o + 11 > buf.size():
			break
		var bi := buf.decode_u8(o)
		var planet := Net.body_by_index(bi)
		if planet == null:
			continue
		var k := Vector3i(buf.decode_s16(o + 1), buf.decode_s16(o + 3), buf.decode_s16(o + 5))
		if region_hash(planet, k) != int(buf.decode_u32(o + 7)) and nb < RESYNC_MAX:
			var p := bad.size()
			bad.resize(p + 7)
			bad.encode_u8(p, bi)
			bad.encode_s16(p + 1, k.x)
			bad.encode_s16(p + 3, k.y)
			bad.encode_s16(p + 5, k.z)
			nb += 1
	if nb > 0:
		stat_resyncs += nb
		_rx_resync_req.rpc_id(1, bad)


@rpc("any_peer", "call_remote", "reliable")
func _rx_resync_req(list: PackedByteArray) -> void:
	if not Net.is_host() or multiplayer.get_remote_sender_id() != Net.other_id:
		return
	flush()
	var n := mini(list.size() / 7, RESYNC_MAX)
	for i in n:
		var o := i * 7
		var bi := list.decode_u8(o)
		var planet := Net.body_by_index(bi)
		if planet == null:
			continue
		var k := Vector3i(list.decode_s16(o + 1), list.decode_s16(o + 3), list.decode_s16(o + 5))
		var arr = (planet.get("edits") as Dictionary).get(k)
		var raw := PackedByteArray()
		var comp := PackedByteArray()
		if arr != null:
			raw = (arr as PackedFloat32Array).to_byte_array()
			comp = raw.compress(FileAccess.COMPRESSION_ZSTD)
		_rx_region.rpc_id(Net.other_id, bi, k, raw.size(), comp)


@rpc("authority", "call_remote", "reliable")
func _rx_region(bi: int, k: Vector3i, raw_size: int, comp: PackedByteArray) -> void:
	if Net.is_server or not Net.world_ready:
		return
	var planet := Net.body_by_index(bi)
	if planet == null:
		return
	var arr = null
	if raw_size == 4096 * 4 and not comp.is_empty():
		var raw := comp.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
		if raw.size() == raw_size:
			arr = raw.to_float32_array()
	planet.net_set_region(k, arr)


# =================================================================================================
# Snapshot
# =================================================================================================

## Host: stream both planets' edits to `peer` (waits for craters still carving).
func send_snapshot(peer: int) -> void:
	_snap_peer = peer
	_snap_queue.clear()
	_streaming = false
	_out = PackedByteArray()
	_out_n = 0
	_snap_wait = 0.0


func _tick_snapshot(delta: float) -> void:
	if _snap_wait >= 0.0:
		_snap_wait += delta
		if _craters_busy() and _snap_wait < SNAP_WAIT_MAX:
			return
		_snap_wait = -1.0
		_capture()
		return
	if _snap_queue.is_empty() or _snap_peer == 0:
		return
	if _snap_peer != Net.other_id:
		_snap_queue.clear()
		return
	for i in SNAP_PARTS_PER_FRAME:
		if _snap_queue.is_empty():
			break
		var part: Array = _snap_queue.pop_front()
		if int(part[0]) < 0:
			_rx_snap_end.rpc_id(_snap_peer)
			Net.terrain_snapshot_sent(_snap_peer)
			_snap_queue.clear()
			return
		_rx_snap_part.rpc_id(_snap_peer, int(part[0]), int(part[1]), part[2])


func _capture() -> void:
	if _snap_peer == 0 or _snap_peer != Net.other_id:
		return
	flush()
	_streaming = true
	var meta := {}
	for bi in 2:
		var planet := Net.body_by_index(bi)
		if planet == null:
			continue
		var keys := PackedInt32Array()
		var raw := PackedByteArray()
		var edits: Dictionary = planet.get("edits")
		for k: Vector3i in edits:
			var arr: PackedFloat32Array = edits[k]
			if arr.size() != 4096:
				continue
			keys.append(k.x)
			keys.append(k.y)
			keys.append(k.z)
			raw.append_array(arr.to_byte_array())
		var kb := keys.to_byte_array()
		var blob := kb.duplicate()
		if not raw.is_empty():
			blob.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
		var parts := int(ceil(float(blob.size()) / float(CHUNK)))
		meta[bi] = {"n": keys.size() / 3, "raw": raw.size(), "klen": kb.size(), "parts": parts}
		for p in parts:
			_snap_queue.append([bi, p, blob.slice(p * CHUNK, mini((p + 1) * CHUNK, blob.size()))])
	_snap_queue.append([-1, 0, PackedByteArray()])
	_rx_snap_begin.rpc_id(_snap_peer, seq, meta)


@rpc("authority", "call_remote", "reliable")
func _rx_snap_begin(s: int, meta: Dictionary) -> void:
	if Net.is_server:
		return
	_snap_seq = s
	_snap_meta = meta
	_snap_parts.clear()
	_snap_done = false
	for bi in meta:
		var a: Array = []
		a.resize(int((meta[bi] as Dictionary).get("parts", 0)))
		_snap_parts[int(bi)] = a


@rpc("authority", "call_remote", "reliable")
func _rx_snap_part(bi: int, idx: int, data: PackedByteArray) -> void:
	if Net.is_server or not _snap_parts.has(bi):
		return
	var a: Array = _snap_parts[bi]
	if idx >= 0 and idx < a.size():
		a[idx] = data
	# Progress on the loading cover.
	var got := 0
	var total := 0
	for k in _snap_parts:
		for part in (_snap_parts[k] as Array):
			total += 1
			if part != null:
				got += 1
	if total > 4:
		Net.overlay.loading(true, "Dünya eşitleniyor… %d%%" % int(100.0 * float(got) / float(total)))


@rpc("authority", "call_remote", "reliable")
func _rx_snap_end() -> void:
	if Net.is_server:
		return
	_snap_done = true


## Client (Net._rx_world): load the received terrain, then the ops buffered meanwhile.
func finish_snapshot() -> void:
	if not _snap_done or _snap_seq < 0:
		return
	for bi in _snap_meta:
		var m: Dictionary = _snap_meta[bi]
		var planet := Net.body_by_index(int(bi))
		if planet == null:
			continue
		var blob := PackedByteArray()
		for part in (_snap_parts.get(int(bi), []) as Array):
			if part is PackedByteArray:
				blob.append_array(part)
		var n := int(m.get("n", 0))
		var klen := int(m.get("klen", 0))
		var raw_size := int(m.get("raw", 0))
		var d := {"regions": 0}
		if n > 0 and blob.size() >= klen:
			var raw := blob.slice(klen).decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
			if raw.size() == raw_size:
				d = {"regions": n, "keys": Marshalls.raw_to_base64(blob.slice(0, klen)),
						"edits": Marshalls.raw_to_base64(raw)}
			else:
				push_warning("[mp] arazi anlık görüntüsü açılamadı (gövde %d)" % int(bi))
		planet.load_state(d)
	seq = _snap_seq
	_snap_parts.clear()
	_snap_done = false
	var buffered := _buffer
	_buffer = []
	for b in buffered:
		_apply_batch(int(b[0]), int(b[1]), b[2])
