#define NOMINMAX
#include <windows.h>
#include <cstdio>
#include <stdexcept>
#include <string>
extern "C" {
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
}

template<class T> T Api(HMODULE library, const char *name)
{
    auto function = reinterpret_cast<T>(GetProcAddress(library, name));
    if (!function) throw std::runtime_error(name);
    return function;
}

int main(int argc, char **argv)
{
    if (argc != 4) return 2;
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    std::wstring directory;
    int length = MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, nullptr, 0);
    directory.resize(length);
    MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, &directory[0], length);
    AddDllDirectory(directory.c_str());
    auto load = [&](const wchar_t *name) { return LoadLibraryExW((directory.substr(0, directory.size() - 1) + L"\\" + name).c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS); };
    try {
        HMODULE util = load(L"avutil-lav-61.dll"), codec = load(L"avcodec-lav-63.dll"), format = load(L"avformat-lav-63.dll");
        if (!util || !codec || !format) throw std::runtime_error("load FFmpeg libraries");
#define IMPORT(library, name) auto name##Fn = Api<decltype(&name)>(library, #name)
        IMPORT(format, avformat_open_input); IMPORT(format, avformat_find_stream_info); IMPORT(format, av_read_frame); IMPORT(format, avformat_close_input);
        IMPORT(codec, avcodec_find_decoder); IMPORT(codec, avcodec_alloc_context3); IMPORT(codec, avcodec_parameters_to_context); IMPORT(codec, avcodec_open2);
        IMPORT(codec, avcodec_send_packet); IMPORT(codec, avcodec_receive_frame); IMPORT(codec, avcodec_free_context); IMPORT(codec, av_packet_alloc); IMPORT(codec, av_packet_unref); IMPORT(codec, av_packet_free);
        IMPORT(util, av_frame_alloc); IMPORT(util, av_frame_unref); IMPORT(util, av_frame_free);
        AVFormatContext *input = nullptr;
        if (avformat_open_inputFn(&input, argv[2], nullptr, nullptr) < 0 || avformat_find_stream_infoFn(input, nullptr) < 0) throw std::runtime_error("input probe");
        int stream = -1;
        for (unsigned index = 0; index < input->nb_streams; ++index) if (input->streams[index]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) { stream = index; break; }
        if (stream < 0) throw std::runtime_error("video stream");
        const AVCodec *decoder = avcodec_find_decoderFn(input->streams[stream]->codecpar->codec_id);
        AVCodecContext *context = avcodec_alloc_context3Fn(decoder);
        if (avcodec_parameters_to_contextFn(context, input->streams[stream]->codecpar) < 0) throw std::runtime_error("decoder parameters");
        context->thread_count = 1;
        if (avcodec_open2Fn(context, decoder, nullptr) < 0) throw std::runtime_error("decoder open");
        AVPacket *packet = av_packet_allocFn();
        AVFrame *frame = av_frame_allocFn();
        FILE *output = nullptr;
        if (fopen_s(&output, argv[3], "wb")) throw std::runtime_error("JSON output");
        std::fprintf(output, "{\"frames\":[\r\n");
        int count = 0;
        auto receive = [&]() {
            while (avcodec_receive_frameFn(context, frame) >= 0) {
                std::fprintf(output, "%s{\"pts\":%lld,\"best_effort_timestamp\":%lld,\"width\":%d,\"height\":%d}\r\n", count ? "," : "", frame->pts, frame->best_effort_timestamp, frame->width, frame->height);
                ++count; av_frame_unrefFn(frame);
            }
        };
        while (av_read_frameFn(input, packet) >= 0) {
            if (packet->stream_index == stream) {
                if (avcodec_send_packetFn(context, packet) < 0) throw std::runtime_error("send packet");
                receive();
            }
            av_packet_unrefFn(packet);
        }
        avcodec_send_packetFn(context, nullptr); receive();
        std::fprintf(output, "]}\r\n"); std::fclose(output);
        av_frame_freeFn(&frame); av_packet_freeFn(&packet); avcodec_free_contextFn(&context); avformat_close_inputFn(&input);
        std::printf("decoded frames: %d\n", count);
    } catch (const std::exception &error) { std::fprintf(stderr, "%s\n", error.what()); return 1; }
    return 0;
}
