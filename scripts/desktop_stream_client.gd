extends Node
## Optimized Desktop Stream Client
## Handles H.264 or JPEG frames from server with texture reuse

signal frame_received(texture: Texture2D)
signal cursor_received(uv: Vector2)
signal status_changed(text: String)
signal connection_changed(connected: bool)

@export var server_url: String = "ws://10.0.0.127/ws"
@export var auto_connect: bool = true
@export var auto_reconnect: bool = true
@export var reconnect_delay_sec: float = 1.0
@export var reconnect_max_delay_sec: float = 5.0

var _ws: WebSocketPeer = null
var _last_state := WebSocketPeer.STATE_CLOSED
var _next_reconnect_time := 0.0
var _current_delay: float = 1.0
var _connecting := false

# ═══════════════════════════════════════════════════════════════════════════
# OPTIMIZATION: Texture reuse to avoid GPU allocations per frame
# ═══════════════════════════════════════════════════════════════════════════
var _reusable_texture: ImageTexture = null
var _reusable_image: Image = null
var _last_frame_size: Vector2i = Vector2i.ZERO

# Performance tracking
var _frame_count := 0
var _frames_this_second := 0
var _last_fps_time := 0.0
var _current_fps := 0.0
var _decode_time_ms := 0.0
var _keyframes_received := 0
var _pframes_received := 0

# H.264 decode state
var _waiting_for_keyframe := true
var _h264_buffer := PackedByteArray()
var _h264_decoder = null # H264Decoder GDExtension instance
var _use_h264 := true # Try H.264 first, fall back to JPEG if extension not available

# Threading
var _decode_thread: Thread
var _decode_semaphore: Semaphore
var _decode_mutex: Mutex
var _frame_queue: Array = []
var _exit_thread := false

func _ready() -> void:
	_current_delay = reconnect_delay_sec
	_next_reconnect_time = reconnect_delay_sec
	
	# Initialize Threading
	_decode_semaphore = Semaphore.new()
	_decode_mutex = Mutex.new()
	_decode_thread = Thread.new()
	_decode_thread.start(_decode_loop)

	# Try to initialize H.264 decoder GDExtension
	if ClassDB.class_exists("H264Decoder"):
		_h264_decoder = ClassDB.instantiate("H264Decoder")
		if _h264_decoder:
			print("[DesktopClient] H264Decoder extension loaded successfully")
			if _h264_decoder.has_method("initialize"):
				_h264_decoder.initialize(1920, 1080)
		else:
			print("[DesktopClient] Failed to instantiate H264Decoder")
			_use_h264 = false
	else:
		print("[DesktopClient] H264Decoder class not found - using JPEG fallback")
		_use_h264 = false
	
	if auto_connect:
		connect_to_server()

func connect_to_server() -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return
	if _connecting:
		return
	if server_url.strip_edges() == "":
		emit_signal("status_changed", "Desktop stream: missing server URL")
		return
	
	# Create a fresh WebSocketPeer
	_ws = WebSocketPeer.new()
	
	# Larger buffers for video frames (H.264 frames are smaller but we need headroom)
	_ws.inbound_buffer_size = 2 * 1024 * 1024 # 2MB
	_ws.outbound_buffer_size = 64 * 1024
	_ws.max_queued_packets = 16 # More packets for higher FPS
	
	_ws.handshake_headers = PackedStringArray([
		"User-Agent: Godot/4.6",
		"Origin: godot-app"
	])
	
	_connecting = true
	_waiting_for_keyframe = true
	
	print("[DesktopClient] Connecting to: ", server_url)
	var err := _ws.connect_to_url(server_url)
	if err != OK:
		_connecting = false
		var err_name := _get_error_name(err)
		print("[DesktopClient] Connect failed: ", err_name)
		emit_signal("status_changed", "Connect failed: %s" % err_name)
	else:
		emit_signal("status_changed", "Desktop stream: connecting...")

func disconnect_from_server() -> void:
	_connecting = false
	if _ws != null and _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close()

