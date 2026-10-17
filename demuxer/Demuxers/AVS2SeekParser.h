// SPDX-License-Identifier: GPL-2.0-or-later
// Bounded AVS2 prediction metadata for seek preflight; syntax follows davs2.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

class AVS2SeekParser
{
  public:
    struct Picture
    {
        bool valid = false;
        bool hasSequence = false; // A complete B0 in this packet, not cached state.
        bool hasPicture = false;
        bool intra = false;
        bool ordinaryI = false;
        bool backgroundDisabled = false;
        bool restartCandidate = false;
        uint8_t coi = 0;
        uint64_t sequenceTag = 0; // Geometry/internal-depth changes reset decoder references.
        unsigned refCount = 0;
        std::array<uint8_t, 7> refDeltas{};
    };

    void Reset() { m_sequence = Sequence{}; }
    bool HasSequence() const { return m_sequence.valid; }

    bool ParsePacket(const uint8_t *data, std::size_t size, Picture &picture)
    {
        picture = Picture{};
        if (!data || size < 4 || size > 16u * 1024u * 1024u ||
            data[0] || data[1] || data[2] != 1)
            return Fail(picture);

        std::size_t position = 0;
        bool sliceAfterPicture = false;
        while (position + 4 <= size)
        {
            const uint8_t code = data[position + 3];
            std::size_t next = position + 4;
            while (next + 3 <= size &&
                   !(data[next] == 0 && data[next + 1] == 0 && data[next + 2] == 1))
                ++next;
            if (next + 3 > size)
                next = size;
            const std::size_t payloadSize = next - position - 4;
            if (code == 0xb0)
            {
                if (picture.hasPicture || !ParseSequence(data + position + 4, payloadSize))
                    return Fail(picture);
                picture.hasSequence = true;
            }
            else if (code == 0xb3 || code == 0xb6)
            {
                if (picture.hasPicture || !m_sequence.valid ||
                    !ParsePicture(data + position + 4, payloadSize, code == 0xb3, picture))
                    return Fail(picture);
            }
            else if (code == 0xb4 || code == 0xb7)
            {
                // Video-edit discontinuities need a new independently certified entry.
                return Fail(picture);
            }
            else if (code > 0xb7)
                return Fail(picture);
            else if (code <= 0xaf && picture.hasPicture)
                sliceAfterPicture = true;
            if (next == size)
                break;
            if (next + 4 > size)
                return Fail(picture);
            position = next;
        }
        if (picture.hasPicture && !sliceAfterPicture)
            return Fail(picture);
        picture.valid = true;
        picture.backgroundDisabled = m_sequence.valid && m_sequence.backgroundDisabled;
        picture.sequenceTag = m_sequence.tag;
        picture.restartCandidate = picture.hasPicture && picture.ordinaryI &&
                                   picture.backgroundDisabled && picture.refCount == 0;
        return true;
    }

  private:
    class Bits
    {
      public:
        Bits(const uint8_t *data, std::size_t size, bool demulate)
            : m_data(data), m_size(size), m_demulate(demulate), m_good(size <= 4096) {}

        uint32_t Read(unsigned count)
        {
            if (count > 32) { m_good = false; return 0; }
            uint32_t value = 0;
            while (count-- && m_good)
            {
                if (!m_left)
                {
                    if (m_position == m_size) { m_good = false; break; }
                    const uint8_t byte = m_data[m_position++];
                    // davs2 removes the two trailing marker bits of 00 00 02 in picture
                    // units, but leaves sequence/extension/user-data units intact.
                    m_left = m_demulate && m_zeros == 2 && byte == 2 ? 6 : 8;
                    m_byte = m_left == 6 ? static_cast<uint8_t>(byte >> 2) : byte;
                    m_zeros = byte == 0 ? m_zeros + 1 : 0;
                }
                value = (value << 1) | ((m_byte >> --m_left) & 1);
            }
            return value;
        }

        uint32_t UE(uint32_t maximum)
        {
            unsigned zeros = 0;
            while (m_good && Read(1) == 0)
                if (++zeros > 16) { m_good = false; return 0; }
            if (!m_good) return 0;
            const uint32_t value = ((1u << zeros) - 1) + Read(zeros);
            if (value > maximum) m_good = false;
            return value;
        }

        bool Good() const { return m_good; }

      private:
        const uint8_t *m_data;
        std::size_t m_size, m_position = 0;
        unsigned m_left = 0, m_zeros = 0;
        uint8_t m_byte = 0;
        bool m_demulate, m_good;
    };

    struct RPS
    {
        unsigned count = 0;
        std::array<uint8_t, 7> deltas{};
    };
    struct Sequence
    {
        bool valid = false, backgroundDisabled = false, lowDelay = false, temporalId = false;
        unsigned rpsCount = 0;
        uint64_t tag = 0;
        std::array<RPS, 32> rps{};
    } m_sequence;

    bool Fail(Picture &picture)
    {
        Reset();
        picture = Picture{};
        return false;
    }

    static bool ParseInlineRPS(Bits &bits, RPS &rps)
    {
        bits.Read(1); // referenced by other pictures
        rps.count = bits.Read(3);
        if (rps.count > 4) return false; // Current davs2 supports four references.
        for (unsigned i = 0; i < rps.count; ++i)
        {
            rps.deltas[i] = static_cast<uint8_t>(bits.Read(6));
            if (!rps.deltas[i]) return false; // A picture cannot reference itself.
        }
        const unsigned removed = bits.Read(3);
        for (unsigned i = 0; i < removed; ++i) bits.Read(6);
        return bits.Read(1) == 1 && bits.Good();
    }

