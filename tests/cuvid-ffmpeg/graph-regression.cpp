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
#include <cwchar>
#include <cstddef>
#include <atomic>
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
    REFERENCE_TIME avgDuration = 0;
    DWORD flags = 0;
    DWORD mediaInterlaceFlags = 0;
    int width = 0, height = 0;
    std::string sha256;
    unsigned phase = 0;
    std::wstring decoder;
};

static GUID Fourcc(DWORD code)
{
    GUID guid = {code, 0, 0x10, {0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71}};
    return guid;
}

class Capture final : public CBaseRenderer
{
    const bool high, nv12, chroma422, chroma444;
    const int bitDepth;
    const GUID subtype;
    Hash *aggregate = nullptr;
public:
    std::vector<Frame> frames;
    CComPtr<ILAVVideoStatus> status;
    unsigned phase = 0;
    uint64_t bytes = 0, precisionSamples = 0;
    bool monotonic = true, timestamps = true;
    explicit Capture(HRESULT *hr, int depth, bool semiplanar, bool two, bool three)
        : CBaseRenderer(CLSID_NULL, L"CUVID pixel capture", nullptr, hr), high(depth > 8), nv12(semiplanar), chroma422(two), chroma444(three), bitDepth(depth),
          subtype(Fourcc(three ? mmioFOURCC('Y','4','1','6') : two ? mmioFOURCC('P','2','1','0') : depth > 10 ? mmioFOURCC('P','0','1','6') : depth > 8 ? mmioFOURCC('P','0','1','0') : semiplanar ? mmioFOURCC('N','V','1','2') : mmioFOURCC('Y','V','1','2'))) { Reset(); }
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
        const size_t expected = chroma444 ? size_t(strideWidth) * storageHeight * 8 : size_t(strideWidth) * storageHeight * (chroma422 ? 4 : 3) / (high ? 1 : 2);
        if (size_t(sample->GetActualDataLength()) < expected) return E_FAIL;
        BYTE *data = nullptr;
        hr = sample->GetPointer(&data);
        if (FAILED(hr)) return hr;
        // Normalize padded YV12/P010 buffers to tightly packed planar Y,U,V.
        // P010 stores 10-bit words at bit 6; the reference is yuv420p10le.
        std::vector<BYTE> canonical(chroma444 ? size_t(width) * height * 6 : size_t(width) * height * (chroma422 ? 4 : 3) / (high ? 1 : 2));
        if (chroma444) {
            auto *output = reinterpret_cast<uint16_t *>(canonical.data());
            const auto *input = reinterpret_cast<const uint16_t *>(data);
            const size_t luma = size_t(width) * height;
            for (int row = 0; row < height; ++row)
                for (int col = 0; col < width; ++col) {
                    const size_t origin = (size_t(row) * strideWidth + col) * 4, target = size_t(row) * width + col;
                    output[target] = input[origin + 1] >> (16 - bitDepth);
                    output[luma + target] = input[origin] >> (16 - bitDepth);
                    output[luma * 2 + target] = input[origin + 2] >> (16 - bitDepth);
                    precisionSamples += (output[target] & ((1 << (bitDepth - 8)) - 1)) != 0;
                }
        } else if (high) {
            auto *output = reinterpret_cast<uint16_t *>(canonical.data());
            const auto *input = reinterpret_cast<const uint16_t *>(data);
            for (int row = 0; row < height; ++row)
                for (int col = 0; col < width; ++col) {
                    const uint16_t word = input[size_t(row) * strideWidth + col] >> (16 - bitDepth);
                    output[size_t(row) * width + col] = word;
                    precisionSamples += (word & 3) != 0;
                }
            const size_t chroma = size_t(strideWidth) * storageHeight, luma = size_t(width) * height;
            for (int row = 0; row < height / (chroma422 ? 1 : 2); ++row)
                for (int col = 0; col < width / 2; ++col) {
                    output[luma + size_t(row) * width / 2 + col] = input[chroma + size_t(row) * strideWidth + col * 2] >> (16 - bitDepth);
                    output[luma + luma / (chroma422 ? 2 : 4) + size_t(row) * width / 2 + col] = input[chroma + size_t(row) * strideWidth + col * 2 + 1] >> (16 - bitDepth);
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
        frame.phase = phase;
        if (status) {
            const WCHAR *name = status->GetActiveDecoderName();
            frame.decoder = name ? name : L"unknown";
        }
        frame.width = width; frame.height = height;
        frame.avgDuration = vi->AvgTimePerFrame;
        frame.mediaInterlaceFlags = vi->dwInterlaceFlags;
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

static std::string Json(const std::wstring &value)
{
    const int count = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string utf8(count, '\0'), escaped;
    if (count) WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), &utf8[0], count, nullptr, nullptr);
    const char *hex = "0123456789abcdef";
    for (unsigned char c : utf8) {
        if (c == '"' || c == '\\') { escaped += '\\'; escaped += c; }
        else if (c < 32) { escaped += "\\u00"; escaped += hex[c >> 4]; escaped += hex[c & 15]; }
        else escaped += c;
    }
    return '"' + escaped + '"';
}

struct DecoderStatus
{
    std::wstring decoder, device;
    HRESULT deviceHr = E_FAIL;
    bool matches = false;
};

static DecoderStatus ReadStatus(ILAVVideoStatus *status, const std::wstring &expected)
{
    DecoderStatus result;
    if (status) {
        const WCHAR *name = status->GetActiveDecoderName();
        result.decoder = name ? name : L"unknown";
        BSTR device = nullptr;
        result.deviceHr = status->GetHWAccelActiveDevice(&device);
        if (device) { result.device = device; SysFreeString(device); }
    }
    result.matches = result.decoder == (expected == L"software" ? L"avcodec" : expected);
    if (expected != L"software" && expected != L"avcodec")
        result.matches = result.matches && SUCCEEDED(result.deviceHr) && !result.device.empty();
    return result;
}

// Optional diagnostic pass-through. Normal validation connects source directly
// to LAV Video so decoder-specific upstream pin interfaces stay available.
class PacketTrace final : public CTransInPlaceFilter
{
    struct Packet { REFERENCE_TIME start, stop; long bytes; bool key, preroll; };
    FILE *stream = nullptr;
    std::wstring manifestPath;
    std::vector<Packet> packets;
    unsigned naluLength = 0;
    std::vector<REFERENCE_TIME> gates;
    size_t nextGate = 0;
    HANDLE reached = nullptr, resume = nullptr;
    REFERENCE_TIME gatePosition = MINLONGLONG;
    std::atomic<bool> cancelled{false};
    void WriteNalus(const BYTE *data, size_t bytes, unsigned length)
    {
        const BYTE prefix[] = {0, 0, 0, 1};
        while (bytes >= length) {
            size_t size = 0;
            for (unsigned index = 0; index < length; ++index) size = (size << 8) | data[index];
            data += length; bytes -= length;
            if (size > bytes) Check(E_FAIL, "invalid diagnostic NAL length");
            if (std::fwrite(prefix, 1, 4, stream) != 4 || std::fwrite(data, 1, size, stream) != size)
                Check(E_FAIL, "write diagnostic NAL");
            data += size; bytes -= size;
        }
        if (bytes) Check(E_FAIL, "truncated diagnostic NAL length");
    }
public:
    PacketTrace(HRESULT *hr) : CTransInPlaceFilter(L"Compressed packet trace", nullptr, CLSID_NULL, hr) {}
    ~PacketTrace() { Cancel(); Close(); if (reached) CloseHandle(reached); if (resume) CloseHandle(resume); }
    HRESULT CheckInputType(const CMediaType *type) override { return type->majortype == MEDIATYPE_Video ? S_OK : E_FAIL; }
    HRESULT Transform(IMediaSample *sample) override
    {
        if (!stream && gates.empty()) return E_UNEXPECTED;
        REFERENCE_TIME start = MINLONGLONG, stop = MINLONGLONG;
        sample->GetTime(&start, &stop);
        if (nextGate < gates.size() && sample->IsSyncPoint() == S_OK && start >= gates[nextGate]) {
            gatePosition = start;
            ++nextGate;
            SetEvent(reached);
            if (WaitForSingleObject(resume, 120000) != WAIT_OBJECT_0 || cancelled) return E_ABORT;
        }
        if (!stream) return S_OK;
        BYTE *data = nullptr;
        HRESULT hr = sample->GetPointer(&data);
        if (FAILED(hr)) return hr;
        const long bytes = sample->GetActualDataLength();
        Packet packet{MINLONGLONG, MINLONGLONG, bytes, sample->IsSyncPoint() == S_OK, sample->IsPreroll() == S_OK};
        sample->GetTime(&packet.start, &packet.stop);
        try {
            if (naluLength) WriteNalus(data, bytes, naluLength);
            else if (std::fwrite(data, 1, bytes, stream) != static_cast<size_t>(bytes)) return E_FAIL;
        } catch (...) { return E_FAIL; }
        packets.push_back(packet);
        return S_OK;
    }
    void GateAt(const std::vector<REFERENCE_TIME> &positions)
    {
        gates = positions; nextGate = 0; cancelled = false;
        reached = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        resume = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!reached || !resume) Check(HRESULT_FROM_WIN32(GetLastError()), "create live settings gate");
    }
    bool WaitGate(long timeout) { return WaitForSingleObject(reached, timeout) == WAIT_OBJECT_0; }
    REFERENCE_TIME GatePosition() const { return gatePosition; }
    void Continue() { SetEvent(resume); }
    void Cancel() { cancelled = true; if (resume) SetEvent(resume); }
    void Start(const std::wstring &directory, const char *segment)
    {
        Close(); packets.clear(); naluLength = 0;
        std::wstring name;
        for (const char *p = segment; *p; ++p) name += *p;
        const std::wstring stem = directory + L"\\" + name;
        manifestPath = stem + L".packets.json";
        if (_wfopen_s(&stream, (stem + L".es").c_str(), L"wb")) Check(E_FAIL, "open packet trace");
        CMediaType type;
        Check(GetPin(0)->ConnectionMediaType(&type), "trace media type");
        if (type.formattype == FORMAT_MPEG2Video && type.FormatLength() >= offsetof(MPEG2VIDEOINFO, dwSequenceHeader)) {
            const auto *info = reinterpret_cast<const MPEG2VIDEOINFO *>(type.Format());
            if (info->cbSequenceHeader > type.FormatLength() - offsetof(MPEG2VIDEOINFO, dwSequenceHeader))
                Check(E_FAIL, "diagnostic sequence header length");
            if (info->hdr.bmiHeader.biCompression == mmioFOURCC('A','V','C','1') || info->hdr.bmiHeader.biCompression == mmioFOURCC('a','v','c','1')) {
                naluLength = info->dwFlags ? info->dwFlags : 4;
                if (naluLength > 4) Check(E_FAIL, "diagnostic NAL length size");
                WriteNalus(reinterpret_cast<const BYTE *>(info->dwSequenceHeader), info->cbSequenceHeader, 2);
            } else if (info->cbSequenceHeader) {
                std::fwrite(info->dwSequenceHeader, 1, info->cbSequenceHeader, stream);
            }
        }
    }
    void Close()
    {
        if (!stream) return;
        std::fclose(stream); stream = nullptr;
        FILE *manifest = nullptr;
        if (_wfopen_s(&manifest, manifestPath.c_str(), L"wb")) return;
        std::fprintf(manifest, "{\"packets\":[\r\n");
        for (size_t index = 0; index < packets.size(); ++index) {
            const auto &packet = packets[index];
            std::fprintf(manifest, "%s{\"start\":%lld,\"stop\":%lld,\"bytes\":%ld,\"key\":%s,\"preroll\":%s}\r\n",
                index ? "," : "", packet.start, packet.stop, packet.bytes, packet.key ? "true" : "false", packet.preroll ? "true" : "false");
        }
        std::fprintf(manifest, "]}\r\n"); std::fclose(manifest);
    }
};