func _process(delta: float) -> void:
	# FPS counter
	_last_fps_time += delta
	if _last_fps_time >= 1.0:
		_current_fps = _frames_this_second
		_frames_this_second = 0
		_last_fps_time = 0.0
	
	# Reconnection logic
	if auto_reconnect and (_ws == null or _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED):
		if not _connecting:
			_next_reconnect_time = max(_next_reconnect_time - delta, 0.0)
			if _next_reconnect_time <= 0.0:
				connect_to_server()
				_current_delay = min(_current_delay * 1.5, reconnect_max_delay_sec)
				_next_reconnect_time = _current_delay
	
	if _ws == null:
		return
	
	_ws.poll()
	var state := _ws.get_ready_state()
	
	if state != _last_state:
		_last_state = state
		_connecting = false
		match state:
			WebSocketPeer.STATE_OPEN:
				print("[DesktopClient] Connected!")
				emit_signal("status_changed", "Desktop stream: connected")
				emit_signal("connection_changed", true)
				_current_delay = reconnect_delay_sec
				_next_reconnect_time = reconnect_delay_sec
				_send_hello()
				_request_keyframe()
			WebSocketPeer.STATE_CONNECTING:
				emit_signal("status_changed", "Desktop stream: connecting")
			WebSocketPeer.STATE_CLOSING:
				emit_signal("status_changed", "Desktop stream: closing")
			WebSocketPeer.STATE_CLOSED:
				var code := _ws.get_close_code()
				print("[DesktopClient] Disconnected, code: ", code)
				emit_signal("status_changed", "Disconnected (code: %d)" % code)
				emit_signal("connection_changed", false)
	
	# Process all available packets
	while _ws.get_available_packet_count() > 0:
		var packet := _ws.get_packet()
		# Only handle binary packets as video frames
		if _ws.was_string_packet():
			pass # Handle text messages if needed
		else:
			_handle_frame(packet)

func _exit_tree() -> void:
	# Clean exit thread
	_exit_thread = true
	if _decode_semaphore:
		_decode_semaphore.post()
	if _decode_thread and _decode_thread.is_started():
		_decode_thread.wait_to_finish()
	
	disconnect_from_server()
	
	if _h264_decoder:
		if _h264_decoder.has_method("cleanup"):
			_h264_decoder.cleanup()
		_h264_decoder = null

func _decode_loop() -> void:
	while not _exit_thread:
		_decode_semaphore.wait()
		if _exit_thread:
			break
			
		_decode_mutex.lock()
		if _frame_queue.is_empty():
			_decode_mutex.unlock()
			continue
			
		var frame_data = _frame_queue.pop_front()
		_decode_mutex.unlock()
		
		var is_keyframe = frame_data.is_keyframe
		var data_bytes = frame_data.bytes
		
		# Decode off-thread
		var image: Image = null
		var decode_success := false
		
		if _use_h264 and _h264_decoder:
			var rgba_data: PackedByteArray = _h264_decoder.decode_frame(data_bytes)
			if rgba_data.size() > 0:
				var w: int = _h264_decoder.get_width()
				var h: int = _h264_decoder.get_height()
				image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba_data)
				decode_success = true
			elif is_keyframe:
				_h264_decoder.reset()
		
		# Fallback to JPEG if needed (still off-thread!)
		if not decode_success:
			image = Image.new()
			var err := image.load_jpg_from_buffer(data_bytes)
			if err != OK:
				err = image.load_png_from_buffer(data_bytes)
			if err == OK:
				decode_success = true
		
		if decode_success and image:
			# Send back to main thread for texture update
			call_deferred("_update_texture_on_main_thread", image)

func _update_texture_on_main_thread(image: Image) -> void:
	# OPTIMIZATION: Reuse texture logic here, on main thread where it's safe
	var frame_size := Vector2i(image.get_width(), image.get_height())
	
	if _reusable_texture == null or frame_size != _last_frame_size:
		_reusable_texture = ImageTexture.create_from_image(image)
		_last_frame_size = frame_size
		# print("[DesktopClient] Created texture: ", frame_size)
	else:
		_reusable_texture.update(image)
	
	emit_signal("frame_received", _reusable_texture)
	
	# Performance tracking
	_frame_count += 1
	_frames_this_second += 1
	
	if _frame_count % 300 == 1:
		print("[DesktopClient] Frame #%d, %dx%d, FPS: %d (I:%d P:%d) [Threaded]" % [
			_frame_count, frame_size.x, frame_size.y,
			_current_fps, _keyframes_received, _pframes_received
		])
	while _ws.get_available_packet_count() > 0:
		var packet := _ws.get_packet()
		if _ws.was_string_packet():
			_handle_text(packet.get_string_from_utf8())
		else:
			_handle_frame(packet)

