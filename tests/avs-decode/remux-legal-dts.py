"""Remux one short, display-PTS-repaired AVS TS fixture with legal coding DTS.

Uses an existing complete FFmpeg runtime: setts modifies packet timestamps and
libavformat regenerates MPEG-TS PES/PCR. Compressed packet bytes and coding order
must match exactly before and after remuxing. This is fixture preparation, not a
general repair for broadcast recordings or mixed audio/video input.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


def run(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            encoding="utf-8", errors="replace", timeout=300)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0]}\n{result.stderr[-4000:]}")
    return result.stdout


def probe(ffprobe, path):
    text = run([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_packets",
                "-show_streams", "-show_data_hash", "sha256", "-show_entries",
                "packet=pts,dts,duration,size,data_hash:stream=time_base",
                "-of", "compact=p=0", str(path)])
    packets, time_bases = [], []
    for line in text.splitlines():
        # libdavs2 may print initialization messages to stdout before packet data.
        if line.startswith("time_base="):
            time_bases.append(line.split("|", 1)[0].split("=", 1)[1])
            continue
        if not line.startswith("pts="):
            continue
        values = dict(field.split("=", 1) for field in line.split("|") if "=" in field)
        digest = values.get("data_hash", "").removeprefix("SHA256:")
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"Missing packet SHA256 in {path}")
        packet = {key: int(values[key]) if values.get(key, "N/A") != "N/A" else None
                  for key in ("pts", "dts", "duration", "size")}
        if packet["pts"] is None or packet["size"] is None or packet["size"] <= 0:
            raise ValueError(f"Every video packet needs display PTS and compressed data: {path}")
        packet["data_sha256"] = digest
        packets.append(packet)
    # ffprobe may repeat a stream in its enclosing MPEG-TS program section.
    if set(time_bases) != {"1/90000"} or not packets:
        raise ValueError(f"Expected one selected video stream with time_base 1/90000: {path}")
    return packets


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def es_hash(ffmpeg, path, output):
    # Decoder-library stdout messages must never enter the compressed ES hash.
    run([ffmpeg, "-v", "error", "-nostdin", "-hide_banner", "-i", str(path),
         "-map", "0:v:0", "-c", "copy", "-f", "data", "-n", str(output)])
    return file_hash(output)


def pcr_stats(path):
    data = path.read_bytes()
    if len(data) % 188:
        raise ValueError(f"Expected 188-byte MPEG-TS packets: {path}")
    streams = {}
    for offset in range(0, len(data), 188):
        packet = data[offset:offset + 188]
        if packet[0] != 0x47:
            raise ValueError(f"Invalid TS synchronization at {offset}: {path}")
        if not packet[3] & 0x20 or packet[4] < 7 or not packet[5] & 0x10:
            continue
        pid = ((packet[1] & 31) << 8) | packet[2]
        base = (packet[6] << 25) | (packet[7] << 17) | (packet[8] << 9) | \
               (packet[9] << 1) | (packet[10] >> 7)
        extension = ((packet[10] & 1) << 8) | packet[11]
        ticks = base * 300 + extension
        stream = streams.setdefault(str(pid), {"count": 0, "first_ticks": ticks,
                                              "last_ticks": ticks, "regressions": 0})
        if stream["count"] and ticks < stream["last_ticks"]:
            stream["regressions"] += 1
        stream["count"] += 1
        stream["last_ticks"] = ticks
    return {"time_base": "1/27000000", "pids": streams,
            "count": sum(stream["count"] for stream in streams.values()),
            "regressions": sum(stream["regressions"] for stream in streams.values())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--fps", type=int, required=True)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.fps <= 0 or 90000 % args.fps:
        raise ValueError("FPS must be positive and divide the 90000-Hz TS time base")
    if args.output.exists() or args.report.exists():
        raise ValueError("Output or report already exists; refusing to overwrite fixture evidence")
    if args.output.resolve() == args.report.resolve():
        raise ValueError("Output and report must be different files")
    before = probe(args.ffprobe, args.input)
    step = 90000 // args.fps
    first_pts = before[0]["pts"]
    lead = max(index * step + first_pts - packet["pts"]
               for index, packet in enumerate(before)) + step
    expected_dts = [index * step + first_pts - lead for index in range(len(before))]
    if any(dts > packet["pts"] for dts, packet in zip(expected_dts, before)):
        raise ValueError("Synthesized coding DTS exceeds display PTS")
    expression = f"setts=pts=PTS:dts=N*{step}+STARTPTS-{lead}:duration={step}:time_base=1/90000"
    run([args.ffmpeg, "-v", "error", "-nostdin", "-hide_banner", "-copyts",
         "-i", str(args.input), "-map", "0:v:0", "-c:v", "copy", "-bsf:v", expression,
         "-muxdelay", "0", "-muxpreload", "0", "-mpegts_copyts", "1",
         "-avoid_negative_ts", "disabled", "-f", "mpegts", "-n", str(args.output)])
    after = probe(args.ffprobe, args.output)
    if len(after) != len(before):
        raise ValueError("Remux changed the video packet count")
    if [packet["pts"] for packet in after] != [packet["pts"] for packet in before]:
        raise ValueError("Remux changed display PTS")
    if [packet["dts"] for packet in after] != expected_dts:
        raise ValueError("Remux changed the requested coding DTS")
    if any(packet["dts"] > packet["pts"] for packet in after):
        raise ValueError("Remuxed DTS exceeds PTS")
    if any(after[index]["dts"] <= after[index - 1]["dts"] for index in range(1, len(after))):
        raise ValueError("Remuxed DTS does not strictly increase")
    if any(packet["duration"] != step for packet in after):
        raise ValueError("Remuxed packet duration differs from the frame period")
    if [(packet["size"], packet["data_sha256"]) for packet in after] != \
            [(packet["size"], packet["data_sha256"]) for packet in before]:
        raise ValueError("Remux changed compressed packet bytes or coding order")
    # Keep child-process files beside the explicitly named output: the sandbox's
    # private TEMP directory may be inaccessible to an external FFmpeg process.
    with tempfile.TemporaryDirectory(prefix="lav-avs-legal-dts-",
                                     dir=args.output.parent.resolve()) as directory:
        temporary = Path(directory)
        input_es = es_hash(args.ffmpeg, args.input, temporary / "input.es")
        output_es = es_hash(args.ffmpeg, args.output, temporary / "output.es")
    if input_es != output_es:
        raise ValueError("Remux changed cumulative video ES SHA256")
    input_pcr = pcr_stats(args.input)
    output_pcr = pcr_stats(args.output)
    if not output_pcr["count"] or output_pcr["regressions"]:
        raise ValueError("Remuxed TS needs PCR with no regression on each PCR PID")
    report = {
        "input": str(args.input.resolve()), "output": str(args.output.resolve()),
        "fps": args.fps, "frames": len(after), "time_base": "1/90000",
        "step_ticks": step, "lead_ticks": lead, "first_pts": first_pts,
        "first_dts": after[0]["dts"], "last_dts": after[-1]["dts"],
        "source_sha256": file_hash(args.input), "output_sha256": file_hash(args.output),
        "input_video_es_sha256": input_es, "output_video_es_sha256": output_es,
        "compressed_es_unchanged": True, "packet_bytes_and_order_unchanged": True,
        "display_pts_unchanged": True, "dts_strictly_monotonic": True,
        "dts_not_after_pts": True, "packet_duration_ticks": step,
        "input_pcr": input_pcr, "output_pcr": output_pcr,
        "output_pcr_present_and_monotonic": True,
        "timestamp_expression": expression,
    }
    args.report.write_bytes((json.dumps(report, indent=2).replace("\n", "\r\n") + "\r\n").encode("utf-8"))
    print(json.dumps(report))


if __name__ == "__main__":
    main()
