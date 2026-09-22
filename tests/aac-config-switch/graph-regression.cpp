#define NOMINMAX
#include <windows.h>
#include <streams.h>
#include <atlbase.h>
#include <atomic>
#include <cstdio>
#include <string>
#include <vector>
#include "LAVAudioSettings.h"
#include "LAVSplitterSettings.h"
#include "LAVVideoSettings.h"

HINSTANCE g_hInst = nullptr;
DWORD g_amPlatform = VER_PLATFORM_WIN32_NT;

static void Check(HRESULT hr, const char *operation)
{
    if (FAILED(hr)) {
        std::fprintf(stderr, "%s: 0x%08lX\n", operation, static_cast<unsigned long>(hr));
        throw hr;
    }
}

class AudioCapture final : public CBaseRenderer
{
public:
    std::atomic<unsigned long long> buffers{0}, samples{0}, nonzero{0};
    std::atomic<long long> first{-1}, last{-1};
    std::atomic<unsigned> rate{0};

    explicit AudioCapture(HRESULT *hr) : CBaseRenderer(CLSID_NULL, L"Audio Capture", nullptr, hr) {}

    HRESULT CheckMediaType(const CMediaType *mt) override
    {
        return mt->majortype == MEDIATYPE_Audio && mt->formattype == FORMAT_WaveFormatEx &&
               (mt->subtype == MEDIASUBTYPE_PCM || mt->subtype == MEDIASUBTYPE_IEEE_FLOAT) ? S_OK : VFW_E_TYPE_NOT_ACCEPTED;
    }

    HRESULT DoRenderSample(IMediaSample *sample) override
    {
        CMediaType mt;
        HRESULT typeResult = m_pInputPin->ConnectionMediaType(&mt);
        if (FAILED(typeResult)) return typeResult;
        const auto *format = reinterpret_cast<const WAVEFORMATEX *>(mt.Format());
        if (!format || !format->nBlockAlign || !format->nSamplesPerSec) return E_FAIL;
        BYTE *data = nullptr;
        HRESULT hr = sample->GetPointer(&data);
        if (FAILED(hr)) return hr;
        const long bytes = sample->GetActualDataLength();
        bool audible = false;
        for (long i = 0; i < bytes; ++i) audible |= data[i] != 0;
        REFERENCE_TIME start = 0, stop = 0;
        if (SUCCEEDED(sample->GetTime(&start, &stop))) {
            if (first.load() == -1) first = start;
            last = stop;
        }
        rate = format->nSamplesPerSec;
        samples += bytes / format->nBlockAlign;
        nonzero += audible;
        ++buffers;
        return S_OK;
    }

    void Reset()
    {
        buffers = samples = nonzero = 0;
        first = last = -1;
        rate = 0;
    }
};

class VideoCapture final : public CBaseRenderer
{
public:
    std::atomic<unsigned long long> buffers{0};
    explicit VideoCapture(HRESULT *hr) : CBaseRenderer(CLSID_NULL, L"Video Capture", nullptr, hr) {}
    HRESULT CheckMediaType(const CMediaType *mt) override
    {
        return mt->majortype == MEDIATYPE_Video ? S_OK : VFW_E_TYPE_NOT_ACCEPTED;
    }
    HRESULT DoRenderSample(IMediaSample *) override
    {
        ++buffers;
        return S_OK;
    }
};

static CComPtr<IBaseFilter> Load(const std::wstring &directory, const wchar_t *file, const wchar_t *id)
{
    const std::wstring path = directory + L"\\" + file;
    HMODULE module = LoadLibraryExW(path.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!module) Check(HRESULT_FROM_WIN32(GetLastError()), "load filter");
    auto entry = reinterpret_cast<HRESULT (STDAPICALLTYPE *)(REFCLSID, REFIID, LPVOID *)>(GetProcAddress(module, "DllGetClassObject"));
    if (!entry) Check(E_NOINTERFACE, "class factory export");
    GUID clsid{};
    Check(CLSIDFromString(id, &clsid), "CLSID");
    CComPtr<IClassFactory> factory;
    Check(entry(clsid, IID_IClassFactory, reinterpret_cast<void **>(&factory)), "factory");
    CComPtr<IBaseFilter> filter;
    Check(factory->CreateInstance(nullptr, IID_IBaseFilter, reinterpret_cast<void **>(&filter)), "filter instance");
    return filter;
}

