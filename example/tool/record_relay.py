#!/usr/bin/env python3
"""Receives raw RGBA frames from the feature-tour test and encodes an MP4.

    python3 tool/record_relay.py out.mp4 &
    flutter test integration_test/feature_tour_test.dart -d macos \
        --dart-define=RECORD_PORT=9777

Stream format: a 12-byte header (width, height, fps as little-endian
uint32), then per captured frame a uint32 repeat count followed by
width*height*4 RGBA bytes. Frames are repeated to keep a constant rate.
"""
import socket
import struct
import subprocess
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "tour.mp4"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 9777

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(1)
print(f"relay listening on {port}", flush=True)
conn, _ = server.accept()


def read_exact(n):
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


width, height, fps = struct.unpack("<III", read_exact(12))
print(f"receiving {width}x{height} @ {fps} fps", flush=True)
ffmpeg = subprocess.Popen(
    [
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{width}x{height}",
        "-r", str(fps), "-i", "-",
        "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "14",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", out,
    ],
    stdin=subprocess.PIPE,
)
frame = width * height * 4
frames = 0
while True:
    count = read_exact(4)
    data = read_exact(frame) if count else None
    if data is None:
        break
    for _ in range(struct.unpack("<I", count)[0]):
        ffmpeg.stdin.write(data)
        frames += 1
ffmpeg.stdin.close()
ffmpeg.wait()
print(f"wrote {out}: {frames} frames ({frames / fps:.1f}s)", flush=True)
