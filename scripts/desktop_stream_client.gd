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
var _running := false
var _network_thread: Thread
var _decode_thread: Thread
var _decode_semaphore: Semaphore
var _decode_mutex: Mutex
var _frame_queue: Array[Dictionary] = [] # Stores {bytes: PackedByteArray, start_time: int}

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
var _audio_buffer: PackedVector2Array = PackedVector2Array() # Jitter buffer
var _prebuffering := true
var _prebuffer_size := 28800 # ~600ms at 48kHz (v3.7 Overhaul)
var _target_playback_fill := 4800 # Keep 100ms in Godot's buffer

func _ready() -> void:
	print("[DesktopClient] CLIENT v3.7 (Stateless Audio & Network Threading)")
	emit_signal("status_changed", "Client v3.7 Loaded")
	
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
	_running = true
	_decode_thread = Thread.new()
	_decode_semaphore = Semaphore.new()
	_decode_mutex = Mutex.new()
	_decode_thread.start(_decode_loop)
	
	_network_thread = Thread.new()
	_network_thread.start(_network_loop)
	
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
	if _network_thread.is_started():
		_network_thread.wait_to_finish()

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
	# FPS counter (updated by decode thread, displayed by main)
	_last_fps_time += delta
	if _last_fps_time >= 1.0:
		_current_fps = _frames_this_second
		_frames_this_second = 0
		_last_fps_time = 0.0
	
	_update_audio_buffer()

func _network_loop() -> void:
	print("[Network] Background thread started")
	# Reconnection and polling happen purely in this thread
	while _running:
		if _ws == null or _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			if auto_reconnect and not _connecting:
				OS.delay_msec(1000)
				call_deferred("connect_to_server")
			else:
				OS.delay_msec(100)
			continue
			
		_ws.poll()
		var state = _ws.get_ready_state()
		
		# Handle Connection State Changes
		if state != _last_state:
			_last_state = state
			if state == WebSocketPeer.STATE_OPEN:
				print("[Network] Connected to server!")
				_audio_buffer.clear()
				_prebuffering = true
				_waiting_for_keyframe = true
				call_deferred("emit_signal", "status_changed", "Connected")
				call_deferred("emit_signal", "connection_changed", true)
				_connecting = false
			elif state == WebSocketPeer.STATE_CLOSED:
				print("[Network] Disconnected")
				call_deferred("emit_signal", "status_changed", "Disconnected")
				call_deferred("emit_signal", "connection_changed", false)
				_connecting = false
				
		# Process All Available Packets
		while _ws.get_available_packet_count() > 0:
			var packet = _ws.get_packet()
			if packet.size() < 1: continue
			
			var type = packet[0]
			if type == 0 or type == 1:
				# Video Frame Packet [Type:1][U:4][V:4][Data:N]
				var video_data = packet.slice(9)
				var cursor_u = packet.decode_float(1)
				var cursor_v = packet.decode_float(5)
				call_deferred("emit_signal", "cursor_received", Vector2(cursor_u, cursor_v))
				
				_decode_mutex.lock()
				_frame_queue.append({
					"bytes": video_data,
					"is_key": (type == 1),
					"time": Time.get_ticks_msec()
				})
				_decode_mutex.unlock()
				_decode_semaphore.post()
				
			elif type == 3:
				# Audio Packet (Stateless ADPCM)
				var adpcm_data = packet.slice(1)
				_handle_audio_packet(adpcm_data)
				
		OS.delay_msec(1) # Keep CPU usage sane (1000Hz poll rate)

func _handle_audio_packet(adpcm_data: PackedByteArray) -> void:
	if not _h264_decoder or adpcm_data.size() < 6:
		return
		
	# Decode IMA ADPCM in C++ extension
	var samples: PackedVector2Array = _h264_decoder.decode_audio(adpcm_data)
	
	if samples.size() > 0:
		_audio_buffer.append_array(samples)
		
		# Latency management (drop if >1 second backlog)
		if _audio_buffer.size() > 48000:
			_audio_buffer = _audio_buffer.slice(_audio_buffer.size() - 24000)
			print("[Audio] Buffer overflow, catchup triggered")

