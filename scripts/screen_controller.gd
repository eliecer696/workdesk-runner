extends Node3D
## VR Screen Controller
## Handles screen positioning, scaling, and attachment to camera

signal screen_moved
signal screen_scaled
signal screen_locked(is_locked: bool)

@export_group("References")
@export var screen_pivot_path: NodePath
@export var xr_camera_path: NodePath
@export var left_controller_path: NodePath
@export var right_controller_path: NodePath

@export_group("Screen Settings")
@export var default_distance: float = 2.5
@export var min_distance: float = 0.5
@export var max_distance: float = 10.0
@export var default_scale: float = 1.0
@export var min_scale: float = 0.3
@export var max_scale: float = 3.0
@export var default_height_offset: float = 0.0 # Relative to camera

@export_group("Input Sensitivity")
@export var distance_speed: float = 2.0 # Units per second
@export var scale_speed: float = 1.0 # Scale per second
@export var height_speed: float = 1.0 # Units per second
@export var move_smoothing: float = 10.0
@export var thumbstick_deadzone: float = 0.2

@export_group("Recenter")
@export var recenter_button: String = "menu_button" # Oculus/Menu button
@export var recenter_hold_time: float = 0.5

var _screen_pivot: Node3D
var _xr_camera: XRCamera3D
var _left_controller: XRController3D
var _right_controller: XRController3D

var _is_locked_to_camera: bool = false
var _is_grabbing: bool = false
var _grab_controller: XRController3D = null
var _grab_relative_transform: Transform3D = Transform3D.IDENTITY

var _current_distance: float
var _current_scale: float
var _current_height_offset: float
var _target_position: Vector3
var _target_rotation: Vector3

var _recenter_hold_timer: float = 0.0
var _pointer_over_screen: bool = false

func _ready() -> void:
	_screen_pivot = get_node_or_null(screen_pivot_path)
	_xr_camera = get_node_or_null(xr_camera_path)
	_left_controller = get_node_or_null(left_controller_path)
	_right_controller = get_node_or_null(right_controller_path)
	
	_current_distance = default_distance
	_current_scale = default_scale
	_current_height_offset = default_height_offset
	
	if _screen_pivot:
		_target_position = _screen_pivot.global_position
		_target_rotation = _screen_pivot.rotation
	
	print("[ScreenController] Initialized")
	print("[ScreenController] Screen pivot: ", _screen_pivot)
	print("[ScreenController] XR Camera: ", _xr_camera)

func _process(delta: float) -> void:
	if not _screen_pivot or not _xr_camera:
		return
	
	_handle_recenter_input(delta)
	_handle_grab_input(delta)
	_handle_thumbstick_input(delta)
	
	if _is_locked_to_camera:
		_update_locked_position(delta)
	elif _is_grabbing:
		_update_grab_position(delta)
	else:
		# Smooth movement to target
		_screen_pivot.global_position = _screen_pivot.global_position.lerp(_target_position, delta * move_smoothing)

func _handle_recenter_input(delta: float) -> void:
	# Check both controllers for menu/oculus button
	var recenter_pressed := false
	
	if _left_controller and _left_controller.is_button_pressed(recenter_button):
		recenter_pressed = true
	if _right_controller and _right_controller.is_button_pressed(recenter_button):
		recenter_pressed = true
	
	if recenter_pressed:
		_recenter_hold_timer += delta
		if _recenter_hold_timer >= recenter_hold_time:
			recenter_screen()
			_recenter_hold_timer = 0.0
	else:
		_recenter_hold_timer = 0.0

func _handle_grab_input(_delta: float) -> void:
	# Check if pointer is over screen (set by xr_pointer)
	if not _pointer_over_screen:
		if _is_grabbing:
			_end_grab()
		return
	
	# Check grip on right controller first, then left
	var controller_to_check := _right_controller
	if controller_to_check == null:
		controller_to_check = _left_controller
	
	if controller_to_check:
		var grip_val: float = controller_to_check.get_float("grip")
		var grip_pressed := grip_val > 0.7
		
		if grip_pressed and not _is_grabbing:
			_start_grab(controller_to_check)
		elif not grip_pressed and _is_grabbing and _grab_controller == controller_to_check:
			_end_grab()
	
	# Also check left controller if right is not grabbing
	if _left_controller and not _is_grabbing:
		var grip_val: float = _left_controller.get_float("grip")
		var grip_pressed := grip_val > 0.7
		if grip_pressed:
			_start_grab(_left_controller)

