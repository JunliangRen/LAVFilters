"""Remove H264 timing or construct MPEG2 soft telecine without changing pixels."""
import argparse
import json
import pathlib
import re


class Bits:
    def __init__(self, data):
        self.bits = ''.join(f'{value:08b}' for value in data)
        self.pos = 0

    def read(self, count=1):
        value = int(self.bits[self.pos:self.pos + count], 2)
        self.pos += count
        return value

    def ue(self):
        zeros = 0
        while not self.read():
            zeros += 1
        return (1 << zeros) - 1 + (self.read(zeros) if zeros else 0)

    def se(self):
        value = self.ue()
        return (value + 1) // 2 if value & 1 else -(value // 2)


def remove_timing(nalu):
    rbsp = nalu[:1] + re.sub(b'\x00\x00\x03', b'\x00\x00', nalu[1:])
    bits = Bits(rbsp[1:])
    profile = bits.read(8)
    bits.read(16)
    bits.ue()
    if profile in (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135):
        chroma = bits.ue()
        if chroma == 3:
            bits.read()
        bits.ue(); bits.ue(); bits.read()
        if bits.read():
            for index in range(12 if chroma == 3 else 8):
                if bits.read():
                    previous = current = 8
                    for _ in range(16 if index < 6 else 64):
                        if current:
                            current = (previous + bits.se() + 256) % 256
                        previous = current or previous
    bits.ue()
    order = bits.ue()
    if order == 0:
        bits.ue()
    elif order == 1:
        bits.read(); bits.se(); bits.se()
        for _ in range(bits.ue()):
            bits.se()
    bits.ue(); bits.read(); bits.ue(); bits.ue()
    if not bits.read():
        bits.read()
    bits.read()
    if bits.read():
        for _ in range(4):
            bits.ue()
    if not bits.read():
        raise ValueError('Expected VUI parameters in input SPS')
    if bits.read():
        if bits.read(8) == 255:
            bits.read(32)
    if bits.read():
        bits.read()
    if bits.read():
        bits.read(4)
        if bits.read():
            bits.read(24)
    if bits.read():
        bits.ue(); bits.ue()
    start = bits.pos
    if not bits.read():
        raise ValueError('Input SPS already has no timing information')
    units, scale, fixed = bits.read(32), bits.read(32), bits.read()
    result = bits.bits[:start] + '0' + bits.bits[bits.pos:]
    # RBSP trailing alignment changes by 65 bits. Remove the old zero padding,
    # retain the stop bit, and align it to a byte again.
    result = result.rstrip('0')
    result += '0' * (-len(result) % 8)
    data = bytes(int(result[index:index + 8], 2) for index in range(0, len(result), 8))
    escaped = bytearray(); zeros = 0
    for value in data:
        if zeros >= 2 and value <= 3:
            escaped.append(3); zeros = 0
        escaped.append(value)
        zeros = zeros + 1 if value == 0 else 0
    return nalu[:1] + escaped, {'num_units_in_tick': units, 'time_scale': scale, 'fixed': fixed, 'timing_info_present': False}


def set_bit(data, start, offset, value):
    byte = start + offset // 8
    mask = 1 << (7 - offset % 8)
    data[byte] = (data[byte] | mask) if value else (data[byte] & ~mask)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('h264-no-timing', 'h264-mp4-no-timing', 'mpeg2-soft-telecine', 'mpeg2-progressive-repeat'))
    parser.add_argument('source', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('metadata', type=pathlib.Path)
    parser.add_argument('--fixed-tff', action='store_true')
    args = parser.parse_args()
    data = args.source.read_bytes()
    records = []
    if args.mode == 'h264-mp4-no-timing':
        data = bytearray(data)
        for match in re.finditer(b'avcC\x01', data):
            start = match.start() + 4
            box_size = int.from_bytes(data[match.start() - 4:match.start()], 'big')
            if box_size < 15 or match.start() + box_size - 4 > len(data):
                raise ValueError('Invalid avcC atom bounds')
            position = start + 6
            for _ in range(data[start + 5] & 31):
                length = int.from_bytes(data[position:position + 2], 'big')
                position += 2
                original = bytes(data[position:position + length])
                replacement, record = remove_timing(original)
                if len(replacement) > length:
                    raise ValueError('Replacement SPS exceeds original avcC size')
                # Zero-valued NAL trailing bytes keep every MP4 atom size and
                # chunk offset unchanged. Original packet PTS/CTS remain intact.
                data[position:position + length] = replacement + b'\x00' * (length - len(replacement))
                position += length
                records.append(record)
        if not records:
            raise ValueError('No avcC SPS found')
    elif args.mode == 'h264-no-timing':
        chunks = re.split(b'(\x00\x00\x00\x01|\x00\x00\x01)', data)
        for index in range(2, len(chunks), 2):
            if chunks[index] and chunks[index][0] & 31 == 7:
                chunks[index], record = remove_timing(chunks[index])
                records.append(record)
        if not records:
            raise ValueError('No SPS found')
        data = b''.join(chunks)
    else:
        data = bytearray(data)
        picture = -1
        for match in re.finditer(b'\x00\x00\x01.', data):
            start, code = match.start() + 4, match.group()[3]
            if code == 0x00:
                picture += 1
            if code != 0xB5:
                continue
            kind = data[start] >> 4
            if kind == 1:
                set_bit(data, start, 12, int(args.mode == 'mpeg2-progressive-repeat'))
            elif kind == 8:
                # frame pictures remain independently decodable progressive
                # images. Alternate repeat_first_field creates 3:2 display.
                repeat = int(picture % 2 == 0)
                set_bit(data, start, 24, 1 if args.fixed_tff else int(((picture + 1) // 2) % 2 == 0))
                set_bit(data, start, 30, repeat)
                set_bit(data, start, 31, 1)
                set_bit(data, start, 32, 1)
                records.append({'coded_picture': picture, 'progressive_sequence': args.mode == 'mpeg2-progressive-repeat', 'progressive_frame': True, 'repeat_first_field': repeat})
        if not records or not any(item['repeat_first_field'] for item in records):
            raise ValueError('No soft telecine picture extensions found')
    args.output.write_bytes(data)
    args.metadata.write_bytes((json.dumps({'mode': args.mode, 'records': records}, indent=2).replace('\n', '\r\n') + '\r\n').encode())


if __name__ == '__main__':
    main()
