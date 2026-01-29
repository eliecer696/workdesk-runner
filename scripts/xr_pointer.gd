extends XRController3D

@export var ray_length: float = 10.0
@export var screen_path: NodePath
@export var client_path: NodePath
@export var viewport_path: NodePath
@export var screen_controller_path: NodePath
@export var send_rate_hz: float = 60.0
@export var trigger_threshold: float = 0.55
@export var screen_size: Vector2 = Vector2(2.4, 1.35)
@export var debug_input: bool = false  # Set to true to see input values in console

var ray: RayCast3D
var laser: MeshInstance3D
var reticle: MeshInstance3D

var _screen_body: Node3D
var _client: Node
var _viewport: SubViewport
var _screen_controller: Node
var _primary_down := false
var _secondary_down := false  # For right-click
var _time_since_send := 0.0
var _last_uv := Vector2(-1, -1)
var _last_pos_px := Vector2.ZERO
var _debug_timer := 0.0
var _xr_active := false
var _pointer_over_screen := false
var _hovered_ui_button: Node3D = null
var _ui_panel: Node = null

func _ready() -> void:
	_screen_body = get_node_or_null(screen_path)
	_client = get_node_or_null(client_path)
	_viewport = get_node_or_null(viewport_path)
	_screen_controller = get_node_or_null(screen_controller_path)
	
	# Find child nodes - supports both naming conventions
	for child in get_children():
		if child is RayCast3D and ray == null:
			ray = child
		elif child is MeshInstance3D:
			if "laser" in child.name.to_lower():
				laser = child
			elif "reticle" in child.name.to_lower():
				reticle = child
	
	if ray:
		ray.target_position = Vector3(0, 0, -ray_length)
		ray.enabled = true
	_update_laser(ray_length)
	_set_reticle(false)
	
	# Check if XR is active
	var xr_interface := XRServer.primary_interface
	_xr_active = xr_interface != null and xr_interface.is_initialized()
	print("[XRPointer] XR Active: ", _xr_active)
	print("[XRPointer] Controller tracker: ", tracker)
	print("[XRPointer] Screen body: ", _screen_body)
	print("[XRPointer] Client: ", _client)
	print("[XRPointer] Screen controller: ", _screen_controller)

func _process(delta: float) -> void:
	_time_since_send += delta
	var is_over_screen := false
	var hit_ui_button: Node3D = null
	
	if ray:
		ray.target_position = Vector3(0, 0, -ray_length)
		ray.force_raycast_update()
		if ray.is_colliding():
			var collider := ray.get_collider()
			
			# Check for UI button hit
			if collider and collider.is_in_group("ui_button"):
				var hit := ray.get_collision_point()
				_set_reticle(true, hit)
				_update_laser(_distance_to(hit))
				hit_ui_button = collider
				_handle_ui_button_input(collider)
			# Check for screen hit
			elif collider and collider.is_in_group("screen") and _screen_body:
				var hit := ray.get_collision_point()
				var uv := _screen_uv(hit)
				if _is_uv_valid(uv):
					is_over_screen = true
					_set_reticle(true, hit)
					_update_laser(_distance_to(hit))
					_send_pointer(uv)
	
	# Update UI button hover state
	_update_ui_button_hover(hit_ui_button)
	
	# Update screen controller about pointer status
	if is_over_screen != _pointer_over_screen:
		_pointer_over_screen = is_over_screen
		if _screen_controller and _screen_controller.has_method("set_pointer_over_screen"):
			_screen_controller.set_pointer_over_screen(is_over_screen)
	
	if not is_over_screen and hit_ui_button == null:
		_clear_pointer()

func _handle_ui_button_input(button: Node3D) -> void:
	# Check for trigger press to activate button
	var trigger_val: float = get_float("trigger")
	var pressed := trigger_val > trigger_threshold
	
	if pressed and not _primary_down:
		# Button just pressed
		var button_label: String = button.get_meta("button_label", "")
		if button_label != "":
			# Find the UI panel and trigger the button
			if _ui_panel == null:
				_ui_panel = get_tree().get_first_node_in_group("screen_ui_panel")
			if _ui_panel and _ui_panel.has_method("handle_button_press"):
				_ui_panel.handle_button_press(button_label)
				print("[XRPointer] UI Button pressed: ", button_label)
	
	_primary_down = pressed

func _update_ui_button_hover(new_button: Node3D) -> void:
	if _hovered_ui_button == new_button:
		return
	
	if _ui_panel == null:
		_ui_panel = get_tree().get_first_node_in_group("screen_ui_panel")
	
	# Clear old hover
	if _hovered_ui_button != null and _ui_panel:
		var old_label: String = _hovered_ui_button.get_meta("button_label", "")
		if old_label != "" and _ui_panel.has_method("set_button_hovered"):
			_ui_panel.set_button_hovered(old_label, false)
	
	# Set new hover
	if new_button != null and _ui_panel:
		var new_label: String = new_button.get_meta("button_label", "")
		if new_label != "" and _ui_panel.has_method("set_button_hovered"):
			_ui_panel.set_button_hovered(new_label, true)
	
	_hovered_ui_button = new_button