int wmain(int argc, wchar_t **argv)
{
    if (argc < 10 || argc > 14) {
        std::fprintf(stderr, "graph-regression.exe PACKAGE FIXTURE BITS THREADS OUTPUT.json FORMAT BACKEND DEINT EXPECTED_DECODER [DEVICE_INDEX] [TIMEOUT_MS] [PACKET_DIRECTORY] [LIVE_SCENARIO]\n"
            "FORMAT: NV12|YV12|P010|P016|P210|Y416; BACKEND: 0=software,1=old CUVID,6=FFmpeg CUVID; DEINT: disable|weave|aggressive-weave|adaptive-single|adaptive-double|adaptive-force|adaptive-force-double|adaptive-tff|adaptive-bff|force-yadif|force-bwdif|force-yadif-single|force-bwdif-single\n");
        return 2;
    }
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!AddDllDirectory(argv[1])) return 3;
    Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM");
    int result = 0;
    FILE *output = nullptr;
    try {
        const long timeoutMs = argc >= 12 ? _wtoi(argv[11]) : 120000;
        if (timeoutMs <= 0) Check(E_INVALIDARG, "segment timeout");
        const int bits = _wtoi(argv[3]);
        const bool high = bits > 8;
        const std::wstring format = argv[6], mode = argv[8], expectedDecoder = argv[9];
        const bool live = argc == 14;
        const std::wstring liveScenario = live ? argv[13] : L"";
        const bool liveSoftware = liveScenario == L"yadif" || liveScenario == L"bwdif";
        const bool swToHW = liveScenario == L"sw-to-hw" || liveScenario == L"sw-hw-sw";
        const bool recordPackets = argc >= 13 && std::wstring(argv[12]) != L"-";
        const bool softwareDeint = mode == L"force-yadif" || mode == L"force-bwdif" || mode == L"force-yadif-single" || mode == L"force-bwdif-single";
        const bool singleSoftware = mode == L"force-yadif-single" || mode == L"force-bwdif-single";
        if (live && ((swToHW ? !softwareDeint : mode != (liveSoftware ? L"adaptive-force-double" : L"adaptive-double")) || _wtoi(argv[7]) != 6 ||
            (!swToHW && !liveSoftware && liveScenario != L"force" && liveScenario != L"tff" && liveScenario != L"bff" && liveScenario != L"cycle")))
            Check(E_INVALIDARG, "live settings scenario");
        const bool nv12 = format == L"NV12", chroma422 = format == L"P210", chroma444 = format == L"Y416";
        if ((bits != 8 && bits != 10 && bits != 12) || (high && format != L"P010" && format != L"P016" && !chroma422 && !chroma444) || (!high && format != L"NV12" && format != L"YV12") || (bits == 12 && format != L"P016"))
            Check(E_INVALIDARG, "output format and bit depth");
        const int backend = _wtoi(argv[7]);
        if (backend != 0 && backend != 1 && backend != 6) Check(E_INVALIDARG, "backend");
        const auto hwAccel = static_cast<LAVHWAccel>(backend);
        const DWORD requestedDevice = argc >= 11 ? static_cast<DWORD>(std::wcstol(argv[10], nullptr, 10)) : LAVHWACCEL_DEVICE_DEFAULT;
        const bool force = mode == L"adaptive-force" || mode == L"adaptive-force-double" || softwareDeint;
        const bool aggressive = mode == L"aggressive-weave" || mode == L"adaptive-aggressive-double";
        const bool adaptive = mode == L"adaptive-single" || mode == L"adaptive-double" || mode == L"adaptive-aggressive-double" || (force && !softwareDeint) || mode == L"adaptive-tff" || mode == L"adaptive-bff";
        if (!adaptive && !softwareDeint && mode != L"disable" && mode != L"weave" && mode != L"aggressive-weave") Check(E_INVALIDARG, "deinterlace mode");
        auto source = Load(argv[1], L"LAVSplitter.ax", L"{B98D13E7-55DB-4385-A33D-09FD1BA26338}");
        CComQIPtr<ILAVFSettings> splitterSettings(source);
        Check(splitterSettings ? splitterSettings->SetRuntimeConfig(TRUE) : E_NOINTERFACE, "splitter runtime config");
        CComQIPtr<IFileSourceFilter> file(source);
        Check(file ? file->Load(argv[2], nullptr) : E_NOINTERFACE, "open fixture");
        auto video = Load(argv[1], L"LAVVideo.ax", L"{EE30215D-164F-4A92-A4EB-9D4C13390F9F}");
        CComQIPtr<ILAVVideoSettings> settings(video);
        Check(settings ? settings->SetRuntimeConfig(TRUE) : E_NOINTERFACE, "video runtime config");
        Check(settings->SetHWAccel(hwAccel), "configure backend");
        if (settings->GetHWAccel() != hwAccel) Check(E_FAIL, "backend setting round trip");
        const DWORD supportBefore = settings->CheckHWAccelSupport(hwAccel);
        const DWORD numDevices = backend ? settings->GetHWAccelNumDevices(hwAccel) : 0;
        std::string devices = "[";
        for (DWORD index = 0; index < numDevices; ++index) {
            BSTR name = nullptr;
            DWORD identifier = 0;
            const HRESULT deviceHr = settings->GetHWAccelDeviceInfo(hwAccel, index, &name, &identifier);
            if (index) devices += ',';
            devices += "{\"index\":" + std::to_string(index) + ",\"identifier\":" + std::to_string(identifier) + ",\"hr\":" + std::to_string(deviceHr) + ",\"name\":" + Json(name ? name : L"") + "}";
            if (name) SysFreeString(name);
            Check(deviceHr, "enumerate device");
        }
        devices += ']';
        if (backend && expectedDecoder != L"software" && (!supportBefore || (backend == 6 && !numDevices))) Check(E_FAIL, "hardware support and devices");
        if (backend == 6) Check(settings->SetHWAccelDeviceIndex(hwAccel, requestedDevice, 0), "configure GPU device");
        else if (backend == 1) Check(settings->SetGPUDeviceIndex(requestedDevice), "configure legacy GPU device");
        DWORD returnedDeviceIdentifier = 123;
        const DWORD returnedDevice = settings->GetHWAccelDeviceIndex(hwAccel, &returnedDeviceIdentifier);
        const bool invalidDevice = backend == 6 && requestedDevice != LAVHWACCEL_DEVICE_DEFAULT && requestedDevice >= numDevices;
        const DWORD expectedDevice = invalidDevice ? LAVHWACCEL_DEVICE_DEFAULT : requestedDevice;
        if (backend == 6 && (returnedDevice != expectedDevice || returnedDeviceIdentifier != 0))
            Check(E_FAIL, "GPU device normalization round trip");
        DWORD deviceAfterApply = returnedDevice;
        const DWORD deviceSelectionRow = returnedDevice == LAVHWACCEL_DEVICE_DEFAULT ? 0 : returnedDevice + 1;
        if (backend == 6 && deviceSelectionRow > numDevices) Check(E_FAIL, "GPU selection row out of bounds");
        for (int i = 0; i < HWCodec_NB; ++i)
            Check(settings->SetHWAccelCodec(static_cast<LAVVideoHWCodec>(i), TRUE), "enable hardware codec");
        Check(settings->SetHWAccelResolutionFlags(LAVHWResFlag_SD | LAVHWResFlag_HD | LAVHWResFlag_UHD), "enable hardware resolutions");
        Check(settings->SetNumThreads(_wtoi(argv[4])), "decoder threads");
        Check(settings->SetDeinterlacingMode(mode == L"disable" ? DeintMode_Disable : force ? DeintMode_Force : aggressive ? DeintMode_Aggressive : DeintMode_Auto), "deinterlacing processing");
        Check(settings->SetDeintFieldOrder(mode == L"adaptive-tff" ? DeintFieldOrder_TopFieldFirst : mode == L"adaptive-bff" ? DeintFieldOrder_BottomFieldFirst : DeintFieldOrder_Auto), "deinterlacing field order");
        Check(settings->SetHWAccelDeintMode(adaptive ? HWDeintMode_Hardware : HWDeintMode_Weave), "GPU deinterlacing");
        Check(settings->SetHWAccelDeintOutput(mode == L"adaptive-double" || mode == L"adaptive-force-double" || mode == L"adaptive-aggressive-double" || (softwareDeint && !singleSoftware) ? DeintOutput_FramePerField : DeintOutput_FramePer2Field), "GPU field output");
        Check(settings->SetSWDeintMode((mode == L"force-yadif" || mode == L"force-yadif-single") ? SWDeintMode_YADIF : (mode == L"force-bwdif" || mode == L"force-bwdif-single") ? SWDeintMode_BWDIF : SWDeintMode_None), "software deinterlacing");
        Check(settings->SetSWDeintOutput(singleSoftware ? DeintOutput_FramePer2Field : DeintOutput_FramePerField), "software field output");
        for (int i = 0; i < LAVOutPixFmt_NB; ++i)
            Check(settings->SetPixelFormat(static_cast<LAVOutPixFmts>(i), i == (chroma444 ? LAVOutPixFmt_Y416 : chroma422 ? LAVOutPixFmt_P210 : bits == 12 ? LAVOutPixFmt_P016 : high ? LAVOutPixFmt_P010 : nv12 ? LAVOutPixFmt_NV12 : LAVOutPixFmt_YV12)), "output format");
        HRESULT hr = S_OK;
        auto *capture = new Capture(&hr, bits, nv12, chroma422, chroma444);
        Check(hr, "capture");
        CComPtr<IBaseFilter> sink;
        Check(capture->QueryInterface(IID_IBaseFilter, reinterpret_cast<void **>(&sink)), "capture interface");
        CComPtr<IGraphBuilder> graph;
        Check(graph.CoCreateInstance(CLSID_FilterGraph), "graph");
        Check(graph->AddFilter(source, L"LAV Source"), "add source");
        Check(graph->AddFilter(video, L"LAV Video"), "add decoder");
        Check(graph->AddFilter(sink, L"Pixel Capture"), "add capture");
        CComPtr<IBaseFilter> traceFilter;
        PacketTrace *trace = nullptr;
        if (recordPackets || live) {
            trace = new PacketTrace(&hr);
            Check(hr, "packet trace");
            Check(trace->QueryInterface(IID_IBaseFilter, reinterpret_cast<void **>(&traceFilter)), "packet trace interface");
            Check(graph->AddFilter(traceFilter, L"Packet Trace"), "add packet trace");
            Check(graph->ConnectDirect(Pin(source, PINDIR_OUTPUT, &MEDIATYPE_Video), Pin(traceFilter, PINDIR_INPUT), nullptr), "connect packet trace input");
            Check(graph->ConnectDirect(Pin(traceFilter, PINDIR_OUTPUT), Pin(video, PINDIR_INPUT), nullptr), "connect packet trace output");
        } else {
            Check(graph->ConnectDirect(Pin(source, PINDIR_OUTPUT, &MEDIATYPE_Video), Pin(video, PINDIR_INPUT), nullptr), "connect source video");
        }
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
        REFERENCE_TIME inputAvgDuration = 0;
        if (inputType.formattype == FORMAT_VideoInfo2 || inputType.formattype == FORMAT_MPEG2Video)
            inputAvgDuration = reinterpret_cast<const VIDEOINFOHEADER2 *>(inputType.Format())->AvgTimePerFrame;
        else if (inputType.formattype == FORMAT_VideoInfo || inputType.formattype == FORMAT_MPEGVideo)
            inputAvgDuration = reinterpret_cast<const VIDEOINFOHEADER *>(inputType.Format())->AvgTimePerFrame;
        CComQIPtr<ILAVVideoStatus> status(video);
        capture->status = status;
        const DecoderStatus connected = ReadStatus(status, expectedDecoder);
        if (invalidDevice) {
            // Runtime-only state models an ordinal persisted before a device
            // disappeared. Applying the returned Automatic value must clear it.
            Check(settings->SetHWAccelDeviceIndex(hwAccel, returnedDevice, static_cast<DWORD>(-1)), "apply normalized Automatic device");
            deviceAfterApply = settings->GetHWAccelDeviceIndex(hwAccel, nullptr);
            if (deviceAfterApply != LAVHWACCEL_DEVICE_DEFAULT) Check(E_FAIL, "GPU Automatic Apply round trip");
        }

        if (_wfopen_s(&output, argv[5], L"wb")) Check(E_FAIL, "open JSON report");
        std::fprintf(output, "{\"pointer_bits\":%zu,\"timeout_ms\":%ld,\"duration\":%lld,\"bits\":%d,\"output_format\":%s,\"threads\":%d,\"backend\":%d,\"deint\":%s,\"expected_decoder\":%s,\"decoder\":%s,\"active_device\":%s,\"requested_device\":%lu,\"returned_device\":%lu,\"returned_device_identifier\":%lu,\"device_after_apply\":%lu,\"device_selection_row\":%lu,\"support_before\":%lu,\"devices\":%s,\"input_fourcc\":%lu,\"input_avg_duration\":%lld,\"live_scenario\":%s,\"segments\":[\r\n",
            sizeof(void *) * 8, timeoutMs, duration, bits, Json(format).c_str(), _wtoi(argv[4]), backend, Json(mode).c_str(), Json(expectedDecoder).c_str(),
            Json(connected.decoder).c_str(), Json(connected.device).c_str(), requestedDevice, returnedDevice, returnedDeviceIdentifier, deviceAfterApply, deviceSelectionRow, supportBefore, devices.c_str(), inputType.subtype.Data1, inputAvgDuration, Json(liveScenario).c_str());
        struct LiveChange { unsigned phase; REFERENCE_TIME packetStart, lastOutputStart; size_t captured; };
        std::vector<LiveChange> liveChanges;
        struct Segment { const char *name; REFERENCE_TIME start, stop; bool seek; };
        const REFERENCE_TIME middle = duration / 2, earlier = duration / 5, span = std::min<REFERENCE_TIME>(10000000, duration / 4);
        std::vector<Segment> segments = {{"whole-file", 0, duration, false}, {"forward-seek", middle, middle + span, true},
            {"backward-seek", earlier, earlier + span, true}, {"forward-again", middle, middle + span, true}, {"whole-replay", 0, MAXLONGLONG, true}};
        if (live) {
            segments = {{"live-settings", 0, duration, false}};
            trace->GateAt(swToHW ? (liveScenario == L"sw-hw-sw" ? std::vector<REFERENCE_TIME>{duration / 4, duration * 3 / 4} : std::vector<REFERENCE_TIME>{duration / 2}) : liveSoftware ? std::vector<REFERENCE_TIME>{duration / 2} : std::vector<REFERENCE_TIME>{duration / 4, duration / 2, duration * 3 / 4});
        }
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
            if (recordPackets) trace->Start(argv[12], segment.name);
            Check(control->Run(), "run");
            if (live) {
                try {
                    for (unsigned phase = 1; phase <= (swToHW ? (liveScenario == L"sw-hw-sw" ? 2u : 1u) : liveSoftware ? 1u : 3u); ++phase) {
                        if (!trace->WaitGate(timeoutMs)) Check(E_FAIL, "live settings key-packet gate timeout");
                        if (swToHW) {
                            Check(settings->SetHWAccelDeintMode(phase == 1 ? HWDeintMode_Hardware : HWDeintMode_Weave), "switch software/hardware deinterlacing while running");
                        } else if (liveSoftware) {
                            Check(settings->SetHWAccelDeintMode(HWDeintMode_Weave), "switch hardware to weave while retaining Force");
                            Check(settings->SetSWDeintMode(liveScenario == L"yadif" ? SWDeintMode_YADIF : SWDeintMode_BWDIF), "enable software deinterlacing while running");
                        } else if (phase == 1) {
                            Check(settings->SetDeinterlacingMode(DeintMode_Disable), "disable deinterlacing while running");
                        } else if (phase == 2) {
                            Check(settings->SetDeinterlacingMode(DeintMode_Auto), "restore adaptive while running");
                            Check(settings->SetHWAccelDeintOutput(DeintOutput_FramePer2Field), "adaptive film while running");
                        } else if (liveScenario == L"cycle") {
                            Check(settings->SetHWAccelDeintOutput(DeintOutput_FramePerField), "restore adaptive video while running");
                        } else if (liveScenario == L"force") {
                            Check(settings->SetDeinterlacingMode(DeintMode_Force), "force deinterlacing while running");
                        } else {
                            Check(settings->SetDeintFieldOrder(liveScenario == L"tff" ? DeintFieldOrder_TopFieldFirst : DeintFieldOrder_BottomFieldFirst), "override field order while running");
                        }
                        liveChanges.push_back({phase, trace->GatePosition(), capture->frames.empty() ? -1LL : capture->frames.back().start, capture->frames.size()});
                        capture->phase = phase;
                        std::printf("live-change phase=%u gate-packet-start=%lld captured=%zu last-output-start=%lld\n", phase, trace->GatePosition(), capture->frames.size(), capture->frames.empty() ? -1LL : capture->frames.back().start);
                        trace->Continue();
                    }
                } catch (...) { trace->Cancel(); control->Stop(); throw; }
            }
            long eventCode = 0;
            hr = events->WaitForCompletion(timeoutMs, &eventCode);
            Check(control->Stop(), "stop completed segment");
            if (trace) trace->Close();
            const DecoderStatus current = ReadStatus(status, expectedDecoder);
            const bool pass = hr == S_OK && eventCode == EC_COMPLETE && !capture->frames.empty() && capture->timestamps && capture->monotonic && (live || current.matches);
            if (!pass) ++result;
            const std::string md5 = capture->Finish();
            std::fprintf(output, "%s{\"name\":\"%s\",\"start\":%lld,\"stop\":%lld,\"event\":%ld,\"hr\":%ld,\"frames\":%zu,\"bytes\":%llu,\"precision_samples\":%llu,\"timestamps\":%s,\"monotonic\":%s,\"md5\":\"%s\",\"pass\":%s,\"frame_data\":[\r\n",
                index ? "," : "", segment.name, segment.start, segment.stop, eventCode, hr, capture->frames.size(), static_cast<unsigned long long>(capture->bytes), static_cast<unsigned long long>(capture->precisionSamples),
                capture->timestamps ? "true" : "false", capture->monotonic ? "true" : "false", md5.c_str(), pass ? "true" : "false");
            for (size_t frameIndex = 0; frameIndex < capture->frames.size(); ++frameIndex) {
                const Frame &frame = capture->frames[frameIndex];
                std::fprintf(output, "%s{\"start\":%lld,\"stop\":%lld,\"avg_duration\":%lld,\"flags\":%lu,\"media_interlace_flags\":%lu,\"width\":%d,\"height\":%d,\"sha256\":\"%s\",\"phase\":%u,\"decoder\":%s}\r\n", frameIndex ? "," : "", frame.start, frame.stop, frame.avgDuration, frame.flags, frame.mediaInterlaceFlags, frame.width, frame.height, frame.sha256.c_str(), frame.phase, Json(frame.decoder).c_str());
            }
            std::fprintf(output, "],\"decoder\":%s,\"active_device\":%s,\"active_device_hr\":%ld,\"decoder_matches\":%s,\"support_after\":%lu}\r\n",
                Json(current.decoder).c_str(), Json(current.device).c_str(), current.deviceHr, current.matches ? "true" : "false", settings->CheckHWAccelSupport(hwAccel));
            std::fflush(output);
            std::printf("%s %s frames=%zu md5=%s event=%ld hr=0x%08lX\n", pass ? "PASS" : "FAIL", segment.name, capture->frames.size(), md5.c_str(), eventCode, static_cast<unsigned long>(hr));
            std::fflush(stdout);
            if (FAILED(hr)) break;
        }
        std::fprintf(output, "],\"live_changes\":[");
        for (size_t index = 0; index < liveChanges.size(); ++index) {
            const auto &change = liveChanges[index];
            std::fprintf(output, "%s{\"phase\":%u,\"gate_packet_start\":%lld,\"captured\":%zu,\"last_output_start\":%lld}",
                index ? "," : "", change.phase, change.packetStart, change.captured, change.lastOutputStart);
        }
        std::fprintf(output, "]}\r\n");
    } catch (...) { result = 10; }
    if (output) std::fclose(output);
    CoUninitialize();
    return result;
}