func _update_audio_buffer() -> void:
	if not _audio_playback:
		return
		
	if _prebuffering:
		if _audio_buffer.size() >= _prebuffer_size:
			_prebuffering = false
			print("[Audio] Prebuffering complete.")
		else:
			return
			
func _update_audio_buffer() -> void:
	if not _audio_playback:
		return
		
	if _prebuffering:
		if _audio_buffer.size() >= _prebuffer_size:
			_prebuffering = false
			print("[Audio] Prebuffering complete, starting playback.")
			emit_signal("status_changed", "Audio Stream: Playing")
		else:
			return # Keep buffering
			
	# Push samples to fill the Godot buffer
	var frames_needed = _audio_playback.get_frames_available()
	if frames_needed > 0 and _audio_buffer.size() > 0:
		var to_push = min(_audio_buffer.size(), frames_needed)
		var push_data = _audio_buffer.slice(0, to_push)
		_audio_playback.push_buffer(push_data)
		_audio_buffer = _audio_buffer.slice(to_push)

func _handle_audio_packet(adpcm_data: PackedByteArray) -> void:
	# Decoding IMA ADPCM in C++ GDExtension (returns PackedVector2Array)
	var samples: PackedVector2Array = _h264_decoder.decode_audio(adpcm_data)
	
	_audio_buffer.append_array(samples)
	
	# Auto-catchup: If buffer is huge (>1200ms), drop older samples to reduce latency
	if _audio_buffer.size() > 57600:
		_audio_buffer = _audio_buffer.slice(_audio_buffer.size() - 28800)
		print("[Audio] Jitter buffer overflow - skipping ahead to reduce latency")

func _update_audio_buffer() -> void:
	if not _audio_playback:
		return
		
	if _prebuffering:
		if _audio_buffer.size() >= _prebuffer_size:
			_prebuffering = false
			print("[Audio] Prebuffering complete, starting playback.")
			emit_signal("status_changed", "Audio Stream: Playing")
		else:
			return # Keep buffering
			
	# Push samples to fill the Godot buffer
	var frames_needed = _audio_playback.get_frames_available()
	if frames_needed > 0 and _audio_buffer.size() > 0:
		var to_push = min(_audio_buffer.size(), frames_needed)
		var push_data = _audio_buffer.slice(0, to_push)
		_audio_playback.push_buffer(push_data)
		_audio_buffer = _audio_buffer.slice(to_push)

func _network_loop() -> void:
	print("[Network] Background thread started")
	while _running:
		if _ws == null or _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			if auto_reconnect and not _connecting:
				OS.delay_msec(1000)
				# No await in threads, use OS.delay
				call_deferred("connect_to_server")
			else:
				OS.delay_msec(100)
			continue
			
		_ws.poll()
		var state = _ws.get_ready_state()
		
		if state != _last_state:
			_last_state = state
			if state == WebSocketPeer.STATE_OPEN:
				print("[Network] Connected to server!")
				# Reset audio buffer on new connection
				_audio_buffer.clear()
				_prebuffering = true
				call_deferred("emit_signal", "status_changed", "Desktop stream: connected")
				call_deferred("emit_signal", "connection_changed", true)
				_connecting = false
			elif state == WebSocketPeer.STATE_CLOSED:
				print("[Network] Disconnected from server")
				call_deferred("emit_signal", "status_changed", "Desktop stream: disconnected")
				call_deferred("emit_signal", "connection_changed", false)
				_connecting = false
				
		while _ws.get_available_packet_count() > 0:
			var packet = _ws.get_packet()
			if packet.size() < 1: continue
			
			var type = packet[0]
			if type == 0 or type == 1:
				# Video packet
				var video_data = packet.slice(9)
				var cursor_u = packet.decode_float(1)
				var cursor_v = packet.decode_float(5)
				call_deferred("emit_signal", "cursor_received", Vector2(cursor_u, cursor_v))
				
				_decode_mutex.lock()
				_frame_queue.append({
					"bytes": video_data,
					"is_key": (type == 1),
					"time": Time.get_ticks_msec()
				})
				_decode_mutex.unlock()
				_decode_semaphore.post()
				
			elif type == 3:
				# Audio packet (stateless IMA ADPCM)
				var adpcm_data = packet.slice(1)
				_handle_audio_packet(adpcm_data)
				
		OS.delay_msec(1) # Keep CPU usage sane but latency low

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
