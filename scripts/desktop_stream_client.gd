extends Node
## Optimized Desktop Stream Client
## Handles H.264 or JPEG frames from server with texture reuse
## Now using threaded decoding to prevent VR stutter

signal frame_received(texture: Texture2D, is_yuv: bool)
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
# THREADING & OPTIMIZATION
# ═══════════════════════════════════════════════════════════════════════════
var _decode_thread: Thread
var _decode_semaphore: Semaphore
var _decode_mutex: Mutex
var _frame_queue: Array[Dictionary] = [] # Stores {bytes: PackedByteArray, start_time: int}
var _running := false

var _reusable_texture: ImageTexture = null
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
var _h264_decoder = null # H264Decoder GDExtension instance
var _use_h264 := true # Try H.264 first, fall back to JPEG if extension not available

# Audio State
var _audio_player: AudioStreamPlayer
var _audio_playback: AudioStreamGeneratorPlayback
var _audio_generator: AudioStreamGenerator
var _audio_started := false

func _ready() -> void:
	print("[DesktopClient] CLIENT v3.4 (Audio Debug)")
	emit_signal("status_changed", "Client v3.4 Loaded")
	
	# Create shared resources
	_frame_queue = []
	_current_delay = reconnect_delay_sec
	_next_reconnect_time = reconnect_delay_sec
	
	# Initialize Audio
	_audio_player = AudioStreamPlayer.new()
	_audio_generator = AudioStreamGenerator.new()
	_audio_generator.mix_rate = 48000
	_audio_generator.buffer_length = 0.5
	_audio_player.stream = _audio_generator
	add_child(_audio_player)
	_audio_player.play()
	_audio_playback = _audio_player.get_stream_playback()
	
	# Initialize Threading
	_decode_thread = Thread.new()
	_decode_semaphore = Semaphore.new()
	_decode_mutex = Mutex.new()
	_running = true
	_decode_thread.start(_decode_loop)
	
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

func _exit_tree() -> void:
	disconnect_from_server()
	# Stop thread
	_running = false
	_decode_semaphore.post()
	if _decode_thread.is_started():
		_decode_thread.wait_to_finish()

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
	
	# Larger buffers for video frames
	_ws.inbound_buffer_size = 4 * 1024 * 1024 # 4MB buffer for 4k support
	_ws.outbound_buffer_size = 64 * 1024
	_ws.max_queued_packets = 32
	
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
			_handle_frame_packet(packet)

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
# THREADED DECODING LOGIC
# ═══════════════════════════════════════════════════════════════════════════

func _handle_frame_packet(bytes: PackedByteArray) -> void:
	# Extract cursor data IMMEDIATELY on main thread for minimum latency
	if bytes.size() >= 9:
		# New format: [FrameType:1][CursorU:4][CursorV:4][Data:N]
		# 0=P-Frame, 1=I-Frame, 2=MouseOnly, 3=Audio
		var type := bytes[0]
		
		if type <= 2:
			var cursor_u := bytes.decode_float(1)
			var cursor_v := bytes.decode_float(5)
			emit_signal("cursor_received", Vector2(cursor_u, cursor_v))
			
			# If MouseOnly, stop here (no video data to decode)
			if type == 2:
				return
		elif type == 3:
			_handle_audio_packet(bytes.slice(1))
			return
	elif bytes.size() >= 8:
		# Old format
		var cursor_u := bytes.decode_float(0)
		var cursor_v := bytes.decode_float(4)
		emit_signal("cursor_received", Vector2(cursor_u, cursor_v))
	
	# Offload decoding to thread
	_decode_mutex.lock()
	_frame_queue.push_back({
		"bytes": bytes,
		"time": Time.get_ticks_usec()
	})
	_decode_mutex.unlock()
	_decode_semaphore.post()

func _handle_audio_packet(adpcm_data: PackedByteArray) -> void:
	if not _h264_decoder or not _audio_playback:
		return
		
	# Decoding IMA ADPCM in C++ GDExtension (returns PackedVector2Array)
	var samples: PackedVector2Array = _h264_decoder.decode_audio(adpcm_data)
	
	if not _audio_started:
		_audio_started = true
		print("[Audio] First packet received! Playback started.")
		emit_signal("status_changed", "Audio Stream: Receiving")
	
	# Push to Godot AudioStreamGenerator
	if samples.size() > 0:
		_audio_playback.push_buffer(samples)

func _decode_loop() -> void:
	while _running:
		_decode_semaphore.wait()
		if not _running: break
		
		# Process one frame at a time from the queue
		var frame_data = null
		
		_decode_mutex.lock()
		if not _frame_queue.is_empty():
			frame_data = _frame_queue.pop_front()
		_decode_mutex.unlock()
		
		if frame_data:
			_decode_task(frame_data.bytes, frame_data.time)

