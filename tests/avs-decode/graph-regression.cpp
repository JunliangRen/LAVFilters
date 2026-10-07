#define NOMINMAX
#include <windows.h>
#include <streams.h>
#include <dvdmedia.h>
#include <atlbase.h>
#include <bcrypt.h>
#include <algorithm>
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>
#include "LAVVideoSettings.h"
#include "LAVSplitterSettings.h"

HINSTANCE g_hInst = nullptr;
DWORD g_amPlatform = VER_PLATFORM_WIN32_NT;

static void Check(HRESULT hr, const char *operation)
{
    if (FAILED(hr)) {
        std::fprintf(stderr, "%s: 0x%08lX\n", operation, static_cast<unsigned long>(hr));
        throw hr;
    }
}

class Hash
{
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::vector<BYTE> object;
    ULONG length = 0;
public:
    explicit Hash(LPCWSTR name)
    {
        Check(BCryptOpenAlgorithmProvider(&algorithm, name, nullptr, 0), "hash algorithm");
        ULONG bytes = 0, size = 0;
        Check(BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<BYTE *>(&size), sizeof(size), &bytes, 0), "hash object size");
        object.resize(size);
        Check(BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH, reinterpret_cast<BYTE *>(&length), sizeof(length), &bytes, 0), "digest size");
        Check(BCryptCreateHash(algorithm, &hash, object.data(), size, nullptr, 0, 0), "create hash");
    }
    ~Hash() { if (hash) BCryptDestroyHash(hash); if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0); }
    void Add(const std::vector<BYTE> &data)
    {
        Check(BCryptHashData(hash, const_cast<BYTE *>(data.data()), static_cast<ULONG>(data.size()), 0), "hash pixels");
    }
    std::string Finish()
    {
        std::vector<BYTE> digest(length);
        Check(BCryptFinishHash(hash, digest.data(), length, 0), "finish hash");
        std::string result;
        const char *hex = "0123456789abcdef";
        for (BYTE b : digest) { result += hex[b >> 4]; result += hex[b & 15]; }
        return result;
    }
};

struct Frame
{
    REFERENCE_TIME start = -1, stop = -1;
    DWORD flags = 0;
    int width = 0, height = 0;
    std::string sha256;
};

static GUID Fourcc(DWORD code)
{
    GUID guid = {code, 0, 0x10, {0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71}};
    return guid;
}

