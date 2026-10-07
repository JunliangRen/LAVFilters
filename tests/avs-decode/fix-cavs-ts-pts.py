"""Assign this short AVS1 JiZhun fixture's PES PTS from picture_distance.

The picture header parser follows libavcodec/cavsdec.c: decode_pic(). This is
a fixture repair, not a general MPEG-TS or arbitrary CAVS stream processor.
It requires a unique complete set of picture distances without wraparound.
Compressed picture data, DTS, PCR and packet lengths remain unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
from importlib.util import spec_from_file_location, module_from_spec
spec = spec_from_file_location("fix_ts_pts", Path(__file__).with_name("fix-ts-pts.py"))
module = module_from_spec(spec)
spec.loader.exec_module(module)
read_pts, write_pts = module.read_pts, module.write_pts


class Bits:
    def __init__(self, data):
        self.data, self.position = data, 0

    def get(self, count):
        result = 0
        for _ in range(count):
            result = result * 2 + ((self.data[self.position // 8] >> (7 - self.position % 8)) & 1)
            self.position += 1
        return result

    def peek(self, count):
        old = self.position
        result = self.get(count)
        self.position = old
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("mapping_json")
    parser.add_argument("--fps", type=int, default=25)
    args = parser.parse_args()
    source = Path(args.source).read_bytes()
    if len(source) % 188 or 90000 % args.fps:
        raise ValueError("Expected 188-byte TS and integral timestamp tick")
    pictures, current = [], None
    for position in range(0, len(source), 188):
        packet = source[position:position + 188]
        if packet[0] != 0x47:
            raise ValueError("Invalid TS synchronization")
        if not packet[3] & 0x10:
            continue
        pid = ((packet[1] & 31) << 8) | packet[2]
        offset = 4 + (1 + packet[4] if packet[3] & 0x20 else 0)
        payload = packet[offset:]
        if packet[1] & 0x40:
            if payload[:3] == b"\x00\x00\x01" and 0xE0 <= payload[3] <= 0xEF:
                if not payload[7] & 0x80:
                    raise ValueError("Video packet has no PTS")
                current = {"pid": pid, "pts_location": position + offset + 9,
                           "old_pts": read_pts(payload[9:14]), "body": bytearray(payload[9 + payload[8]:])}
                pictures.append(current)
            elif current and pid == current["pid"]:
                raise ValueError("Unexpected non-video PES on video PID")
        elif current and pid == current["pid"]:
            current["body"].extend(payload)
    revision = 0
    for picture in pictures:
        body = picture.pop("body")
        candidates = [(body.find(b"\x00\x00\x01" + bytes([code])), code) for code in (0xB3, 0xB6)]
        candidates = [(position, code) for position, code in candidates if position >= 0]
        if len(candidates) != 1:
            raise ValueError("Each video PES must contain exactly one picture header")
        position, code = candidates[0]
        bits = Bits(body[position + 4:])
        bits.get(16)  # bbv_delay
        if code == 0xB6:
            picture["picture_type"] = ("I", "P", "B")[bits.get(2)]
        else:
            picture["picture_type"] = "I"
            if bits.get(1):
                bits.get(24)  # time_code
            # This official fixture is progressive and has low_delay=0.
            if not bits.peek(9) & 1 or bits.peek(11) & 3:
                revision = 1
            if revision:
                bits.get(1)  # marker_bit
        picture["picture_distance"] = bits.get(8)
    distances = [picture["picture_distance"] for picture in pictures]
    if sorted(distances) != list(range(len(pictures))):
        raise ValueError("Expected unique complete picture distances 0..N-1")
    base = pictures[0]["old_pts"]
    output = bytearray(source)
    for picture in pictures:
        location = picture["pts_location"]
        picture["new_pts"] = base + picture["picture_distance"] * (90000 // args.fps)
        output[location:location + 5] = write_pts(picture["new_pts"], source[location] & 0xF0)
    Path(args.output).write_bytes(output)
    report = {"frames": len(pictures), "source_sha256": hashlib.sha256(source).hexdigest(),
              "output_sha256": hashlib.sha256(output).hexdigest(), "compressed_es_unchanged": True,
              "mapping_basis": "AVS1 picture_distance parsed according to FFmpeg cavsdec.c decode_pic(); complete unique 0..N-1",
              "pictures": pictures}
    Path(args.mapping_json).write_bytes((json.dumps(report, indent=2).replace("\n", "\r\n") + "\r\n").encode())
    print(json.dumps({key: value for key, value in report.items() if key != "pictures"}))


if __name__ == "__main__":
    main()
