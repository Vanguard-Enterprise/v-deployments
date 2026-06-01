import os, base64
print(base64.b64encode(os.urandom(64)).decode()) 
# this makes a code
