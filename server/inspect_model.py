import torch

# 1. โหลดไฟล์โมเดลของคุณ
model_path = "models/best_model_2_9_26.pt"
checkpoint = torch.load(model_path, map_location='cpu', weights_only=False)

print("--- Keys in .pt file ---")
print(checkpoint.keys())

# 2. ปริ้นชื่อ Layer ในโมเดลของคุณออกมาดู
if 'model_state_dict' in checkpoint:
    print("\n--- Layers in your model ---")
    state_dict = checkpoint['model_state_dict']
    
    # ปริ้นชื่อ layer ทั้งหมดออกมาดู (เพื่อเอาไปเทียบกับ lip_model.py)
    for i, key in enumerate(state_dict.keys()):
        print(key)
        if i >= 15:
            break
else:
    print("\n⚠️ No model_state_dict found!")
