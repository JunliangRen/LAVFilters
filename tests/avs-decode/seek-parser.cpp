// SPDX-License-Identifier: GPL-2.0-or-later
// Standalone metadata/closure tests. No decoder, media files, or registration.
#include "../../demuxer/Demuxers/AVS2SeekParser.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

namespace
{
struct Writer
{
    std::vector<unsigned> bits;

    void Put(uint32_t value, unsigned count)
    {
        while (count) bits.push_back((value >> --count) & 1);
    }
    void UE(unsigned value)
    {
        const unsigned code = value + 1;
        unsigned zeros = 0;
        for (unsigned v = code; v > 1; v >>= 1) ++zeros;
        Put(0, zeros);
        Put(code, zeros + 1);
    }
    std::vector<uint8_t> Bytes(bool protect = false) const
    {
        std::vector<uint8_t> out;
        std::size_t position = 0;
        unsigned zeros = 0;
        while (position < bits.size())
        {
            bool escape = protect && zeros == 2;
            for (unsigned j = 0; j < 6 && escape; ++j)
                if (position + j < bits.size() && bits[position + j]) escape = false;
            const unsigned count = escape ? 6 : 8;
            unsigned value = 0;
            for (unsigned j = 0; j < count; ++j)
                value = (value << 1) | (position < bits.size() ? bits[position++] : 0);
            // AVS2 pseudo-code appends two marker bits after six zero bits.
            if (escape) value = (value << 2) | 2;
            out.push_back(static_cast<uint8_t>(value));
            zeros = value == 0 ? zeros + 1 : 0;
        }
        return out;
    }
};

void Unit(std::vector<uint8_t> &packet, unsigned code, const std::vector<uint8_t> &payload)
{
    packet.insert(packet.end(), {0, 0, 1, static_cast<uint8_t>(code)});
    packet.insert(packet.end(), payload.begin(), payload.end());
}

std::vector<uint8_t> Sequence(bool background = false, bool weightedBad = false,
                              unsigned rpsCount = 1, bool field = false, unsigned width = 3840)
{
    Writer b;
    b.Put(0x22, 8); b.Put(0x66, 8); // Main10 profile and level
    b.Put(1, 1); b.Put(field, 1); b.Put(width, 14); b.Put(2160, 14);
    b.Put(1, 2); b.Put(2, 3); b.Put(2, 3); // 4:2:0, sample/internal precision
    b.Put(1, 4); b.Put(6, 4); b.Put(0, 18); b.Put(1, 1); b.Put(0, 12);
    b.Put(0, 1); b.Put(1, 1); b.Put(0, 1); b.Put(0, 18); b.Put(6, 3);
    b.Put(weightedBad, 1);
    if (weightedBad)
    {
        b.Put(1, 1); b.UE(65536);
        for (unsigned i = 1; i < 80; ++i) b.UE(1);
    }
    b.Put(!background, 1); b.Put(0, 10); b.Put(1, 1); b.Put(rpsCount, 6);
    for (unsigned i = 0; i < rpsCount; ++i)
    {
        b.Put(1, 1); b.Put(0, 3); b.Put(0, 3); b.Put(1, 1);
    }
    b.Put(0, 5); b.Put(1, 1); b.Put(0, 2);
    return b.Bytes();
}

std::vector<uint8_t> Picture(unsigned coi, bool intra = true,
                             std::vector<unsigned> references = {}, int index = 0,
                             bool rpsMarker = true)
{
    Writer b;
    b.Put(0, 32);
    if (intra) b.Put(0, 1); else b.Put(1, 2);
    b.Put(coi, 8); b.UE(0); b.Put(index >= 0, 1);
    if (index >= 0) b.Put(static_cast<unsigned>(index), 5);
    else
    {
        b.Put(1, 1); b.Put(static_cast<unsigned>(references.size()), 3);
        for (unsigned delta : references) b.Put(delta, 6);
        b.Put(0, 3); b.Put(rpsMarker, 1);
    }
    b.Put(1, 1); b.Put(0, 2); b.Put(1, 1); b.Put(20, 7); b.Put(1, 1); b.Put(1, 1);
    return b.Bytes(true);
}

std::vector<uint8_t> Packet(const std::vector<uint8_t> &sequence,
                            const std::vector<uint8_t> &picture, unsigned code = 0xb3)
{
    std::vector<uint8_t> packet;
    if (!sequence.empty()) Unit(packet, 0xb0, sequence);
    Unit(packet, code, picture);
    Unit(packet, 0, {0x80}); // A complete packet needs a slice after its header.
    return packet;
}

unsigned tests = 0;
void Check(bool passed, const char *name)
{
    std::printf("%s %s\n", passed ? "PASS" : "FAIL", name);
    if (!passed) std::exit(1);
    ++tests;
}
} // namespace