func _decode_task(bytes: PackedByteArray, start_time: int) -> void:
	# New frame format: [FrameType:1][CursorU:4][CursorV:4][Data:N]
	# FrameType: 0 = P-frame, 1 = I-frame (keyframe)
	var frame_type := 0
	var frame_data: PackedByteArray
	
	if bytes.size() < 10:
		# Legacy format fallback
		if bytes.size() < 9: return
		frame_data = bytes.slice(8)
		# Assume keyframes for JPEG legacy
		frame_type = 1
	else:
		frame_type = bytes[0]
		frame_data = bytes.slice(9)
	
	var is_keyframe := (frame_type == 1)
	
	# IMPORTANT: We must update waiting_for_keyframe state carefully.
	# Since this is running in a thread, we use a local check or careful sync.
	# However, gdscript variables are generally accessible. 
	# To be safe, we'll read property.
	
	if is_keyframe:
		# We're good
		pass
	elif _waiting_for_keyframe:
		# Skip P-frames if waiting for keyframe
		if _frame_count % 60 == 0:
			# Print on main thread using call_deferred? Or just print (thread safe usually)
			print("[DesktopClient] Waiting for keyframe... (received P-frame)")
		return

	# Decode the image - try H.264 first, then JPEG
	var image: Image = null
	var decode_success := false
	
	if _use_h264 and _h264_decoder:
		# Blocking decode call
		var decoded_data: PackedByteArray = _h264_decoder.decode_frame(frame_data)
		var data_size = decoded_data.size()
		
		if data_size > 0:
			var w: int = _h264_decoder.get_width()
			var h: int = _h264_decoder.get_height()
			var yuv_size = int(float(w * h) * 1.5)
			var rgba_size = w * h * 4
			
			if data_size == yuv_size:
				# YUV 4:2:0 packed in L8 format (1 byte per "pixel" in texture terms)
				# Texture height needs to be 1.5x original height
				image = Image.create_from_data(w, int(h * 1.5), false, Image.FORMAT_L8, decoded_data)
				decode_success = true
			elif data_size == rgba_size:
				# Standard RGBA
				image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, decoded_data)
				decode_success = true
			else:
				print("[DesktopClient] Unexpected data size: %d (Expected YUV:%d or RGB:%d)" % [data_size, yuv_size, rgba_size])
		else:
			print("[DesktopClient] H.264 decode output empty")
			if is_keyframe:
				_h264_decoder.reset()
	
	# Fallback to JPEG
	if not decode_success:
		image = Image.new()
		var err := image.load_jpg_from_buffer(frame_data)
		if err != OK:
			image.load_png_from_buffer(frame_data)
		if not image.is_empty():
			decode_success = true
		else:
			image = null

	if decode_success and image:
		# Send valid image back to main thread
		var elapsed = (Time.get_ticks_usec() - start_time) / 1000.0
		
		# We pass the image and metadata back
		call_deferred("_on_frame_decoded", image, elapsed, is_keyframe)

func _on_frame_decoded(image: Image, decode_time: float, is_keyframe: bool) -> void:
	if image == null: return
	
	# Update H.264 state on main thread
	if is_keyframe:
		_keyframes_received += 1
		_waiting_for_keyframe = false
	else:
		_pframes_received += 1

	# Reuse texture
	var frame_size := Vector2i(image.get_width(), image.get_height())
	
	if _reusable_texture == null or frame_size != _last_frame_size or _reusable_texture.get_format() != image.get_format():
		_reusable_texture = ImageTexture.create_from_image(image)
		_last_frame_size = frame_size
		print("[DesktopClient] Created texture: %dx%d fmt=%d" % [frame_size.x, frame_size.y, image.get_format()])
		print("[DesktopClient] Created texture: %dx%d fmt=%d" % [frame_size.x, frame_size.y, image.get_format()])
	else:
		_reusable_texture.set_image(image)
	
	var is_yuv = (image.get_format() == Image.FORMAT_L8)
	emit_signal("frame_received", _reusable_texture, is_yuv)
	
	# Stats
	_frame_count += 1
	_frames_this_second += 1
	_decode_time_ms = decode_time
	
	if _frame_count % 300 == 1:
		print("[DesktopClient] Frame #%d, %dx%d, decode: %.1fms, FPS: %d (I:%d P:%d)" % [
			_frame_count, frame_size.x, frame_size.y, _decode_time_ms,
			_current_fps, _keyframes_received, _pframes_received
		])

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
