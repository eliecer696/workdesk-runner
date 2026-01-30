extends Node3D
## 3D UI Panel for Screen Controls
## Displays buttons above the screen for lock, scale, and height adjustments

@export var screen_controller_path: NodePath
@export var button_spacing: float = 0.15
@export var panel_height_offset: float = 0.55 # Above the screen

var _screen_controller: Node
var _buttons: Array[Dictionary] = []
var _hovered_button: int = -1

# Button definitions
const BUTTON_LOCK := 0
const BUTTON_SCALE_DOWN := 1
const BUTTON_SCALE_UP := 2
const BUTTON_HEIGHT_DOWN := 3
const BUTTON_HEIGHT_UP := 4
const BUTTON_RECENTER := 5

const ICON_PATH := "res://Icons/"

func _ready() -> void:
	_screen_controller = get_node_or_null(screen_controller_path)
	add_to_group("screen_ui_panel")
	_create_buttons()
	print("[ScreenUI] Panel initialized")

func _create_buttons() -> void:
	var button_data := [
		{"icon": "vr_unselected.png", "label": "Lock", "action": "toggle_lock"},
		{"icon": "eye_unselected.png", "label": "Scale-", "action": "scale_down"},
		{"icon": "eye_selected.png", "label": "Scale+", "action": "scale_up"},
		{"icon": "user.png", "label": "Down", "action": "height_down"},
		{"icon": "menue.png", "label": "Up", "action": "height_up"},
		{"icon": "home.png", "label": "Center", "action": "recenter"},
	]
	
	var total_width := button_data.size() * button_spacing
	var start_x := -total_width / 2.0 + button_spacing / 2.0
	
	for i in range(button_data.size()):
		var btn_info: Dictionary = button_data[i]
		var btn_node := _create_button_mesh(btn_info["label"], btn_info["icon"])
		btn_node.position = Vector3(start_x + i * button_spacing, panel_height_offset, 0)
		add_child(btn_node)
		
		_buttons.append({
			"node": btn_node,
			"action": btn_info["action"],
			"label": btn_info["label"],
			"idle_icon": btn_info["icon"]
		})

func _create_button_mesh(label: String, icon_file: String) -> Node3D:
	var button_root := Node3D.new()
	button_root.name = "Button_" + label.replace(" ", "_")
	
	# Button background (box)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "ButtonMesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(0.12, 0.08, 0.01) # Slightly taller for icons
	mesh_instance.mesh = box_mesh
	
	# Material
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.15, 0.15, 0.2, 0.9)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true # ALWAYS on top of screen
	material.render_priority = 10 # Draw after screen
	mesh_instance.material_override = material
	
	button_root.add_child(mesh_instance)
	
	# Collision for raycasting
	var static_body := StaticBody3D.new()
	static_body.name = "ButtonBody"
	static_body.add_to_group("ui_button")
	static_body.set_meta("button_label", label)
	
	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(0.12, 0.05, 0.02)
	collision.shape = box_shape
	static_body.add_child(collision)
	
	button_root.add_child(static_body)
	
	# Icon using Sprite3D
	var sprite_3d := Sprite3D.new()
	sprite_3d.name = "Icon"
	sprite_3d.texture = load(ICON_PATH + icon_file)
	sprite_3d.pixel_size = 0.0005 # Scale it to fit
	sprite_3d.position = Vector3(0, 0, 0.01)
	sprite_3d.no_depth_test = true
	sprite_3d.render_priority = 11
	
	button_root.add_child(sprite_3d)
	
	return button_root

func handle_button_press(button_label: String) -> void:
	match button_label:
		"Lock":
			if _screen_controller and _screen_controller.has_method("toggle_lock_to_camera"):
				_screen_controller.toggle_lock_to_camera()
				_update_lock_button_state()
		"Scale-":
			if _screen_controller and _screen_controller.has_method("adjust_scale"):
				_screen_controller.adjust_scale(-0.1)
		"Scale+":
			if _screen_controller and _screen_controller.has_method("adjust_scale"):
				_screen_controller.adjust_scale(0.1)
		"Down":
			if _screen_controller and _screen_controller.has_method("adjust_height"):
				_screen_controller.adjust_height(-0.1)
		"Up":
			if _screen_controller and _screen_controller.has_method("adjust_height"):
				_screen_controller.adjust_height(0.1)
		"Center":
			if _screen_controller and _screen_controller.has_method("recenter_screen"):
				_screen_controller.recenter_screen()

func _update_lock_button_state() -> void:
	if _buttons.is_empty():
		return
	
	var is_locked := false
	if _screen_controller and _screen_controller.has_method("is_locked_to_camera"):
		is_locked = _screen_controller.is_locked_to_camera()
	
	var lock_btn: Dictionary = _buttons[BUTTON_LOCK]
	
	# Update Icon
	var icon_node: Sprite3D = lock_btn["node"].get_node("Icon")
	if icon_node:
		var icon_file := "vr_selected.png" if is_locked else "vr_unselected.png"
		icon_node.texture = load(ICON_PATH + icon_file)
	
	# Update color
	var mesh: MeshInstance3D = lock_btn["node"].get_node("ButtonMesh")
	if mesh and mesh.material_override:
		var mat: StandardMaterial3D = mesh.material_override
		if is_locked:
			mat.albedo_color = Color(0.2, 0.5, 0.3, 0.9) # Green when locked
		else:
			mat.albedo_color = Color(0.15, 0.15, 0.2, 0.9) # Default

func set_button_hovered(button_label: String, is_hovered: bool) -> void:
	for i in range(_buttons.size()):
		var btn: Dictionary = _buttons[i]
		if btn["label"] == button_label:
			var mesh: MeshInstance3D = btn["node"].get_node("ButtonMesh")
			if mesh and mesh.material_override:
				var mat: StandardMaterial3D = mesh.material_override
				if is_hovered:
					mat.emission_enabled = true
					mat.emission = Color(0.3, 0.5, 0.8)
				else:
					mat.emission_enabled = false
			break