int main()
{
    AVS2SeekParser parser;
    AVS2SeekParser::Picture p;
    const auto sequence = Sequence(), picture = Picture(26), packet = Packet(sequence, picture);
    const auto Parse = [&](const std::vector<uint8_t> &bytes)
    {
        return parser.ParsePacket(bytes.data(), bytes.size(), p);
    };
    Check(Parse(packet) && p.restartCandidate && p.coi == 26 && p.refCount == 0,
          "protected 00-00-02 picture header and SPS-selected RPS");
    bool hasEscape = false;
    for (std::size_t i = 0; i + 2 < picture.size(); ++i)
        if (!picture[i] && !picture[i + 1] && picture[i + 2] == 2) hasEscape = true;
    Check(hasEscape, "synthetic picture exercises pseudo-code removal");
    Check(Parse(Packet({}, Picture(27, false, {1}, -1), 0xb6)) && !p.intra &&
              p.refCount == 1 && p.refDeltas[0] == 1 && !p.hasSequence,
          "retained SPS and inline inter RPS");
    Check(Parse(Packet(sequence, Picture(26, true, {1}, -1))) && !p.restartCandidate && p.refCount == 1,
          "intra picture with an old reference is not a restart");
    parser.Reset();
    Check(!Parse(Packet({}, picture)), "picture without SPS rejected");

    std::vector<uint8_t> sequenceUnit;
    Unit(sequenceUnit, 0xb0, sequence);
    bool allRejected = true;
    for (std::size_t size = 0; size < sequenceUnit.size(); ++size)
    {
        parser.Reset();
        if (parser.ParsePacket(sequenceUnit.data(), size, p)) allRejected = false;
    }
    Check(allRejected, "every truncated SPS byte bound rejected");
    bool noCandidate = true;
    for (std::size_t size = 0; size < packet.size() - 5; ++size)
    {
        parser.Reset();
        if (parser.ParsePacket(packet.data(), size, p) && p.restartCandidate) noCandidate = false;
    }
    Check(noCandidate, "truncated picture without a slice cannot certify");
    Check(!Parse(Packet(Sequence(true), picture)), "background sequence rejected");
    Check(!Parse(Packet(Sequence(false, true), picture)), "weighted quantization UE above cap rejected");
    Check(!Parse(Packet(Sequence(false, false, 33), picture)), "SPS RPS table above 32 rejected");
    Check(!Parse(Packet(Sequence(false, false, 1, true), picture)), "field-coded sequence rejected");
    Check(!Parse(Packet(sequence, Picture(26, true, {}, 1))), "out-of-range SPS RPS index rejected");
    Check(!Parse(Packet(sequence, Picture(26, true, {1, 2, 3, 4, 5}, -1))), "more than four references rejected");
    Check(!Parse(Packet(sequence, Picture(26, true, {}, -1, false))), "invalid inline RPS marker rejected");
    Check(!parser.ParsePacket(nullptr, 100, p) &&
              !parser.ParsePacket(packet.data(), 16u * 1024u * 1024u + 1, p),
          "null and oversized packet bounds");
    Check(!Parse(Packet({}, picture)) && Parse(packet), "failure clears SPS; valid new SPS recovers");

    AVS2SeekClosure closure;
    Check(closure.Begin(p), "zero-reference ordinary I starts a candidate");
    p.hasSequence = false; p.intra = p.ordinaryI = p.restartCandidate = false;
    p.refCount = 1; p.refDeltas[0] = 1;
    bool consecutive = true;
    for (unsigned i = 1; i < 64; ++i)
    {
        p.coi = static_cast<uint8_t>(26 + i);
        if (!closure.Add(p)) consecutive = false;
    }
    Check(consecutive && closure.Certified() && closure.Count() == 64,
          "64 consecutive pictures certify reference closure");
    Parse(packet); p.coi = 230; closure.Begin(p);
    p.restartCandidate = p.intra = p.ordinaryI = false; p.refCount = 1; p.refDeltas[0] = 1;
    consecutive = true;
    for (unsigned i = 1; i < 64; ++i)
    {
        p.coi = static_cast<uint8_t>(230 + i);
        if (!closure.Add(p)) consecutive = false;
    }
    Check(consecutive && closure.Certified(), "COI 255-to-0 wrap remains consecutive");
    Parse(packet); closure.Begin(p); p.coi = 27; p.refCount = 1; p.refDeltas[0] = 2;
    Check(!closure.Add(p) && !closure.Certified(), "pre-entry reference invalidates closure");
    Parse(packet); closure.Begin(p); p.coi = 28;
    Check(!closure.Add(p), "COI gap invalidates closure");
    Parse(packet); closure.Begin(p); p.coi = 27; p.refCount = 1; p.refDeltas[0] = 0;
    Check(!closure.Add(p), "self-reference invalidates closure");
    Parse(packet); closure.Begin(p);
    Check(Parse(Packet(Sequence(false, false, 1, false, 1920), Picture(27, false, {1}, -1), 0xb6)) &&
              !closure.Add(p), "geometry change invalidates closure");
    std::printf("SUMMARY tests=%u passed\n", tests);
    return 0;
}