class Capture final : public CBaseRenderer
{
    const bool high, nv12;
    const GUID subtype;
    Hash *aggregate = nullptr;
public:
    std::vector<Frame> frames;
    uint64_t bytes = 0, precisionSamples = 0;
    bool monotonic = true, timestamps = true;
    explicit Capture(HRESULT *hr, bool ten, bool semiplanar) : CBaseRenderer(CLSID_NULL, L"AVS pixel capture", nullptr, hr), high(ten), nv12(semiplanar),
        subtype(Fourcc(ten ? mmioFOURCC('P','0','1','0') : semiplanar ? mmioFOURCC('N','V','1','2') : mmioFOURCC('Y','V','1','2'))) { Reset(); }
    ~Capture() { delete aggregate; }
    HRESULT CheckMediaType(const CMediaType *mt) override
    {
        return mt->majortype == MEDIATYPE_Video && mt->subtype == subtype &&
            mt->formattype == FORMAT_VideoInfo2 && mt->FormatLength() >= sizeof(VIDEOINFOHEADER2) ? S_OK : VFW_E_TYPE_NOT_ACCEPTED;
    }
    HRESULT DoRenderSample(IMediaSample *sample) override
    {
        CMediaType media;
        HRESULT hr = m_pInputPin->ConnectionMediaType(&media);
        if (FAILED(hr)) return hr;
        const auto *vi = reinterpret_cast<const VIDEOINFOHEADER2 *>(media.Format());
        const int strideWidth = vi->bmiHeader.biWidth, storageHeight = std::abs(vi->bmiHeader.biHeight);
        const int width = vi->rcTarget.right > vi->rcTarget.left ? vi->rcTarget.right - vi->rcTarget.left : strideWidth;
        const int height = vi->rcTarget.bottom > vi->rcTarget.top ? vi->rcTarget.bottom - vi->rcTarget.top : storageHeight;
        if (width <= 0 || height <= 0 || (width & 1) || (height & 1) || width > strideWidth || height > storageHeight) return E_FAIL;
        const size_t expected = size_t(strideWidth) * storageHeight * 3 / (high ? 1 : 2);
        if (size_t(sample->GetActualDataLength()) < expected) return E_FAIL;
        BYTE *data = nullptr;
        hr = sample->GetPointer(&data);
        if (FAILED(hr)) return hr;
        // Normalize padded YV12/P010 buffers to tightly packed planar Y,U,V.
        // P010 stores 10-bit words at bit 6; the reference is yuv420p10le.
        std::vector<BYTE> canonical(size_t(width) * height * 3 / (high ? 1 : 2));
        if (high) {
            auto *output = reinterpret_cast<uint16_t *>(canonical.data());
            const auto *input = reinterpret_cast<const uint16_t *>(data);
            for (int row = 0; row < height; ++row)
                for (int col = 0; col < width; ++col) {
                    const uint16_t word = input[size_t(row) * strideWidth + col] >> 6;
                    output[size_t(row) * width + col] = word;
                    precisionSamples += (word & 3) != 0;
                }
            const size_t chroma = size_t(strideWidth) * storageHeight, luma = size_t(width) * height;
            for (int row = 0; row < height / 2; ++row)
                for (int col = 0; col < width / 2; ++col) {
                    output[luma + size_t(row) * width / 2 + col] = input[chroma + size_t(row) * strideWidth + col * 2] >> 6;
                    output[luma * 5 / 4 + size_t(row) * width / 2 + col] = input[chroma + size_t(row) * strideWidth + col * 2 + 1] >> 6;
                }
        } else if (nv12) {
            const size_t luma = size_t(width) * height, chroma = size_t(strideWidth) * storageHeight;
            for (int row = 0; row < height; ++row)
                std::copy_n(data + size_t(row) * strideWidth, width, canonical.data() + size_t(row) * width);
            for (int row = 0; row < height / 2; ++row)
                for (int col = 0; col < width / 2; ++col) {
                    canonical[luma + size_t(row) * width / 2 + col] = data[chroma + size_t(row) * strideWidth + col * 2];
                    canonical[luma * 5 / 4 + size_t(row) * width / 2 + col] = data[chroma + size_t(row) * strideWidth + col * 2 + 1];
                }
        } else {
            size_t target = 0;
            for (int plane : {0, 2, 1}) {
                const int rows = plane ? height / 2 : height, columns = plane ? width / 2 : width;
                const int stride = plane ? strideWidth / 2 : strideWidth;
                const size_t origin = plane ? size_t(strideWidth) * storageHeight * (plane == 2 ? 5 : 4) / 4 : 0;
                for (int row = 0; row < rows; ++row) {
                    std::copy_n(data + origin + size_t(row) * stride, columns, canonical.data() + target);
                    target += columns;
                }
            }
        }
        Frame frame;
        frame.width = width; frame.height = height;
        hr = sample->GetTime(&frame.start, &frame.stop);
        if (FAILED(hr)) timestamps = false;
        if (!frames.empty() && frame.start <= frames.back().start) monotonic = false;
        CComQIPtr<IMediaSample2> extended(sample);
        AM_SAMPLE2_PROPERTIES properties{};
        if (extended && SUCCEEDED(extended->GetProperties(sizeof(properties), reinterpret_cast<BYTE *>(&properties))))
            frame.flags = properties.dwTypeSpecificFlags;
        try {
            Hash hash(BCRYPT_SHA256_ALGORITHM);
            hash.Add(canonical); frame.sha256 = hash.Finish();
            aggregate->Add(canonical);
        } catch (...) { return E_FAIL; }
        bytes += canonical.size();
        frames.push_back(std::move(frame));
        return S_OK;
    }
    void Reset()
    {
        frames.clear(); bytes = precisionSamples = 0; monotonic = timestamps = true;
        delete aggregate; aggregate = new Hash(BCRYPT_MD5_ALGORITHM);
    }
    std::string Finish() { return aggregate->Finish(); }
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
                const bool matches = mt->majortype == *majorType;
                DeleteMediaType(mt);
                if (matches) return pin;
            }
        }
        pin.Release();
    }
    Check(E_FAIL, "find video pin");
    return nullptr;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc < 6 || argc > 8) {
        std::fprintf(stderr, "graph-regression.exe PACKAGE FIXTURE BITS THREADS OUTPUT.json [NV12|YV12|P010] [TIMEOUT_MS]\n");
        return 2;
    }
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!AddDllDirectory(argv[1])) return 3;
    Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM");
    int result = 0;
    FILE *output = nullptr;
    try {
        const long timeoutMs = argc == 8 ? _wtoi(argv[7]) : 120000;
        if (timeoutMs <= 0) Check(E_INVALIDARG, "segment timeout");
        const bool high = _wtoi(argv[3]) == 10;
        const bool nv12 = argc >= 7 && std::wstring(argv[6]) == L"NV12";
        auto source = Load(argv[1], L"LAVSplitter.ax", L"{B98D13E7-55DB-4385-A33D-09FD1BA26338}");
        CComQIPtr<ILAVFSettings> splitterSettings(source);
        Check(splitterSettings ? splitterSettings->SetRuntimeConfig(TRUE) : E_NOINTERFACE, "splitter runtime config");
        CComQIPtr<IFileSourceFilter> file(source);
        Check(file ? file->Load(argv[2], nullptr) : E_NOINTERFACE, "open fixture");
        auto video = Load(argv[1], L"LAVVideo.ax", L"{EE30215D-164F-4A92-A4EB-9D4C13390F9F}");
        CComQIPtr<ILAVVideoSettings> settings(video);
        Check(settings ? settings->SetRuntimeConfig(TRUE) : E_NOINTERFACE, "video runtime config");
        Check(settings->SetHWAccel(HWAccel_None), "software decode");
        Check(settings->SetNumThreads(_wtoi(argv[4])), "decoder threads");
        Check(settings->SetDeinterlacingMode(DeintMode_Disable), "disable deinterlacing");
        for (int i = 0; i < LAVOutPixFmt_NB; ++i)
            Check(settings->SetPixelFormat(static_cast<LAVOutPixFmts>(i), i == (high ? LAVOutPixFmt_P010 : nv12 ? LAVOutPixFmt_NV12 : LAVOutPixFmt_YV12)), "output format");
        HRESULT hr = S_OK;
        auto *capture = new Capture(&hr, high, nv12);
        Check(hr, "capture");
        CComPtr<IBaseFilter> sink;
        Check(capture->QueryInterface(IID_IBaseFilter, reinterpret_cast<void **>(&sink)), "capture interface");
        CComPtr<IGraphBuilder> graph;
        Check(graph.CoCreateInstance(CLSID_FilterGraph), "graph");
        Check(graph->AddFilter(source, L"LAV Source"), "add source");
        Check(graph->AddFilter(video, L"LAV Video"), "add decoder");
        Check(graph->AddFilter(sink, L"Pixel Capture"), "add capture");
        Check(graph->ConnectDirect(Pin(source, PINDIR_OUTPUT, &MEDIATYPE_Video), Pin(video, PINDIR_INPUT), nullptr), "connect source video");
        Check(graph->ConnectDirect(Pin(video, PINDIR_OUTPUT), Pin(sink, PINDIR_INPUT), nullptr), "connect decoded video");
        CComQIPtr<IMediaFilter> timing(graph);
        Check(timing->SetSyncSource(nullptr), "disable clock");
        CComQIPtr<IMediaControl> control(graph);
        CComQIPtr<IMediaSeeking> seeking(graph);
        CComQIPtr<IMediaEvent> events(graph);
        REFERENCE_TIME duration = 0;
        Check(seeking->GetDuration(&duration), "duration");
        CMediaType inputType;
        Check(Pin(video, PINDIR_INPUT)->ConnectionMediaType(&inputType), "decoder input type");
        CComQIPtr<ILAVVideoStatus> status(video);
        const LPCWSTR decoder = status ? status->GetActiveDecoderName() : L"unknown";
        char decoderName[128]{};
        WideCharToMultiByte(CP_UTF8, 0, decoder ? decoder : L"unknown", -1, decoderName, sizeof(decoderName), nullptr, nullptr);
        if (_wfopen_s(&output, argv[5], L"wb")) Check(E_FAIL, "open JSON report");
        std::fprintf(output, "{\"pointer_bits\":%zu,\"timeout_ms\":%ld,\"duration\":%lld,\"bits\":%d,\"output_format\":\"%s\",\"threads\":%d,\"decoder\":\"%s\",\"input_fourcc\":%lu,\"segments\":[\r\n", sizeof(void *) * 8, timeoutMs, duration, high ? 10 : 8, high ? "P010" : nv12 ? "NV12" : "YV12", _wtoi(argv[4]), decoderName, inputType.subtype.Data1);
        struct Segment { const char *name; REFERENCE_TIME start, stop; bool seek; };
        const REFERENCE_TIME middle = duration / 2, earlier = duration / 5, span = std::min<REFERENCE_TIME>(10000000, duration / 4);
        std::vector<Segment> segments = {{"whole-file", 0, duration, false}, {"forward-seek", middle, middle + span, true},
            {"backward-seek", earlier, earlier + span, true}, {"forward-again", middle, middle + span, true}, {"whole-replay", 0, MAXLONGLONG, true}};
        for (size_t index = 0; index < segments.size(); ++index) {
            const auto &segment = segments[index];
            Check(control->Stop(), "stop before segment");
            capture->Reset();
            long oldCode = 0; LONG_PTR firstParam = 0, secondParam = 0;
            while (events->GetEvent(&oldCode, &firstParam, &secondParam, 0) == S_OK) events->FreeEventParams(oldCode, firstParam, secondParam);
            if (segment.seek) {
                REFERENCE_TIME start = segment.start, stop = segment.stop;
                Check(seeking->SetPositions(&start, AM_SEEKING_AbsolutePositioning, &stop, AM_SEEKING_AbsolutePositioning), "seek segment");
            }
            Check(control->Run(), "run");
            long eventCode = 0;
            hr = events->WaitForCompletion(timeoutMs, &eventCode);
            Check(control->Stop(), "stop completed segment");
            const bool pass = hr == S_OK && eventCode == EC_COMPLETE && !capture->frames.empty() && capture->timestamps && capture->monotonic;
            if (!pass) ++result;
            const std::string md5 = capture->Finish();
            std::fprintf(output, "%s{\"name\":\"%s\",\"start\":%lld,\"stop\":%lld,\"event\":%ld,\"hr\":%ld,\"frames\":%zu,\"bytes\":%llu,\"precision_samples\":%llu,\"timestamps\":%s,\"monotonic\":%s,\"md5\":\"%s\",\"pass\":%s,\"frame_data\":[\r\n",
                index ? "," : "", segment.name, segment.start, segment.stop, eventCode, hr, capture->frames.size(), static_cast<unsigned long long>(capture->bytes), static_cast<unsigned long long>(capture->precisionSamples),
                capture->timestamps ? "true" : "false", capture->monotonic ? "true" : "false", md5.c_str(), pass ? "true" : "false");
            for (size_t frameIndex = 0; frameIndex < capture->frames.size(); ++frameIndex) {
                const Frame &frame = capture->frames[frameIndex];
                std::fprintf(output, "%s{\"start\":%lld,\"stop\":%lld,\"flags\":%lu,\"width\":%d,\"height\":%d,\"sha256\":\"%s\"}\r\n", frameIndex ? "," : "", frame.start, frame.stop, frame.flags, frame.width, frame.height, frame.sha256.c_str());
            }
            std::fprintf(output, "]}\r\n");
            std::fflush(output);
            std::printf("%s %s frames=%zu md5=%s event=%ld hr=0x%08lX\n", pass ? "PASS" : "FAIL", segment.name, capture->frames.size(), md5.c_str(), eventCode, static_cast<unsigned long>(hr));
            std::fflush(stdout);
            if (FAILED(hr)) break;
        }
        std::fprintf(output, "]}\r\n");
    } catch (...) { result = 10; }
    if (output) std::fclose(output);
    CoUninitialize();
    return result;
}