func _get_error_name(err: int) -> String:
	match err:
		OK: return "OK"
		ERR_CANT_CONNECT: return "ERR_CANT_CONNECT"
		ERR_CANT_RESOLVE: return "ERR_CANT_RESOLVE"
		ERR_CONNECTION_ERROR: return "ERR_CONNECTION_ERROR"
		ERR_TIMEOUT: return "ERR_TIMEOUT"
		_: return "ERROR_%d" % err

func _send_hello() -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var msg := {"type": "hello", "client": "godot", "version": 2}
	_ws.send_text(JSON.stringify(msg))

func _request_keyframe() -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var msg := {"type": "request_keyframe"}
	_ws.send_text(JSON.stringify(msg))
	print("[DesktopClient] Requested keyframe")

func _handle_text(text: String) -> void:
	var data = JSON.parse_string(text)
	if typeof(data) == TYPE_DICTIONARY:
		if data.has("type") and data.type == "status" and data.has("text"):
			emit_signal("status_changed", String(data.text))

# ═══════════════════════════════════════════════════════════════════════════
# FRAME HANDLING - Optimized with texture reuse
# ═══════════════════════════════════════════════════════════════════════════

func _handle_frame(bytes: PackedByteArray) -> void:
	# New format: [FrameType:1][CursorU:4][CursorV:4][Data:N]
	# FrameType: 0 = P-frame, 1 = I-frame (keyframe)
	if bytes.size() < 10:
		# Try old format for backwards compatibility
		_handle_frame_legacy(bytes)
		return
	
	# Parse header on main thread (very fast)
	var frame_type := bytes[0] # 0 = P-frame, 1 = I-frame
	var cursor_u: float = bytes.decode_float(1)
	var cursor_v: float = bytes.decode_float(5)
	var frame_data := bytes.slice(9)
	
	# Emit cursor position immediately
	emit_signal("cursor_received", Vector2(cursor_u, cursor_v))
	
	# Track keyframes
	var is_keyframe := (frame_type == 1)
	if is_keyframe:
		_keyframes_received += 1
		_waiting_for_keyframe = false
	else:
		_pframes_received += 1
	
	# Skip P-frames until we get a keyframe (for H.264)
	if _waiting_for_keyframe and not is_keyframe:
		return
	
	# Push to thread queue
	_decode_mutex.lock()
	# Drop old frames if we are falling behind (latency optimization)
	if _frame_queue.size() > 2:
		_frame_queue.pop_front() # Drop oldest
	
	_frame_queue.append({
		"bytes": frame_data,
		"is_keyframe": is_keyframe
	})
	_decode_mutex.unlock()
	_decode_semaphore.post()
	

func _handle_frame_legacy(bytes: PackedByteArray) -> void:
	# Old format: [CursorU:4][CursorV:4][JPEG:N]
	if bytes.size() < 9:
		return
	
	var cursor_u := bytes.decode_float(0)
	var cursor_v := bytes.decode_float(4)
	emit_signal("cursor_received", Vector2(cursor_u, cursor_v))
	
	var jpeg_data := bytes.slice(8)
	var image := Image.new()
	var err := image.load_jpg_from_buffer(jpeg_data)
	if err != OK:
		return
	
	# Texture reuse
	var frame_size := Vector2i(image.get_width(), image.get_height())
	if _reusable_texture == null or frame_size != _last_frame_size:
		_reusable_texture = ImageTexture.create_from_image(image)
		_last_frame_size = frame_size
	else:
		_reusable_texture.update(image)
	
	emit_signal("frame_received", _reusable_texture)
	_frame_count += 1
	_frames_this_second += 1

# ═══════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═══════════════════════════════════════════════════════════════════════════

func is_stream_connected() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

func get_fps() -> float:
	return _current_fps

func get_decode_time_ms() -> float:
	return _decode_time_ms

func send_pointer_event(uv: Vector2, pressed: bool, just_pressed: bool, just_released: bool, button: int = 0) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var msg := {
		"type": "pointer",
		"u": uv.x,
		"v": uv.y,
		"pressed": pressed,
		"down": just_pressed,
		"up": just_released,
		"button": button
	}
	_ws.send_text(JSON.stringify(msg))