    bool ParseSequence(const uint8_t *data, std::size_t size)
    {
        Bits bits(data, size, false);
        Sequence sequence;
        const unsigned profile = bits.Read(8);
        if (profile != 0x12 && profile != 0x20 && profile != 0x22) return false;
        bits.Read(8); // level
        bits.Read(1); // progressive sequence
        if (bits.Read(1)) return false; // Field-coded sequences are not preflighted.
        const unsigned width = bits.Read(14), height = bits.Read(14);
        if (width < 16 || height < 16 || bits.Read(2) != 1) return false;
        const unsigned sample = bits.Read(3);
        const unsigned internal = profile == 0x22 ? bits.Read(3) : 1;
        if (sample < 1 || sample > internal || internal > 2) return false;
        sequence.tag = width | (static_cast<uint64_t>(height) << 14) |
                       (static_cast<uint64_t>(internal) << 28);
        bits.Read(4); // aspect ratio
        const unsigned rate = bits.Read(4);
        if (rate < 1 || rate > 13) return false;
        bits.Read(18);
        if (bits.Read(1) != 1) return false;
        bits.Read(12);
        sequence.lowDelay = bits.Read(1) != 0;
        if (bits.Read(1) != 1) return false;
        sequence.temporalId = bits.Read(1) != 0;
        bits.Read(18);
        const unsigned lcu = bits.Read(3);
        if (lcu < 4 || lcu > 6) return false;
        if (bits.Read(1) && bits.Read(1)) // weighted quantization + explicit matrices
            for (unsigned i = 0; i < 80; ++i) bits.UE(65535);
        sequence.backgroundDisabled = bits.Read(1) != 0;
        if (!sequence.backgroundDisabled) return false;
        bits.Read(10); // remaining sequence coding-tool flags
        if (bits.Read(1) != 1) return false;
        sequence.rpsCount = bits.Read(6);
        if (sequence.rpsCount > sequence.rps.size()) return false;
        for (unsigned i = 0; i < sequence.rpsCount; ++i)
            if (!ParseInlineRPS(bits, sequence.rps[i])) return false;
        if (!sequence.lowDelay) bits.Read(5); // picture reorder delay
        bits.Read(3); // cross-loop-filter flag and reserved bits
        if (!bits.Good()) return false;
        sequence.valid = true;
        m_sequence = sequence;
        return true;
    }

    bool ParsePicture(const uint8_t *data, std::size_t size, bool intra, Picture &picture)
    {
        Bits bits(data, size, true);
        bits.Read(32); // BBV delay
        if (intra)
        {
            if (bits.Read(1)) bits.Read(24); // optional time code
        }
        else
        {
            const unsigned type = bits.Read(2);
            if (type == 0) return false;
        }
        picture.coi = static_cast<uint8_t>(bits.Read(8));
        if (m_sequence.temporalId) bits.Read(3);
        if (!m_sequence.lowDelay) bits.UE(63); // display delay
        RPS rps;
        if (bits.Read(1))
        {
            const unsigned index = bits.Read(5);
            if (index >= m_sequence.rpsCount) return false;
            rps = m_sequence.rps[index];
        }
        else if (!ParseInlineRPS(bits, rps)) return false;
        if (m_sequence.lowDelay) bits.UE(65535); // BBV check times
        const bool progressive = bits.Read(1) != 0;
        if (!progressive && bits.Read(1) != 1) return false;
        bits.Read(2); // top/repeat field flags
        // At least fixed-picture-QP and its seven-bit value must be present.
        bits.Read(8);
        if (!bits.Good()) return false;
        picture.hasPicture = true;
        picture.intra = picture.ordinaryI = intra;
        picture.refCount = rps.count;
        picture.refDeltas = rps.deltas;
        return true;
    }
};

class AVS2SeekClosure
{
  public:
    void Reset() { m_valid = false; m_count = 0; m_previous = 0; }
    bool Begin(const AVS2SeekParser::Picture &picture)
    {
        Reset();
        if (!picture.valid || !picture.hasPicture || !picture.restartCandidate || !picture.ordinaryI ||
            !picture.backgroundDisabled || picture.refCount != 0) return false;
        m_valid = true;
        m_count = 1;
        m_previous = picture.coi;
        m_sequenceTag = picture.sequenceTag;
        return true;
    }
    bool Add(const AVS2SeekParser::Picture &picture)
    {
        if (!m_valid || !picture.valid || !picture.backgroundDisabled || picture.refCount > 4) { Reset(); return false; }
        if (!picture.hasPicture) return true;
        if (picture.sequenceTag != m_sequenceTag) { Reset(); return false; }
        if (picture.coi != static_cast<uint8_t>(m_previous + 1)) { Reset(); return false; }
        for (unsigned i = 0; i < picture.refCount; ++i)
            if (!picture.refDeltas[i] || picture.refDeltas[i] > m_count) { Reset(); return false; }
        m_previous = picture.coi;
        if (m_count < 64) ++m_count;
        return true;
    }
    bool Certified() const { return m_valid && m_count >= 64; }
    unsigned Count() const { return m_count; }

  private:
    bool m_valid = false;
    unsigned m_count = 0;
    uint8_t m_previous = 0;
    uint64_t m_sequenceTag = 0;
};
