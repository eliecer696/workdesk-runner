extends Node

func _ready():
    print("--- H264Decoder Extension Validation ---")
    
    if ClassDB.class_exists("H264Decoder"):
        print("[OK] H264Decoder class is registered in Godot.")
        
        var decoder = ClassDB.instantiate("H264Decoder")
        if decoder:
            print("[OK] H264Decoder successfully instantiated.")
            
            # Check methods
            var methods = ClassDB.class_get_method_list("H264Decoder")
            var method_names = []
            for m in methods:
                method_names.append(m.name)
            
            print("Available methods: ", method_names)
            
            if "decode_frame" in method_names:
                print("[OK] decode_frame method found.")
            else:
                print("[ERROR] decode_frame method NOT found!")
                
            if "get_width" in method_names and "get_height" in method_names:
                print("[OK] Resolution getter methods found.")
            else:
                print("[ERROR] Resolution getter methods NOT found!")
        else:
            print("[ERROR] Failed to instantiate H264Decoder despite class existing.")
    else:
        print("[ERROR] H264Decoder class not found.")
        print("Check if you have placed the .so/.dll files in addons/h264_decoder/bin/ and restarted Godot.")

    print("---------------------------------------")
    get_tree().quit()
