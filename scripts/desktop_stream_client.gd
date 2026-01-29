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

func _ready() -> void:
	_current_delay = reconnect_delay_sec
	_next_reconnect_time = reconnect_delay_sec
	
	# Try to initialize H.264 decoder GDExtension
	if ClassDB.class_exists("H264Decoder"):
		_h264_decoder = ClassDB.instantiate("H264Decoder")
		if _h264_decoder:
			print("[DesktopClient] H264Decoder extension loaded successfully")
			if _h264_decoder.has_method("initialize"):
				_h264_decoder.initialize()
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
	# New frame format: [FrameType:1][CursorU:4][CursorV:4][Data:N]
	# FrameType: 0 = P-frame, 1 = I-frame (keyframe)
	if bytes.size() < 10:
		# Try old format for backwards compatibility
		_handle_frame_legacy(bytes)
		return
	
	var start_time := Time.get_ticks_usec()
	
	# Parse header
	var frame_type := bytes[0] # 0 = P-frame, 1 = I-frame
	var cursor_u := bytes.decode_float(1)
	var cursor_v := bytes.decode_float(5)
	var frame_data := bytes.slice(9)
	
	# Emit cursor position
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
		if _frame_count % 60 == 0:
			print("[DesktopClient] Waiting for keyframe... (received P-frame)")
		return
	
	# Decode the image - try H.264 first, then JPEG
	var image := Image.new()
	var decode_success := false
	
	if _use_h264 and _h264_decoder:
		# Try H.264 decode using GDExtension
		var rgba_data: PackedByteArray = _h264_decoder.decode_frame(frame_data)
		if rgba_data.size() > 0:
			var w: int = _h264_decoder.get_width()
			var h: int = _h264_decoder.get_height()
			image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba_data)
			decode_success = true
			# print("Decoded H.264 frame: %dx%d" % [w, h])
		else:
			print("[DesktopClient] H.264 decode returned empty (FrameType: %d, Size: %d)" % [frame_type, frame_data.size()])
			if is_keyframe:
				# Reset decoder on keyframe decode failure
				print("[DesktopClient] Keyframe decode failed, resetting decoder")
				_h264_decoder.reset()
	
	# Fallback to JPEG if H.264 failed or not available
	if not decode_success:
		# If we expected H.264 but got here, it's likely a failure.
		# But if we aren't using H264, this is normal path.
		if _use_h264:
			print("Fallback to JPEG/PNG (H.264 failed or empty)")
			
		var err := image.load_jpg_from_buffer(frame_data)
		if err != OK:
			err = image.load_png_from_buffer(frame_data)
		if err == OK:
			decode_success = true
		else:
			# Neither codec worked
			if _frame_count % 100 == 0:
				print("[DesktopClient] Failed to decode frame (neither H.264 nor JPEG)")
			return
	
	# ═══════════════════════════════════════════════════════════════════════
	# OPTIMIZATION: Reuse texture instead of allocating new one each frame
	# ═══════════════════════════════════════════════════════════════════════
	var frame_size := Vector2i(image.get_width(), image.get_height())
	
	if _reusable_texture == null or frame_size != _last_frame_size:
		# First frame or resolution changed - create new texture
		_reusable_texture = ImageTexture.create_from_image(image)
		_last_frame_size = frame_size
		print("[DesktopClient] Created texture: ", frame_size)
	else:
		# Reuse existing texture - just update the data
		_reusable_texture.update(image)
	
	emit_signal("frame_received", _reusable_texture)
	
	# Performance tracking
	_frame_count += 1
	_frames_this_second += 1
	_decode_time_ms = (Time.get_ticks_usec() - start_time) / 1000.0
	
	if _frame_count % 300 == 1:
		print("[DesktopClient] Frame #%d, %dx%d, decode: %.1fms, FPS: %d (I:%d P:%d)" % [
			_frame_count, frame_size.x, frame_size.y, _decode_time_ms,
			_current_fps, _keyframes_received, _pframes_received
		])

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
