extends RefCounted
## Interpolation buffer for one remote entity (player, bot, skiff, structure aim): snapshots stamped
## with the SENDER's clock (msec). The receiver estimates the clock offset (the smallest recent
## local - remote difference, i.e. the fastest delivery, drifting up slowly) and renders `delay_ms`
## behind the newest data, so 1-2 lost or late packets never show.
##   push(remote_ms, payload)        payload: anything (usually a Dictionary)
##   sample() -> [a, b, t]           the two snapshots around the render time and the blend 0..1
##                                    (t > 1 up to max_extra_ms past the newest: extrapolate)
##   latest() -> payload / null

var delay_ms := 110.0
var max_extra_ms := 220.0
var keep := 24

var _snaps: Array = []          # [remote_ms, payload] oldest first
var _offset := 0.0
var _have_offset := false


func clear() -> void:
	_snaps.clear()
	_have_offset = false


func is_empty() -> bool:
	return _snaps.is_empty()


func push(remote_ms: int, payload) -> void:
	var now := float(Time.get_ticks_msec())
	var off := now - float(remote_ms)
	if not _have_offset or absf(off - _offset) > 5000.0:
		_offset = off
		_have_offset = true
	elif off < _offset:
		_offset = off
	else:
		_offset += (off - _offset) * 0.004
	if not _snaps.is_empty() and remote_ms <= int(_snaps[-1][0]):
		if remote_ms < int(_snaps[-1][0]) - 2000:
			_snaps.clear()            # the sender restarted its clock: start over
		else:
			return
	_snaps.append([remote_ms, payload])
	while _snaps.size() > keep:
		_snaps.pop_front()


func latest():
	return null if _snaps.is_empty() else _snaps[-1][1]


## Render time in the sender's clock.
func render_ms() -> float:
	return float(Time.get_ticks_msec()) - _offset - delay_ms


func sample() -> Array:
	if _snaps.is_empty():
		return []
	if _snaps.size() == 1:
		return [_snaps[0][1], _snaps[0][1], 0.0]
	var rt := render_ms()
	if rt <= float(_snaps[0][0]):
		return [_snaps[0][1], _snaps[0][1], 0.0]
	for i in range(_snaps.size() - 1, 0, -1):
		var a: Array = _snaps[i - 1]
		var b: Array = _snaps[i]
		if rt >= float(a[0]):
			var span := maxf(float(b[0]) - float(a[0]), 1.0)
			var t := (rt - float(a[0])) / span
			if i < _snaps.size() - 1:
				t = minf(t, 1.0)
			else:
				t = minf(t, 1.0 + max_extra_ms / span)
			return [a[1], b[1], t]
	return [_snaps[0][1], _snaps[0][1], 0.0]