func _clear_pointer() -> void:
	if _primary_down:
		_primary_down = false
		if _client and _client.has_method("send_pointer_event"):
			_client.call("send_pointer_event", _last_uv, false, false, true, 0)  # Release left
	if _secondary_down:
		_secondary_down = false
		if _client and _client.has_method("send_pointer_event"):
			_client.call("send_pointer_event", _last_uv, false, false, true, 1)  # Release right
	_set_reticle(false)
	_update_laser(ray_length)

func _screen_uv(hit: Vector3) -> Vector2:
	var local := _screen_body.to_local(hit)
	var u := local.x / screen_size.x + 0.5
	var v := -local.y / screen_size.y + 0.5
	return Vector2(u, v)

func _is_uv_valid(uv: Vector2) -> bool:
	return uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0

func _distance_to(hit: Vector3) -> float:
	return global_transform.origin.distance_to(hit)

func _set_reticle(is_visible: bool, hit_pos: Vector3 = Vector3.ZERO) -> void:
	if not reticle:
		return
	reticle.visible = is_visible
	if is_visible:
		reticle.global_transform.origin = hit_pos

func _update_laser(distance: float) -> void:
	if not laser:
		return
	var clamped: float = maxf(distance, 0.01)
	laser.scale = Vector3(1, 1, clamped)
	laser.position = Vector3(0, 0, -clamped * 0.5)

func _send_pointer(uv: Vector2) -> void:
	# Primary button (left click) - trigger
	var trigger_val: float = get_float("trigger")
	var pressed := trigger_val > trigger_threshold
	if is_button_pressed("trigger_click"):
		pressed = true
	
	# Debug logging every second
	if debug_input:
		_debug_timer += get_process_delta_time()
		if _debug_timer >= 1.0:
			_debug_timer = 0.0
			var is_tracking = get_is_active()
			print("[XRPointer] trigger=%.2f, grip=%.2f, tracking=%s" % [
				trigger_val,
				get_float("grip"),
				str(is_tracking)
			])
	
	var just_pressed := pressed and not _primary_down
	var just_released := (not pressed) and _primary_down
	_primary_down = pressed
	
	# Secondary button (right click) - grip or secondary button
	# But NOT if screen is being grabbed
	var is_screen_grabbing := false
	if _screen_controller and _screen_controller.has_method("is_grabbing"):
		is_screen_grabbing = _screen_controller.is_grabbing()
	
	var grip_val: float = get_float("grip")
	var secondary_pressed := false
	
	# Only use grip for right-click if NOT grabbing the screen
	if not is_screen_grabbing:
		secondary_pressed = grip_val > trigger_threshold
		if is_button_pressed("grip_click"):
			secondary_pressed = true
	
	# Also check for "secondary" or "by" button (B/Y on controllers) - these always work
	if is_button_pressed("by_button") or is_button_pressed("secondary_click"):
		secondary_pressed = true
	
	var secondary_just_pressed := secondary_pressed and not _secondary_down
	var secondary_just_released := (not secondary_pressed) and _secondary_down
	_secondary_down = secondary_pressed
	
	var should_send: bool = _time_since_send >= (1.0 / max(send_rate_hz, 1.0)) or uv.distance_to(_last_uv) > 0.002
	_send_local_ui(uv, pressed, just_pressed, just_released, secondary_pressed, secondary_just_pressed, secondary_just_released)
	
	if just_pressed or just_released or secondary_just_pressed or secondary_just_released or should_send:
		_time_since_send = 0.0
		_last_uv = uv
		var can_send := true
		if _client and _client.has_method("is_stream_connected"):
			can_send = bool(_client.call("is_stream_connected"))
		if can_send and _client and _client.has_method("send_pointer_event"):
			# Send left-click events
			if just_pressed or just_released or should_send:
				_client.call("send_pointer_event", uv, pressed, just_pressed, just_released, 0)
			# Send right-click events
			if secondary_just_pressed or secondary_just_released:
				_client.call("send_pointer_event", uv, secondary_pressed, secondary_just_pressed, secondary_just_released, 1)

func _send_local_ui(uv: Vector2, pressed: bool, just_pressed: bool, just_released: bool, secondary_pressed: bool = false, secondary_just_pressed: bool = false, secondary_just_released: bool = false) -> void:
	if not _viewport:
		return
	var size := _viewport.size
	if size.x <= 0 or size.y <= 0:
		return
	var pos := Vector2(uv.x * size.x, uv.y * size.y)
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	motion.relative = pos - _last_pos_px
	_last_pos_px = pos
	_viewport.push_input(motion)
	
	# Left click
	if just_pressed or just_released:
		var button := InputEventMouseButton.new()
		button.position = pos
		button.global_position = pos
		button.button_index = MOUSE_BUTTON_LEFT
		button.pressed = pressed
		_viewport.push_input(button)
	
	# Right click
	if secondary_just_pressed or secondary_just_released:
		var button := InputEventMouseButton.new()
		button.position = pos
		button.global_position = pos
		button.button_index = MOUSE_BUTTON_RIGHT
		button.pressed = secondary_pressed
		_viewport.push_input(button)
