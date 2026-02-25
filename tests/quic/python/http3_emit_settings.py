from aioquic._buffer import Buffer
from aioquic.h3.connection import encode_settings

settings = {
    0x01: 0,
    0x06: 131072,
    0x07: 16,
    0x33: 1,
}
payload = encode_settings(settings)
buf = Buffer(capacity=64 + len(payload))
buf.push_uint_var(0x04)
buf.push_uint_var(len(payload))
buf.push_bytes(payload)
print("FRAMEHEX:" + bytes(buf.data).hex())
