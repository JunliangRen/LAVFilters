"""Repair stream-copy TS PTS from decoded display order without altering ES bytes.

Raw AVS2 demuxer PTS synthesis assigns timestamps in an unsuitable order for
the long B-frame chains in these fixtures. The decoder preserves each packet's
PTS in the returned frame, allowing a bijection between original packet tokens
and independently verified reconstruction/display order. Only PES PTS bytes
are changed; packet sizes, DTS, PCR, and compressed elementary data are kept.
"""
import argparse
import hashlib
import json
from pathlib import Path


def read_pts(data):
    return ((data[0] >> 1 & 7) << 30) | (data[1] << 22) | ((data[2] >> 1) << 15) | (data[3] << 7) | (data[4] >> 1)


def write_pts(value, prefix):
    return bytes((prefix | (((value >> 30) & 7) << 1) | 1,
                  (value >> 22) & 255, (((value >> 15) & 127) << 1) | 1,
                  (value >> 7) & 255, ((value & 127) << 1) | 1))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("frames_json")
    parser.add_argument("output")
    parser.add_argument("--fps", type=int, required=True)
    args = parser.parse_args()
    source = Path(args.source).read_bytes()
    text = Path(args.frames_json).read_text(encoding="utf-8-sig")
    # libdavs2 writes initialization messages to stdout ahead of ffprobe JSON.
    frames = json.loads(text[text.index('{'):])["frames"]
    tokens = [int(frame["pts"]) for frame in frames]
    if len(tokens) != len(set(tokens)) or not tokens or 90000 % args.fps:
        raise ValueError("A unique packet-to-display-frame PTS mapping is required")
    mapping = {token: tokens[0] + index * (90000 // args.fps) for index, token in enumerate(tokens)}
    output = bytearray(source)
    changed = 0
    seen = set()
    if len(source) % 188:
        raise ValueError("Expected 188-byte MPEG-TS packets")
    for position in range(0, len(source), 188):
        packet = source[position:position + 188]
        if packet[0] != 0x47:
            raise ValueError("Invalid TS synchronization")
        if not packet[1] & 0x40 or not packet[3] & 0x10:
            continue
        offset = 4 + (1 + packet[4] if packet[3] & 0x20 else 0)
        if packet[offset:offset + 3] != b"\x00\x00\x01" or not 0xE0 <= packet[offset + 3] <= 0xEF:
            continue
        if not packet[offset + 7] & 0x80 or offset + 14 > 188:
            raise ValueError("Expected in-packet video PES PTS")
        location = position + offset + 9
        old = read_pts(source[location:location + 5])
        if old not in mapping or old in seen:
            raise ValueError(f"Missing or duplicate packet PTS token {old}")
        seen.add(old)
        output[location:location + 5] = write_pts(mapping[old], source[location] & 0xF0)
        changed += mapping[old] != old
    if len(seen) != len(tokens):
        raise ValueError(f"Only mapped {len(seen)} of {len(tokens)} frames")
    Path(args.output).write_bytes(output)
    print(json.dumps({"frames": len(tokens), "changed_pts": changed,
                      "source_sha256": hashlib.sha256(source).hexdigest(),
                      "output_sha256": hashlib.sha256(output).hexdigest(),
                      "compressed_es_unchanged": True}))


if __name__ == "__main__":
    main()
