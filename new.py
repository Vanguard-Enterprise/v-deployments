import os
import base64

def generate_zitadel_master_key():
    key_bytes = os.urandom(32)  # 32 bytes = 256 bits
    key_base64 = base64.b64encode(key_bytes).decode('utf-8')
    print("Master Key (Raw Bytes):", key_bytes)
    print("Master Key (Base64):", key_base64)

generate_zitadel_master_key()
