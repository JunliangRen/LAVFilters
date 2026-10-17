#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
extern "C" {
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/pixdesc.h"
}

// Direct API regression: each decoder owns its state; all load the same DLL.
// No filter registration, registry writes, player settings, or output YUV files.
static void Require(bool condition, const char *operation)
{
    if (!condition) throw std::runtime_error(operation);
}

static std::string Utf8(const wchar_t *value)
{
    const int length = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    Require(length > 0, "UTF-8 path length");
    std::string output(length, '\0');
    Require(WideCharToMultiByte(CP_UTF8, 0, value, -1, &output[0], length, nullptr, nullptr) != 0, "UTF-8 path");
    output.pop_back();
    return output;
}

class Hash
{
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE handle = nullptr;
    std::vector<BYTE> object;
    ULONG length = 0;
public:
    explicit Hash(LPCWSTR name)
    {
        Require(BCryptOpenAlgorithmProvider(&algorithm, name, nullptr, 0) >= 0, "hash algorithm");
        ULONG size = 0, bytes = 0;
        Require(BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<BYTE *>(&size), sizeof(size), &bytes, 0) >= 0, "hash object size");
        object.resize(size);
        Require(BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH, reinterpret_cast<BYTE *>(&length), sizeof(length), &bytes, 0) >= 0, "hash size");
        Require(BCryptCreateHash(algorithm, &handle, object.data(), size, nullptr, 0, 0) >= 0, "hash create");
    }
    ~Hash() { if (handle) BCryptDestroyHash(handle); if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0); }
    void Add(const std::vector<BYTE> &data)
    {
        Require(BCryptHashData(handle, const_cast<BYTE *>(data.data()), static_cast<ULONG>(data.size()), 0) >= 0, "hash pixels");
    }
    std::string Finish()
    {
        std::vector<BYTE> digest(length);
        Require(BCryptFinishHash(handle, digest.data(), length, 0) >= 0, "finish hash");
        std::string result;
        constexpr char hex[] = "0123456789abcdef";
        for (BYTE value : digest) { result += hex[value >> 4]; result += hex[value & 15]; }
        return result;
    }
};

