extends RefCounted
## One GPU density thread (with its own local RenderingDevice) shared by every planet / moon.
## Planets register their body config, submit chunk requests and collect finished density grids.
## Each body is validated once against the CPU generator; on mismatch (or without GPU compute) its
## requests come back with null density and the planet falls back to CPU jobs.

const GpuDensity := preload("res://scripts/planet/gpu_density.gd")
const TerrainGen := preload("res://scripts/planet/terrain_gen.gd")
const SAMPLES := GpuDensity.SAMPLES

static var _instance = null

var state := 0                 # 0 starting, 1 running, -1 unavailable
var _thread: Thread
var _sem := Semaphore.new()
var _mutex := Mutex.new()
var _requests: Array = []      # [owner_id, body_index, request]
var _done := {}                # owner_id -> Array of [request, density or null, sign flags, min |d|]
var _params := PackedFloat32Array()
var _cfgs: Array = []
var _body_ok := PackedByteArray()   # 0 untested, 1 ok, 2 failed
var _dirty := false
var _quit := false
var _users := 0


## The shared service, or null when GPU compute cannot be used (headless / no RenderingDevice).
static func acquire():
	if DisplayServer.get_name() == "headless" or RenderingServer.get_rendering_device() == null:
		return null
	if _instance == null:
		_instance = load("res://scripts/planet/gpu_service.gd").new()
		_instance._start()
	_instance._users += 1
	return _instance


func release(owner_id: int) -> void:
	_mutex.lock()
	_done.erase(owner_id)
	var keep: Array = []
	for r in _requests:
		if r[0] != owner_id:
			keep.append(r)
	_requests = keep
	_mutex.unlock()
	_users -= 1
	if _users <= 0:
		_mutex.lock()
		_quit = true
		_mutex.unlock()
		_sem.post()
		_thread.wait_to_finish()
		if _instance == self:
			_instance = null


## Returns the body index for GPU requests, or -1 when the table is full.
func register_body(cfg: Dictionary) -> int:
	_mutex.lock()
	var idx := _cfgs.size()
	if idx >= GpuDensity.MAX_BODIES:
		_mutex.unlock()
		return -1
	_cfgs.append(cfg)
	_params.append_array(GpuDensity.body_params(cfg))
	_body_ok.append(0)
	_dirty = true
	_mutex.unlock()
	_sem.post()
	return idx


func submit(owner_id: int, body: int, request: Array) -> void:
	_mutex.lock()
	_requests.append([owner_id, body, request])
	_mutex.unlock()


func flush() -> void:
	_sem.post()


func take_done(owner_id: int) -> Array:
	_mutex.lock()
	var out: Array = _done.get(owner_id, [])
	_done.erase(owner_id)
	_mutex.unlock()
	return out


func _start() -> void:
	_thread = Thread.new()
	_thread.start(_loop, Thread.PRIORITY_HIGH)


func _loop() -> void:
	var g := GpuDensity.new()
	var ok := g.init()
	if ok:
		print("Planet: GPU density sampling active")
	else:
		push_warning("Planet: GPU density unavailable (%s), using CPU threads" % g.error)
	_mutex.lock()
	state = 1 if ok else -1
	_mutex.unlock()
	while true:
		_sem.wait()
		while true:
			_mutex.lock()
			if _quit:
				_mutex.unlock()
				if ok:
					g.free_resources()
				return
			var params := PackedFloat32Array()
			var untested: Array = []
			if _dirty:
				_dirty = false
				params = _params.duplicate()
				for i in _body_ok.size():
					if _body_ok[i] == 0:
						untested.append([i, _cfgs[i]])
			var batch := _requests.slice(0, GpuDensity.BATCH)
			_requests = _requests.slice(GpuDensity.BATCH)
			_mutex.unlock()
			if ok and not params.is_empty():
				g.set_bodies(params)
				for e in untested:
					var cfg: Dictionary = e[1]
					var worst := g.self_test(e[0], TerrainGen.new(int(cfg.get("seed", 1337)), cfg))
					_mutex.lock()
					_body_ok[e[0]] = 1 if worst < 0.05 else 2
					_mutex.unlock()
					if worst >= 0.05:
						push_warning("Planet: GPU density mismatch for body %d (%.4f), using CPU" % [e[0], worst])
			if batch.is_empty() and params.is_empty():
				break
			if batch.is_empty():
				continue
			var out := {}
			var gpu_items: Array = []
			var chunks: Array = []
			for item in batch:
				var body: int = item[1]
				var usable: bool = ok and body >= 0 and body < _body_ok.size() and _body_ok[body] == 1
				if usable:
					var o4: Vector4i = item[2][3]
					chunks.append(Vector4i(o4.x, o4.y, o4.z, o4.w | (body << 8)))
					gpu_items.append(item)
				else:
					if not out.has(item[0]):
						out[item[0]] = []
					out[item[0]].append([item[2], null, 0, 0.0])
			if not chunks.is_empty():
				var res := g.compute(chunks)
				var dens: PackedFloat32Array = res[0]
				var flags: PackedInt32Array = res[1]
				var mins: PackedFloat32Array = res[2]
				for i in gpu_items.size():
					var item: Array = gpu_items[i]
					if not out.has(item[0]):
						out[item[0]] = []
					out[item[0]].append([item[2], dens.slice(i * SAMPLES, (i + 1) * SAMPLES), flags[i], mins[i]])
			_mutex.lock()
			for owner in out:
				if _done.has(owner):
					(_done[owner] as Array).append_array(out[owner])
				else:
					_done[owner] = out[owner]
			_mutex.unlock()
