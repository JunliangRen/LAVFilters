#include <windows.h>
#include <dshow.h>
#include <stdio.h>
#include <string>

struct FilterCase { const wchar_t* file; const wchar_t* clsid; };
int wmain(int argc, wchar_t** argv)
{
    if (argc != 2) return 2;
    wprintf(L"Native smoke process pointer_bits=%zu\n", sizeof(void*) * 8);
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    DLL_DIRECTORY_COOKIE directory = AddDllDirectory(argv[1]);
    if (!directory) { wprintf(L"AddDllDirectory failed: %lu\n", GetLastError()); return 3; }
    HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(init)) return 4;
    const FilterCase cases[] = {
        {L"LAVSplitter.ax", L"{171252A0-8820-4AFE-9DF8-5C92B2D66B04}"},
        {L"LAVSplitter.ax", L"{B98D13E7-55DB-4385-A33D-09FD1BA26338}"},
        {L"LAVAudio.ax", L"{E8E73B6B-4CB3-44A4-BE99-4F7BCB96E491}"},
        {L"LAVVideo.ax", L"{EE30215D-164F-4A92-A4EB-9D4C13390F9F}"}
    };
    int failures = 0;
    for (const auto& test : cases) {
        std::wstring path = std::wstring(argv[1]) + L"\\" + test.file;
        HMODULE module = LoadLibraryExW(path.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!module) { wprintf(L"FAIL %ls LoadLibrary: %lu\n", test.file, GetLastError()); ++failures; continue; }
        auto entry = reinterpret_cast<HRESULT (STDAPICALLTYPE*)(REFCLSID, REFIID, LPVOID*)>(GetProcAddress(module, "DllGetClassObject"));
        GUID clsid{};
        CLSIDFromString(test.clsid, &clsid);
        IClassFactory* factory = nullptr;
        HRESULT result = entry ? entry(clsid, IID_IClassFactory, reinterpret_cast<void**>(&factory)) : E_NOINTERFACE;
        IBaseFilter* filter = nullptr;
        if (SUCCEEDED(result)) result = factory->CreateInstance(nullptr, IID_IBaseFilter, reinterpret_cast<void**>(&filter));
        IEnumPins* pins = nullptr;
        if (SUCCEEDED(result)) result = filter->EnumPins(&pins);
        unsigned count = 0;
        if (SUCCEEDED(result)) {
            IPin* pin = nullptr;
            while (pins->Next(1, &pin, nullptr) == S_OK) { ++count; pin->Release(); }
        }
        wprintf(L"%ls %ls %ls HRESULT=0x%08lX pins=%u\n", SUCCEEDED(result) ? L"PASS" : L"FAIL", test.file, test.clsid, static_cast<unsigned long>(result), count);
        if (FAILED(result)) ++failures;
        if (pins) pins->Release();
        if (filter) filter->Release();
        if (factory) factory->Release();
        FreeLibrary(module);
    }
    std::wstring quickSync = std::wstring(argv[1]) + L"\\IntelQuickSyncDecoder.dll";
    HMODULE quickSyncModule = LoadLibraryExW(quickSync.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!quickSyncModule) { wprintf(L"FAIL IntelQuickSyncDecoder.dll LoadLibrary: %lu\n", GetLastError()); ++failures; }
    else { wprintf(L"PASS IntelQuickSyncDecoder.dll load\n"); FreeLibrary(quickSyncModule); }
    CoUninitialize();
    RemoveDllDirectory(directory);
    return failures ? 1 : 0;
}
