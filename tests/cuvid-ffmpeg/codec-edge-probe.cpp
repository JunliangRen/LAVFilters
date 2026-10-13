#define NOMINMAX
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <string>
extern "C" {
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/opt.h"
#include "libavutil/sha.h"
#include "libavutil/mem.h"
}
#define STRINGIFY_VALUE(value) STRINGIFY_LITERAL(value)
#define STRINGIFY_LITERAL(value) #value
static const char *codecModule = "avcodec-lav-" STRINGIFY_VALUE(LIBAVCODEC_VERSION_MAJOR) ".dll";
static const char *formatModule = "avformat-lav-" STRINGIFY_VALUE(LIBAVFORMAT_VERSION_MAJOR) ".dll";
static const char *utilModule = "avutil-lav-" STRINGIFY_VALUE(LIBAVUTIL_VERSION_MAJOR) ".dll";

static void Check(int result, const char *operation)
{
    if (result < 0) {
        char message[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(result, message, sizeof(message));
        std::fprintf(stderr, "%s: %s (%d)\n", operation, message, result);
        std::exit(1);
    }
}

static std::string Hash(const AVFrame *frame)
{
    AVSHA *hash = av_sha_alloc();
    if (!hash) std::exit(1);
    av_sha_init(hash, 256);
    if (frame->format != AV_PIX_FMT_NV12 && frame->format != AV_PIX_FMT_YUV420P) std::exit(1);
    const int planes = frame->format == AV_PIX_FMT_NV12 ? 2 : 3;
    if (planes == 3) {
        for (int plane = 0; plane < 3; ++plane)
            for (int row = 0; row < frame->height / (plane ? 2 : 1); ++row)
                av_sha_update(hash, frame->data[plane] + row * frame->linesize[plane], frame->width / (plane ? 2 : 1));
    } else {
        for (int row = 0; row < frame->height; ++row)
            av_sha_update(hash, frame->data[0] + row * frame->linesize[0], frame->width);
        // Canonical planar Y,U,V, matching the DirectShow capture.
        for (int component = 0; component < 2; ++component)
            for (int row = 0; row < frame->height / 2; ++row)
                for (int col = 0; col < frame->width / 2; ++col)
                    av_sha_update(hash, frame->data[1] + row * frame->linesize[1] + col * 2 + component, 1);
    }
    uint8_t digest[32]; av_sha_final(hash, digest); av_free(hash);
    const char *hex = "0123456789abcdef";
    std::string result;
    for (uint8_t value : digest) { result += hex[value >> 4]; result += hex[value & 15]; }
    return result;
}

static std::string ModulePath(const char *name)
{
    char path[32768];
    HMODULE module = GetModuleHandleA(name);
    if (!module || !GetModuleFileNameA(module, path, sizeof(path))) std::exit(1);
    std::string result;
    for (const char *value = path; *value; ++value) {
        if (*value == '\\' || *value == '"') result += '\\';
        result += *value;
    }
    return result;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        std::fprintf(stderr, "codec-edge-probe INPUT OUTPUT.json software|default-cuvid|dynamic-auto\n");
        return 2;
    }
    AVFormatContext *format = nullptr;
    Check(avformat_open_input(&format, argv[1], nullptr, nullptr), "open input");
    Check(avformat_find_stream_info(format, nullptr), "stream info");
    int video = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    Check(video, "video stream");
    const bool dynamic = std::string(argv[3]) == "dynamic-auto";
    const bool hardware = dynamic || std::string(argv[3]) == "default-cuvid";
    const AVCodec *codec = hardware ? avcodec_find_decoder_by_name(dynamic ? "mpeg2_cuvid" : "h264_cuvid") : avcodec_find_decoder(format->streams[video]->codecpar->codec_id);
    if (!codec) return 2;
    AVCodecContext *context = avcodec_alloc_context3(codec);
    Check(avcodec_parameters_to_context(context, format->streams[video]->codecpar), "codec parameters");
    context->pkt_timebase = format->streams[video]->time_base;
    context->framerate = hardware ? AVRational{25, 1} : format->streams[video]->r_frame_rate;
    context->thread_count = 1;
    AVDictionary *options = nullptr;
    if (hardware) {
        av_dict_set(&options, "deint", "adaptive", 0);
        av_dict_set(&options, "drop_second_field", "0", 0);
        if (dynamic) av_dict_set(&options, "dynamic_deint", "1", 0);
        // Do not opt into dynamic_deint: this explicitly tests the default API.
    }
    Check(avcodec_open2(context, codec, &options), "codec open");
    if (options) return 2;
    FILE *output = nullptr;
    if (fopen_s(&output, argv[2], "wb")) return 2;
    std::fprintf(output, "{\"pointer_bits\":%zu,\"decoder\":\"%s\",\"loaded_modules\":{\"%s\":\"%s\",\"%s\":\"%s\",\"%s\":\"%s\"},\"input_time_base\":[%d,%d],\"frames\":[\r\n", sizeof(void *) * 8, codec->name,
        codecModule, ModulePath(codecModule).c_str(), formatModule, ModulePath(formatModule).c_str(), utilModule, ModulePath(utilModule).c_str(), context->pkt_timebase.num, context->pkt_timebase.den);
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    size_t count = 0;
    auto Receive = [&]() {
        int result;
        while ((result = avcodec_receive_frame(context, frame)) >= 0) {
            const AVDictionaryEntry *processed = av_dict_get(frame->metadata, "lav.cuvid.deinterlaced", nullptr, 0);
            std::fprintf(output, "%s{\"pts\":%lld,\"duration\":%lld,\"repeat_pict\":%d,\"interlaced\":%s,\"top_field_first\":%s,\"framerate\":[%d,%d],\"sha256\":\"%s\",\"processed\":\"%s\"}\r\n", count ? "," : "", frame->pts, frame->duration, frame->repeat_pict,
                frame->flags & AV_FRAME_FLAG_INTERLACED ? "true" : "false", frame->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST ? "true" : "false", context->framerate.num, context->framerate.den, Hash(frame).c_str(), processed ? processed->value : "");
            ++count;
            av_frame_unref(frame);
        }
        if (result != AVERROR(EAGAIN) && result != AVERROR_EOF) Check(result, "receive frame");
    };
    while (av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == video) {
            int result;
            while ((result = avcodec_send_packet(context, packet)) == AVERROR(EAGAIN)) Receive();
            Check(result, "send packet");
            Receive();
        }
        av_packet_unref(packet);
    }
    Check(avcodec_send_packet(context, nullptr), "drain");
    Receive();
    std::fprintf(output, "],\"count\":%zu,\"output_framerate\":[%d,%d]}\r\n", count, context->framerate.num, context->framerate.den);
    std::fclose(output);
    av_packet_free(&packet); av_frame_free(&frame);
    avcodec_free_context(&context); avformat_close_input(&format);
    return count ? 0 : 1;
}