static CComPtr<IPin> Pin(IBaseFilter *filter, PIN_DIRECTION direction, const GUID *majorType = nullptr)
{
    CComPtr<IEnumPins> pins;
    Check(filter->EnumPins(&pins), "enum pins");
    CComPtr<IPin> pin;
    while (pins->Next(1, &pin, nullptr) == S_OK) {
        PIN_DIRECTION actual;
        Check(pin->QueryDirection(&actual), "pin direction");
        if (actual == direction) {
            if (!majorType) return pin;
            CComPtr<IEnumMediaTypes> types;
            Check(pin->EnumMediaTypes(&types), "enum media types");
            AM_MEDIA_TYPE *mt = nullptr;
            while (types->Next(1, &mt, nullptr) == S_OK) {
                bool matches = mt->majortype == *majorType;
                DeleteMediaType(mt);
                if (matches) return pin;
            }
        }
        pin.Release();
    }
    Check(E_FAIL, "find pin");
    return nullptr;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc < 3 || argc > 4) return 2;
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!AddDllDirectory(argv[1])) return 3;
    Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM");
    int result = 0;
    try {
        auto source = Load(argv[1], L"LAVSplitter.ax", L"{B98D13E7-55DB-4385-A33D-09FD1BA26338}");
        CComQIPtr<ILAVFSettings> splitterSettings(source);
        Check(splitterSettings->SetRuntimeConfig(TRUE), "splitter runtime settings");
        CComQIPtr<IFileSourceFilter> file(source);
        Check(file->Load(argv[2], nullptr), "open TS");
        auto audio = Load(argv[1], L"LAVAudio.ax", L"{E8E73B6B-4CB3-44A4-BE99-4F7BCB96E491}");
        CComQIPtr<ILAVAudioSettings> audioSettings(audio);
        Check(audioSettings->SetRuntimeConfig(TRUE), "audio runtime settings");
        HRESULT hr;
        auto *capture = new AudioCapture(&hr);
        Check(hr, "capture");
        CComPtr<IBaseFilter> sink;
        Check(capture->QueryInterface(IID_IBaseFilter, reinterpret_cast<void **>(&sink)), "capture interface");
        CComPtr<IGraphBuilder> graph;
        Check(graph.CoCreateInstance(CLSID_FilterGraph), "graph");
        Check(graph->AddFilter(source, L"LAV Source"), "add source");
        Check(graph->AddFilter(audio, L"LAV Audio"), "add decoder");
        Check(graph->AddFilter(sink, L"PCM Capture"), "add sink");
        Check(graph->ConnectDirect(Pin(source, PINDIR_OUTPUT, &MEDIATYPE_Audio), Pin(audio, PINDIR_INPUT), nullptr), "connect source audio");
        Check(graph->ConnectDirect(Pin(audio, PINDIR_OUTPUT), Pin(sink, PINDIR_INPUT), nullptr), "connect PCM");
        CComPtr<IBaseFilter> video, videoSink;
        VideoCapture *videoCapture = nullptr;
        if (argc == 4 && std::wstring(argv[3]) == L"--av") {
            video = Load(argv[1], L"LAVVideo.ax", L"{EE30215D-164F-4A92-A4EB-9D4C13390F9F}");
            CComQIPtr<ILAVVideoSettings> videoSettings(video);
            Check(videoSettings->SetRuntimeConfig(TRUE), "video runtime settings");
            Check(videoSettings->SetHWAccel(HWAccel_None), "software video decode");
            videoCapture = new VideoCapture(&hr);
            Check(hr, "video capture");
            Check(videoCapture->QueryInterface(IID_IBaseFilter, reinterpret_cast<void **>(&videoSink)), "video capture interface");
            Check(graph->AddFilter(video, L"LAV Video"), "add video decoder");
            Check(graph->AddFilter(videoSink, L"Video Capture"), "add video sink");
            Check(graph->ConnectDirect(Pin(source, PINDIR_OUTPUT, &MEDIATYPE_Video), Pin(video, PINDIR_INPUT), nullptr), "connect source video");
            Check(graph->ConnectDirect(Pin(video, PINDIR_OUTPUT), Pin(videoSink, PINDIR_INPUT), nullptr), "connect decoded video");
        }
        CComQIPtr<IMediaFilter> timing(graph);
        Check(timing->SetSyncSource(nullptr), "disable clock");
        CComQIPtr<IMediaControl> control(graph);
        CComQIPtr<IMediaSeeking> seeking(graph);
        CComQIPtr<IMediaEvent> events(graph);
        REFERENCE_TIME duration = 0;
        Check(seeking->GetDuration(&duration), "duration");
        struct Segment { const char *name; double start, stop; };
        std::vector<Segment> segments = {
            {"natural-crossing", 0, 20}, {"forward-seek", 12, 14},
            {"backward-seek", 2, 4}, {"forward-again", 20, 22},
            {"crossing-seek", 8, 12}, {"backward-again", 2, 4},
            {"forward-minute", 60, 62}
        };
        if (argc == 4 && std::wstring(argv[3]) == L"--full")
            segments = {{"whole-file", 0, duration / 10000000.0}};
        for (const auto &segment : segments) {
            Check(control->Pause(), "pause");
            capture->Reset();
            if (videoCapture) videoCapture->buffers = 0;
            REFERENCE_TIME start = static_cast<REFERENCE_TIME>(segment.start * 10000000.0);
            REFERENCE_TIME stop = static_cast<REFERENCE_TIME>(segment.stop * 10000000.0);
            Check(seeking->SetPositions(&start, AM_SEEKING_AbsolutePositioning, &stop, AM_SEEKING_AbsolutePositioning), "seek");
            Check(control->Run(), "run");
            long eventCode = 0;
            hr = events->WaitForCompletion(segment.stop - segment.start > 60 ? 120000 : 20000, &eventCode);
            Check(control->Pause(), "pause completed segment");
            const double pcmSeconds = capture->rate.load() ? double(capture->samples.load()) / capture->rate.load() : 0;
            const double expected = segment.stop - segment.start;
            // A video PTS can end a bounded graph before audio reaches its stop time.
            const double tolerance = segment.start == 0 ? 1.0 : (videoCapture ? 0.3 : 0.15);
            const bool pass = hr == S_OK && eventCode == EC_COMPLETE &&
                              pcmSeconds >= expected - tolerance && pcmSeconds <= expected + 0.15 && capture->nonzero.load() > 0 &&
                              (!videoCapture || videoCapture->buffers.load() > 0);
            std::printf("%s %s start=%.3f stop=%.3f pcm_seconds=%.6f buffers=%llu nonzero_buffers=%llu first=%lld last=%lld video_buffers=%llu event=%ld hr=0x%08lX\n",
                pass ? "PASS" : "FAIL", segment.name, segment.start, segment.stop, pcmSeconds,
                capture->buffers.load(), capture->nonzero.load(), capture->first.load(), capture->last.load(),
                videoCapture ? videoCapture->buffers.load() : 0, eventCode, static_cast<unsigned long>(hr));
            std::fflush(stdout);
            if (!pass) ++result;
            if (FAILED(hr)) break;
        }
        Check(control->Stop(), "stop");
    } catch (...) { result = 10; }
    CoUninitialize();
    return result;
}