func _start_grab(controller: XRController3D) -> void:
	_is_grabbing = true
	_grab_controller = controller
	
	# Capture relative transform between controller and screen
	_grab_relative_transform = controller.global_transform.affine_inverse() * _screen_pivot.global_transform
	
	_is_locked_to_camera = false
	emit_signal("screen_locked", false)
	print("[ScreenController] Started grabbing screen (Pivot: Controller)")

func _end_grab() -> void:
	_is_grabbing = false
	_grab_controller = null
	_target_position = _screen_pivot.global_position
	print("[ScreenController] Ended grabbing screen")
	emit_signal("screen_moved")

func _update_grab_position(_delta: float) -> void:
	if _grab_controller and _screen_pivot:
		# Screen follows the controller's transform perfectly (position + rotation)
		_screen_pivot.global_transform = _grab_controller.global_transform * _grab_relative_transform
		_target_position = _screen_pivot.global_position
		
		# Removed _face_camera() during grab so the user has full rotation control

func _handle_thumbstick_input(delta: float) -> void:
	if not _right_controller:
		return
	
	# Get thumbstick values
	var thumbstick: Vector2 = _right_controller.get_vector2("primary")
	
	# Apply deadzone
	if abs(thumbstick.x) < thumbstick_deadzone:
		thumbstick.x = 0.0
	if abs(thumbstick.y) < thumbstick_deadzone:
		thumbstick.y = 0.0
	
	if thumbstick == Vector2.ZERO:
		return
	
	# Up/Down (Y axis) - controls distance from camera
	if abs(thumbstick.y) > 0:
		_current_distance -= thumbstick.y * distance_speed * delta
		_current_distance = clamp(_current_distance, min_distance, max_distance)
		_update_screen_position()
	
	# Left/Right (X axis) - controls scale
	if abs(thumbstick.x) > 0:
		_current_scale += thumbstick.x * scale_speed * delta
		_current_scale = clamp(_current_scale, min_scale, max_scale)
		_screen_pivot.scale = Vector3.ONE * _current_scale
		emit_signal("screen_scaled")

func _update_locked_position(_delta: float) -> void:
	_update_screen_position()

func _update_screen_position() -> void:
	if not _xr_camera or not _screen_pivot:
		return
	
	# Get camera forward direction (on XZ plane for stability)
	var cam_transform := _xr_camera.global_transform
	var forward := -cam_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	
	# Position screen in front of camera
	var target_pos := cam_transform.origin + forward * _current_distance
	target_pos.y = cam_transform.origin.y + _current_height_offset
	
	_target_position = target_pos
	
	if _is_locked_to_camera:
		_screen_pivot.global_position = target_pos
	
	_face_camera()

func _face_camera() -> void:
	if not _xr_camera or not _screen_pivot:
		return
	
	# Make screen face the camera
	var look_target := _xr_camera.global_position
	look_target.y = _screen_pivot.global_position.y # Keep upright
	_screen_pivot.look_at(look_target, Vector3.UP)
	_screen_pivot.rotate_y(PI) # Flip to face camera

func recenter_screen() -> void:
	print("[ScreenController] Recentering screen")
	_current_distance = default_distance
	_current_scale = default_scale
	_current_height_offset = default_height_offset
	_screen_pivot.scale = Vector3.ONE * _current_scale
	_update_screen_position()
	_screen_pivot.global_position = _target_position
	emit_signal("screen_moved")

func toggle_lock_to_camera() -> void:
	_is_locked_to_camera = not _is_locked_to_camera
	if _is_locked_to_camera:
		_update_screen_position()
	print("[ScreenController] Lock to camera: ", _is_locked_to_camera)
	emit_signal("screen_locked", _is_locked_to_camera)

func set_locked_to_camera(locked: bool) -> void:
	_is_locked_to_camera = locked
	if _is_locked_to_camera:
		_update_screen_position()
	emit_signal("screen_locked", _is_locked_to_camera)

func is_locked_to_camera() -> bool:
	return _is_locked_to_camera

func is_grabbing() -> bool:
	return _is_grabbing

func set_pointer_over_screen(is_over: bool) -> void:
	_pointer_over_screen = is_over

func adjust_distance(amount: float) -> void:
	_current_distance = clamp(_current_distance + amount, min_distance, max_distance)
	_update_screen_position()

func adjust_scale(amount: float) -> void:
	_current_scale = clamp(_current_scale + amount, min_scale, max_scale)
	_screen_pivot.scale = Vector3.ONE * _current_scale
	emit_signal("screen_scaled")

func adjust_height(amount: float) -> void:
	_current_height_offset += amount
	_update_screen_position()

func get_current_distance() -> float:
	return _current_distance

func get_current_scale() -> float:
	return _current_scale