struct Api
{
    template<class T> static T Get(HMODULE module, const char *name)
    {
        auto function = reinterpret_cast<T>(GetProcAddress(module, name));
        Require(function != nullptr, name);
        return function;
    }
#define DECLARE(name) decltype(&name) name##Fn = nullptr
    DECLARE(avformat_open_input); DECLARE(avformat_find_stream_info); DECLARE(av_read_frame); DECLARE(avformat_close_input);
    DECLARE(avcodec_find_decoder_by_name); DECLARE(avcodec_alloc_context3); DECLARE(avcodec_parameters_to_context); DECLARE(avcodec_open2);
    DECLARE(avcodec_send_packet); DECLARE(avcodec_receive_frame); DECLARE(avcodec_flush_buffers); DECLARE(avcodec_free_context);
    DECLARE(av_packet_alloc); DECLARE(av_packet_clone); DECLARE(av_packet_unref); DECLARE(av_packet_free);
    DECLARE(av_frame_alloc); DECLARE(av_frame_unref); DECLARE(av_frame_free); DECLARE(av_pix_fmt_desc_get);
#undef DECLARE
    explicit Api(const wchar_t *directory)
    {
        SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        Require(AddDllDirectory(directory) != nullptr, "candidate DLL directory");
        auto load = [&](const wchar_t *name) {
            return LoadLibraryExW((std::wstring(directory) + L"\\" + name).c_str(), nullptr,
                LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        };
        HMODULE util = load(L"avutil-lav-61.dll"), codec = load(L"avcodec-lav-63.dll"), format = load(L"avformat-lav-63.dll");
        Require(util && codec && format, "load candidate FFmpeg libraries");
#define IMPORT(library, name) name##Fn = Get<decltype(&name)>(library, #name)
        IMPORT(format, avformat_open_input); IMPORT(format, avformat_find_stream_info); IMPORT(format, av_read_frame); IMPORT(format, avformat_close_input);
        IMPORT(codec, avcodec_find_decoder_by_name); IMPORT(codec, avcodec_alloc_context3); IMPORT(codec, avcodec_parameters_to_context); IMPORT(codec, avcodec_open2);
        IMPORT(codec, avcodec_send_packet); IMPORT(codec, avcodec_receive_frame); IMPORT(codec, avcodec_flush_buffers); IMPORT(codec, avcodec_free_context);
        IMPORT(codec, av_packet_alloc); IMPORT(codec, av_packet_clone); IMPORT(codec, av_packet_unref); IMPORT(codec, av_packet_free);
        IMPORT(util, av_frame_alloc); IMPORT(util, av_frame_unref); IMPORT(util, av_frame_free); IMPORT(util, av_pix_fmt_desc_get);
#undef IMPORT
    }
};

struct Input
{
    Api &api;
    AVFormatContext *format = nullptr;
    int stream = -1;
    std::vector<AVPacket *> packets;
    uint64_t packetBytes = 0;
    Input(Api &functions, const wchar_t *path, bool probe = true) : api(functions)
    {
        const auto filename = Utf8(path);
        Require(api.avformat_open_inputFn(&format, filename.c_str(), nullptr, nullptr) >= 0, "open bounded fixture");
        if (probe) {
            Require(api.avformat_find_stream_infoFn(format, nullptr) >= 0, "fixture stream info");
            for (unsigned index = 0; index < format->nb_streams; ++index)
                if (format->streams[index]->codecpar->codec_id == AV_CODEC_ID_AVS2) { stream = static_cast<int>(index); break; }
            Require(stream >= 0, "fixture must contain AVS2 video");
        }
        AVPacket *packet = api.av_packet_allocFn();
        Require(packet != nullptr, "packet allocation");
        int result = 0;
        while ((result = api.av_read_frameFn(format, packet)) >= 0) {
            if (stream < 0 && packet->stream_index >= 0 && static_cast<unsigned>(packet->stream_index) < format->nb_streams &&
                format->streams[packet->stream_index]->codecpar->codec_id == AV_CODEC_ID_AVS2)
                stream = packet->stream_index;
            if (packet->stream_index == stream) {
                packetBytes += packet->size;
                // A mistaken full-recording input cannot grow memory without bound.
                Require(packetBytes <= 128ull * 1024 * 1024 && packets.size() < 8192, "fixture exceeds 128 MiB / 8192 video packet bound");
                auto copy = api.av_packet_cloneFn(packet);
                Require(copy != nullptr, "clone fixture packet");
                packets.push_back(copy);
            }
            api.av_packet_unrefFn(packet);
        }
        api.av_packet_freeFn(&packet);
        Require(result == AVERROR_EOF && stream >= 0 && !packets.empty(), "bounded fixture demux EOF with AVS2 video");
    }
    ~Input()
    {
        for (auto packet : packets) api.av_packet_freeFn(&packet);
        api.avformat_close_inputFn(&format);
    }
    AVStream *Stream() const { return format->streams[stream]; }
};

struct Frame
{
    int width = 0, height = 0, bits = 0;
    int64_t pts = AV_NOPTS_VALUE, duration = 0;
    std::string sha256;
    bool operator==(const Frame &other) const
    {
        return width == other.width && height == other.height && bits == other.bits && pts == other.pts &&
            duration == other.duration && sha256 == other.sha256;
    }
};

struct Result
{
    std::string name, md5;
    std::vector<Frame> frames;
    uint64_t bytes = 0, precision = 0;
    bool passed = false;
};

class Decoder
{
    Api &api;
    AVCodecContext *context = nullptr;
    AVFrame *frame = nullptr;
    Result result;
    Hash *aggregate = nullptr;
    void Capture()
    {
        const auto *description = api.av_pix_fmt_desc_getFn(static_cast<AVPixelFormat>(frame->format));
        Require(description && description->nb_components == 3 && description->log2_chroma_w == 1 && description->log2_chroma_h == 1 &&
            (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUV420P10LE), "unexpected decoded pixel format");
        const int bits = description->comp[0].depth;
        Require(bits == 8 || bits == 10, "unexpected sample precision");
        Require(frame->width > 0 && frame->height > 0 && !(frame->width & 1) && !(frame->height & 1), "invalid decoded dimensions");
        const int sampleBytes = bits > 8 ? 2 : 1;
        std::vector<BYTE> canonical(size_t(frame->width) * frame->height * 3 / 2 * sampleBytes);
        size_t offset = 0;
        for (int plane = 0; plane < 3; ++plane) {
            const int width = plane ? frame->width / 2 : frame->width, height = plane ? frame->height / 2 : frame->height;
            Require(frame->data[plane] && std::abs(frame->linesize[plane]) >= width * sampleBytes, "invalid decoded plane");
            for (int row = 0; row < height; ++row) {
                const BYTE *source = frame->data[plane] + ptrdiff_t(row) * frame->linesize[plane];
                std::copy_n(source, width * sampleBytes, canonical.data() + offset);
                if (bits == 10) {
                    const auto *samples = reinterpret_cast<const uint16_t *>(source);
                    for (int col = 0; col < width; ++col) {
                        Require(samples[col] < 1024, "10-bit sample outside nominal range");
                        // Match the graph helper's luma-only precision counter.
                        if (!plane) result.precision += (samples[col] & 3) != 0;
                    }
                }
                offset += width * sampleBytes;
            }
        }
        Hash hash(BCRYPT_SHA256_ALGORITHM);
        hash.Add(canonical); aggregate->Add(canonical);
        result.bytes += canonical.size();
        result.frames.push_back({frame->width, frame->height, bits, frame->pts, frame->duration, hash.Finish()});
    }
    int Receive()
    {
        int ret = 0;
        while ((ret = api.avcodec_receive_frameFn(context, frame)) >= 0) {
            Capture(); api.av_frame_unrefFn(frame);
        }
        Require(ret == AVERROR(EAGAIN) || ret == AVERROR_EOF, "receive frame failed");
        return ret;
    }
public:
    Decoder(Api &functions, const Input &input, int threads) : api(functions)
    {
        const auto *codec = api.avcodec_find_decoder_by_nameFn("libdavs2");
        Require(codec != nullptr && codec->id == AV_CODEC_ID_AVS2, "libdavs2 codec unavailable");
        context = api.avcodec_alloc_context3Fn(codec);
        Require(context != nullptr, "allocate decoder context");
        Require(api.avcodec_parameters_to_contextFn(context, input.Stream()->codecpar) >= 0, "copy decoder parameters");
        context->pkt_timebase = input.Stream()->time_base;
        context->thread_count = threads;
        Require(api.avcodec_open2Fn(context, codec, nullptr) >= 0, "open libdavs2 context");
        frame = api.av_frame_allocFn();
        Require(frame != nullptr, "allocate output frame");
        Reset("initial");
    }
    ~Decoder()
    {
        delete aggregate;
        api.av_frame_freeFn(&frame);
        api.avcodec_free_contextFn(&context);
    }
    void Reset(const char *name)
    {
        delete aggregate; aggregate = new Hash(BCRYPT_MD5_ALGORITHM);
        result = Result{}; result.name = name;
    }
    void Flush() { api.avcodec_flush_buffersFn(context); }
    void Step(const AVPacket *packet)
    {
        int ret = api.avcodec_send_packetFn(context, packet);
        if (ret == AVERROR(EAGAIN)) {
            Require(Receive() == AVERROR(EAGAIN), "unexpected decoder EOF before send");
            ret = api.avcodec_send_packetFn(context, packet);
        }
        Require(ret >= 0, "send AVS2 packet failed");
        Receive();
    }
    void Packets(const Input &input) { for (const auto *packet : input.packets) Step(packet); }
    Result Finish()
    {
        Require(api.avcodec_send_packetFn(context, nullptr) >= 0, "send drain packet failed");
        Require(Receive() == AVERROR_EOF, "decoder did not finish drain");
        result.md5 = aggregate->Finish();
        Require(!result.frames.empty(), "decoder emitted no frames");
        return result;
    }
};

static Result Decode(Api &api, const Input &input, int threads, const char *name)
{
    Decoder decoder(api, input, threads);
    decoder.Reset(name); decoder.Packets(input);
    auto result = decoder.Finish(); result.passed = true;
    return result;
}

static void Match(Result &actual, const Result &expected)
{
    actual.passed = actual.frames == expected.frames && actual.bytes == expected.bytes && actual.precision == expected.precision;
    if (!actual.passed) {
        size_t first = 0;
        while (first < std::min(actual.frames.size(), expected.frames.size()) && actual.frames[first] == expected.frames[first]) ++first;
        std::fprintf(stderr, "%s: expected %zu frames/%llu bytes, got %zu/%llu; first differing frame %zu\n",
            actual.name.c_str(), expected.frames.size(), static_cast<unsigned long long>(expected.bytes), actual.frames.size(),
            static_cast<unsigned long long>(actual.bytes), first);
    }
}

static Result Joined(const Result &first, const Result &second, const Result &third)
{
    Result expected;
    for (const auto *item : {&first, &second, &third}) {
        expected.frames.insert(expected.frames.end(), item->frames.begin(), item->frames.end());
        expected.bytes += item->bytes; expected.precision += item->precision;
    }
    return expected;
}

static void Write(FILE *output, const Result &result, bool comma)
{
    std::fprintf(output, "%s{\"name\":\"%s\",\"pass\":%s,\"frames\":%zu,\"bytes\":%llu,\"precision_samples\":%llu,\"md5\":\"%s\",\"frame_data\":[\r\n",
        comma ? "," : "", result.name.c_str(), result.passed ? "true" : "false", result.frames.size(),
        static_cast<unsigned long long>(result.bytes), static_cast<unsigned long long>(result.precision), result.md5.c_str());
    for (size_t index = 0; index < result.frames.size(); ++index) {
        const auto &frame = result.frames[index];
        std::fprintf(output, "%s{\"width\":%d,\"height\":%d,\"bits\":%d,\"pts\":%lld,\"duration\":%lld,\"sha256\":\"%s\"}\r\n",
            index ? "," : "", frame.width, frame.height, frame.bits, frame.pts, frame.duration, frame.sha256.c_str());
    }
    std::fprintf(output, "]}\r\n"); std::fflush(output);
    std::printf("%s %s frames=%zu md5=%s\n", result.passed ? "PASS" : "FAIL", result.name.c_str(), result.frames.size(), result.md5.c_str());
    std::fflush(stdout);
}

int wmain(int argc, wchar_t **argv)
{
    if (argc < 5 || argc > 6) {
        std::fprintf(stderr, "codec-instances.exe PACKAGE AVS2_8.ts AVS2_10.ts OUTPUT.json [THREADS]\n");
        std::fprintf(stderr, "codec-instances.exe --cold-8|--cold-10 PACKAGE AVS2.ts OUTPUT.json [THREADS]\n");
        return 2;
    }
    FILE *output = nullptr;
    try {
        const int threads = argc == 6 ? _wtoi(argv[5]) : 2;
        Require(threads > 0 && threads <= 16, "threads must be in [1,16]");
        const bool cold8 = std::wstring(argv[1]) == L"--cold-8", cold10 = std::wstring(argv[1]) == L"--cold-10";
        if (cold8 || cold10) {
            const int bits = cold10 ? 10 : 8;
            Api api(argv[2]);
            // find_stream_info may decode frames and initialize the global
            // primitive table. Demux only, so both workers encounter it cold.
            Input input(api, argv[3], false);
            Require(_wfopen_s(&output, argv[4], L"wb") == 0, "create cold report");
            std::fprintf(output, "{\"pointer_bits\":%zu,\"decoder\":\"libdavs2\",\"threads\":%d,\"bits\":%d,\"probe_warmed_decoder\":false,\"runs\":[\r\n", sizeof(void *) * 8, threads, bits);
            std::atomic<int> ready{0}; std::atomic<bool> start{false};
            Result firstResult, secondResult; std::exception_ptr firstError, secondError;
            auto worker = [&](const char *name, Result &result, std::exception_ptr &error) {
                std::unique_ptr<Decoder> decoder;
                try { decoder = std::make_unique<Decoder>(api, input, threads); } catch (...) { error = std::current_exception(); }
                ready.fetch_add(1);
                while (!start.load()) std::this_thread::yield();
                if (decoder) try {
                    decoder->Reset(name); decoder->Packets(input); result = decoder->Finish();
                } catch (...) { error = std::current_exception(); }
            };
            std::thread first(worker, "cold-first-a", std::ref(firstResult), std::ref(firstError));
            std::thread second(worker, "cold-first-b", std::ref(secondResult), std::ref(secondError));
            while (ready.load() != 2) std::this_thread::yield();
            start.store(true); first.join(); second.join();
            if (firstError) std::rethrow_exception(firstError);
            if (secondError) std::rethrow_exception(secondError);
            const auto baseline = Decode(api, input, threads, "warm-baseline");
            for (const auto &frame : baseline.frames) Require(frame.bits == bits, "cold input has wrong precision");
            if (bits == 10) Require(baseline.precision > 0, "cold 10-bit input lacks low precision samples");
            Match(firstResult, baseline); Write(output, firstResult, false);
            Match(secondResult, baseline); Write(output, secondResult, true);
            Write(output, baseline, true);
            const bool passed = firstResult.passed && secondResult.passed;
            std::fprintf(output, "],\"passed\":%s,\"run_count\":3}\r\n", passed ? "true" : "false");
            std::fclose(output); output = nullptr;
            return passed ? 0 : 1;
        }
        Api api(argv[1]); Input eight(api, argv[2]), ten(api, argv[3]);
        Require(_wfopen_s(&output, argv[4], L"wb") == 0, "create report");
        std::fprintf(output, "{\"pointer_bits\":%zu,\"decoder\":\"libdavs2\",\"threads\":%d,\"packet_counts\":[%zu,%zu],\"packet_bytes\":[%llu,%llu],\"runs\":[\r\n",
            sizeof(void *) * 8, threads, eight.packets.size(), ten.packets.size(), static_cast<unsigned long long>(eight.packetBytes), static_cast<unsigned long long>(ten.packetBytes));
        std::vector<Result> runs;
        auto save = [&](Result result, const Result *expected = nullptr) {
            if (expected) Match(result, *expected);
            Write(output, result, !runs.empty());
            Require(result.passed, result.name.c_str());
            runs.push_back(std::move(result));
        };
        const auto base8 = Decode(api, eight, threads, "baseline-8");
        const auto base10 = Decode(api, ten, threads, "baseline-10");
        for (const auto &frame : base8.frames) Require(frame.bits == 8, "8-bit baseline changed precision");
        for (const auto &frame : base10.frames) Require(frame.bits == 10, "10-bit baseline changed precision");
        Require(base10.precision > 0, "10-bit baseline lacks low precision bits");
        save(base8); save(base10);
        {
            Decoder dec8(api, eight, threads), dec10(api, ten, threads);
            dec8.Reset("interleaved-8"); dec10.Reset("interleaved-10");
            for (size_t index = 0; index < std::max(eight.packets.size(), ten.packets.size()); ++index) {
                if (index < eight.packets.size()) dec8.Step(eight.packets[index]);
                if (index < ten.packets.size()) dec10.Step(ten.packets[index]);
            }
            save(dec8.Finish(), &base8); save(dec10.Finish(), &base10);
        }
        {
            std::atomic<int> ready{0}; std::atomic<bool> start{false};
            Result parallel8, parallel10; std::exception_ptr error8, error10;
            auto worker = [&](const Input &input, const char *name, Result &result, std::exception_ptr &error) {
                ready.fetch_add(1);
                while (!start.load()) std::this_thread::yield();
                try { result = Decode(api, input, threads, name); } catch (...) { error = std::current_exception(); }
            };
            std::thread first(worker, std::cref(eight), "parallel-8", std::ref(parallel8), std::ref(error8));
            std::thread second(worker, std::cref(ten), "parallel-10", std::ref(parallel10), std::ref(error10));
            while (ready.load() != 2) std::this_thread::yield();
            start.store(true); first.join(); second.join();
            if (error8) std::rethrow_exception(error8);
            if (error10) std::rethrow_exception(error10);
            save(parallel8, &base8); save(parallel10, &base10);
        }
        for (bool reverse : {false, true}) {
            const Input *inputs[] = {reverse ? &ten : &eight, reverse ? &eight : &ten, reverse ? &ten : &eight};
            const Result *expected[] = {reverse ? &base10 : &base8, reverse ? &base8 : &base10, reverse ? &base10 : &base8};
            Decoder decoder(api, *inputs[0], threads);
            for (int index = 0; index < 3; ++index) {
                decoder.Flush();
                const auto name = std::string("flush-switch-") + (reverse ? "10-8-10-" : "8-10-8-") + std::to_string(index);
                decoder.Reset(name.c_str()); decoder.Packets(*inputs[index]);
                save(decoder.Finish(), expected[index]);
            }
            const auto expectedJoined = Joined(*expected[0], *expected[1], *expected[2]);
            decoder.Flush(); decoder.Reset(reverse ? "sequence-switch-10-8-10" : "sequence-switch-8-10-8");
            for (const auto *input : inputs) decoder.Packets(*input);
            save(decoder.Finish(), &expectedJoined);
        }
        for (const auto *input : {&eight, &ten}) {
            Decoder decoder(api, *input, threads);
            for (size_t index = 0; index < std::min<size_t>(8, input->packets.size()); ++index) decoder.Step(input->packets[index]);
            decoder.Flush(); decoder.Reset(input == &eight ? "discard-flush-replay-8" : "discard-flush-replay-10");
            decoder.Packets(*input); save(decoder.Finish(), input == &eight ? &base8 : &base10);
        }
        std::fprintf(output, "],\"passed\":true,\"run_count\":%zu}\r\n", runs.size());
        std::fclose(output); output = nullptr;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        if (output) { std::fprintf(output, "],\"passed\":false}\r\n"); std::fclose(output); }
        return 1;
    }
    return 0;
}
