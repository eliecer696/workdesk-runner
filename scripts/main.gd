extends Node3D

@onready var desktop_viewport: SubViewport = $DesktopViewport
@onready var screen_mesh: MeshInstance3D = $ScreenPivot/ScreenBody/Screen
@onready var status_label: Label = $DesktopViewport/DesktopUI/Status
@onready var desktop_client: Node = $DesktopClient
@onready var server_url_edit: LineEdit = get_node_or_null("DesktopViewport/DesktopUI/ConnectionPanel/ServerUrl") as LineEdit
@onready var connect_button: Button = get_node_or_null("DesktopViewport/DesktopUI/ConnectionPanel/ConnectButton") as Button
@onready var disconnect_button: Button = get_node_or_null("DesktopViewport/DesktopUI/ConnectionPanel/DisconnectButton") as Button

var _screen_material: StandardMaterial3D
var _cursor_sprite: Sprite3D
var _cursor_uv: Vector2 = Vector2(0.5, 0.5)
var _screen_size: Vector2 = Vector2(2.4, 1.35) # Must match the screen mesh size

func _ready() -> void:
	_setup_xr()
	_setup_screen_material()
	_setup_cursor()
	_wire_desktop_client()
	_setup_connection_ui()
	set_status("Desktop stream: not connected")

func set_status(text: String) -> void:
	if status_label:
		status_label.text = text

func _setup_xr() -> void:
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface:
		_apply_openxr_action_map(xr_interface)
		if xr_interface.initialize():
			get_viewport().use_xr = true
		else:
			push_warning("OpenXR not initialized; staying in non-XR mode.")
	else:
		push_warning("OpenXR interface not found.")

func _apply_openxr_action_map(xr_interface: XRInterface) -> void:
	var action_map_path := "res://openxr_action_map.tres"
	if not ResourceLoader.exists(action_map_path):
		return
	if xr_interface.has_method("set_action_map"):
		var action_map = load(action_map_path)
		xr_interface.call("set_action_map", action_map)

func _setup_screen_material() -> void:
	if not screen_mesh:
		return
	
	# Load YUV Shader
	var shader = load("res://shaders/yuv_shader.gdshader")
	if not shader:
		push_error("Failed to load yuv_shader.gdshader")
		return
		
	var material = ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("is_yuv", false) # Default to RGB
	
	if desktop_viewport:
		material.set_shader_parameter("yuv_tex", desktop_viewport.get_texture())
		
	screen_mesh.material_override = material
	print("[Main] Screen material setup with YUV shader")

func _setup_cursor() -> void:
	# Create cursor sprite as child of screen body
	var screen_body = get_node_or_null("ScreenPivot/ScreenBody")
	if not screen_body:
		return
	
	_cursor_sprite = Sprite3D.new()
	_cursor_sprite.name = "CursorSprite"
	
	# Create a simple cursor texture (white arrow)
	var cursor_image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	cursor_image.fill(Color(0, 0, 0, 0))
	# Draw arrow shape
	for y in range(24):
		for x in range(min(y + 1, 16)):
			cursor_image.set_pixel(x, y, Color.WHITE)
		# Arrow outline
		if y < 20:
			cursor_image.set_pixel(min(y + 1, 15), y, Color.BLACK)
	# Inner fill
	for y in range(1, 20):
		for x in range(1, min(y, 14)):
			cursor_image.set_pixel(x, y, Color.WHITE)
	
	var cursor_texture := ImageTexture.create_from_image(cursor_image)
	_cursor_sprite.texture = cursor_texture
	_cursor_sprite.pixel_size = 0.001 # Scale cursor appropriately
	_cursor_sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_cursor_sprite.position = Vector3(0, 0, 0.02) # Slightly in front of screen
	_cursor_sprite.modulate = Color(1, 1, 1, 1)
	
	screen_body.add_child(_cursor_sprite)
	print("[Main] Cursor sprite created")


func _wire_desktop_client() -> void:
	if not desktop_client:
		return
	if desktop_client.has_signal("frame_received"):
		desktop_client.connect("frame_received", Callable(self, "_on_frame_received"))
	if desktop_client.has_signal("cursor_received"):
		desktop_client.connect("cursor_received", Callable(self, "_on_cursor_received"))
	if desktop_client.has_signal("status_changed"):
		desktop_client.connect("status_changed", Callable(self, "_on_status_changed"))

func _setup_connection_ui() -> void:
	if server_url_edit and desktop_client:
		var current = str(desktop_client.get("server_url"))
		if current != "":
			server_url_edit.text = current
	if connect_button:
		connect_button.pressed.connect(_on_connect_pressed)
	if disconnect_button:
		disconnect_button.pressed.connect(_on_disconnect_pressed)
	if server_url_edit:
		server_url_edit.text_submitted.connect(func(_text: String) -> void:
			_on_connect_pressed()
		)

func _apply_server_url() -> void:
	if not desktop_client or not server_url_edit:
		return
	desktop_client.set("server_url", server_url_edit.text.strip_edges())

func _on_connect_pressed() -> void:
	_apply_server_url()
	if desktop_client and desktop_client.has_method("connect_to_server"):
		desktop_client.call("connect_to_server")

func _on_disconnect_pressed() -> void:
	if desktop_client and desktop_client.has_method("disconnect_from_server"):
		desktop_client.call("disconnect_from_server")

var _display_frame_count := 0

func _on_frame_received(texture: Texture2D, is_yuv: bool) -> void:
	_display_frame_count += 1
	if _display_frame_count % 60 == 1:
		print("[Main] Displaying frame #", _display_frame_count, " tex: ", texture.get_width(), "x", texture.get_height(), " YUV:", is_yuv)
	
	if screen_mesh.material_override is ShaderMaterial:
		var mat = screen_mesh.material_override as ShaderMaterial
		mat.set_shader_parameter("yuv_tex", texture)
		mat.set_shader_parameter("is_yuv", is_yuv)

func _on_cursor_received(uv: Vector2) -> void:
	_cursor_uv = uv
	if _cursor_sprite:
		# Convert UV (0-1) to local position on screen
		var local_x := (uv.x - 0.5) * _screen_size.x
		var local_y := (0.5 - uv.y) * _screen_size.y # Flip Y
		_cursor_sprite.position = Vector3(local_x, local_y, 0.02)

func _on_status_changed(text: String) -> void:
	set_status(text)
