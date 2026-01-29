extends Node
## Test script to enumerate GoZenVideo methods

func _ready() -> void:
	print("=== Checking GoZenVideo API ===")
	
	if ClassDB.class_exists("GoZenVideo"):
		print("[OK] GoZenVideo class exists")
		
		# Get all methods
		var methods = ClassDB.class_get_method_list("GoZenVideo", true)
		print("\nGoZenVideo methods:")
		for method in methods:
			var params = []
			for arg in method.args:
				params.append("%s: %s" % [arg.name, type_string(arg.type)])
			print("  - %s(%s) -> %s" % [method.name, ", ".join(params), type_string(method.return.type)])
		
		# Check for buffer-related methods
		print("\n=== Looking for buffer decode methods ===")
		var buffer_methods = ["decode", "packet", "buffer", "data", "nal", "frame"]
		for method in methods:
			for keyword in buffer_methods:
				if keyword.to_lower() in method.name.to_lower():
					print("  FOUND: %s" % method.name)
					break
	else:
		print("[ERROR] GoZenVideo class not found!")
		print("Available classes with 'video' or 'gozen':")
		for cls in ClassDB.get_class_list():
			if "video" in cls.to_lower() or "gozen" in cls.to_lower():
				print("  - %s" % cls)
	
	# Also check AudioStreamFFmpeg
	if ClassDB.class_exists("AudioStreamFFmpeg"):
		print("\n[OK] AudioStreamFFmpeg class exists")
	else:
		print("\n[WARN] AudioStreamFFmpeg class not found")
	
	print("\n=== Done ===")
	get_tree().quit()
