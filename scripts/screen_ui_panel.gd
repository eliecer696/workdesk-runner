extends Node3D
## 3D UI Panel for Screen Controls
## Displays buttons above the screen for lock, scale, and height adjustments

@export var screen_controller_path: NodePath
@export var button_spacing: float = 0.15
@export var panel_height_offset: float = 0.55  # Above the screen

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

func _ready() -> void:
	_screen_controller = get_node_or_null(screen_controller_path)
	add_to_group("screen_ui_panel")
	_create_buttons()
	print("[ScreenUI] Panel initialized")

func _create_buttons() -> void:
	var button_data := [
		{"icon": "🔒", "label": "Lock", "action": "toggle_lock"},
		{"icon": "−", "label": "Scale-", "action": "scale_down"},
		{"icon": "+", "label": "Scale+", "action": "scale_up"},
		{"icon": "↓", "label": "Down", "action": "height_down"},
		{"icon": "↑", "label": "Up", "action": "height_up"},
		{"icon": "⌂", "label": "Center", "action": "recenter"},
	]
	
	var total_width := button_data.size() * button_spacing
	var start_x := -total_width / 2.0 + button_spacing / 2.0
	
	for i in range(button_data.size()):
		var btn_info: Dictionary = button_data[i]
		var btn_node := _create_button_mesh(btn_info["label"])
		btn_node.position = Vector3(start_x + i * button_spacing, panel_height_offset, 0)
		add_child(btn_node)
		
		_buttons.append({
			"node": btn_node,
			"action": btn_info["action"],
			"label": btn_info["label"]
		})

func _create_button_mesh(label: String) -> Node3D:
	var button_root := Node3D.new()
	button_root.name = "Button_" + label.replace(" ", "_")
	
	# Button background (box)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "ButtonMesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(0.12, 0.05, 0.01)
	mesh_instance.mesh = box_mesh
	
	# Material
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.15, 0.15, 0.2, 0.9)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
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
	
	# Label using Label3D
	var label_3d := Label3D.new()
	label_3d.name = "Label"
	label_3d.text = label
	label_3d.font_size = 32
	label_3d.position = Vector3(0, 0, 0.01)
	label_3d.modulate = Color.WHITE
	label_3d.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label_3d.no_depth_test = true
	
	button_root.add_child(label_3d)
	
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
	var mesh: MeshInstance3D = lock_btn["node"].get_node("ButtonMesh")
	if mesh and mesh.material_override:
		var mat: StandardMaterial3D = mesh.material_override
		if is_locked:
			mat.albedo_color = Color(0.2, 0.5, 0.3, 0.9)  # Green when locked
		else:
			mat.albedo_color = Color(0.15, 0.15, 0.2, 0.9)  # Default

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
