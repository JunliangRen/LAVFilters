#define NOMINMAX
#include <windows.h>
#include <streams.h>
#include <dvdmedia.h>
#include <atlbase.h>
#include <cstdio>
#include <string>
#include <atomic>
#include "LAVVideoSettings.h"
#include "LAVSplitterSettings.h"
HINSTANCE g_hInst=nullptr;
DWORD g_amPlatform=VER_PLATFORM_WIN32_NT;
static std::string Utf8(LPCWSTR s){if(!s)return "";int n=WideCharToMultiByte(CP_UTF8,0,s,-1,nullptr,0,nullptr,nullptr);std::string r(n,0);WideCharToMultiByte(CP_UTF8,0,s,-1,r.data(),n,nullptr,nullptr);r.pop_back();return r;}
static void Check(HRESULT hr,const char *op){printf("step=%s hr=0x%08lX time_ms=%llu\n",op,(unsigned long)hr,GetTickCount64());fflush(stdout);if(FAILED(hr))throw hr;}
static std::string Guid(REFGUID g){wchar_t t[64];StringFromGUID2(g,t,64);return Utf8(t);}
static void DumpType(const char *phase,const AM_MEDIA_TYPE &m){printf("type=%s major=%s subtype=%s format=%s bytes=%lu",phase,Guid(m.majortype).c_str(),Guid(m.subtype).c_str(),Guid(m.formattype).c_str(),(unsigned long)m.cbFormat);const BITMAPINFOHEADER *b=nullptr;REFERENCE_TIME dur=-1;if(m.formattype==FORMAT_VideoInfo2&&m.cbFormat>=sizeof(VIDEOINFOHEADER2)){auto v=(const VIDEOINFOHEADER2*)m.pbFormat;b=&v->bmiHeader;dur=v->AvgTimePerFrame;}else if(m.formattype==FORMAT_VideoInfo&&m.cbFormat>=sizeof(VIDEOINFOHEADER)){auto v=(const VIDEOINFOHEADER*)m.pbFormat;b=&v->bmiHeader;dur=v->AvgTimePerFrame;}else if(m.formattype==FORMAT_MPEG2Video&&m.cbFormat>=sizeof(MPEG2VIDEOINFO)){auto v=(const MPEG2VIDEOINFO*)m.pbFormat;b=&v->hdr.bmiHeader;dur=v->hdr.AvgTimePerFrame;printf(" profile=%lu level=%lu",(unsigned long)v->dwProfile,(unsigned long)v->dwLevel);}if(b)printf(" size=%ldx%ld bits=%u compression=0x%08lX frame_duration=%lld",b->biWidth,b->biHeight,b->biBitCount,(unsigned long)b->biCompression,dur);puts("");}
static CComPtr<IBaseFilter> Load(const std::wstring &dir,LPCWSTR name,LPCWSTR id){std::wstring p=dir+L"\\"+name;HMODULE h=LoadLibraryExW(p.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);if(!h)Check(HRESULT_FROM_WIN32(GetLastError()),"LoadLibrary");auto e=(HRESULT(STDAPICALLTYPE*)(REFCLSID,REFIID,void**))GetProcAddress(h,"DllGetClassObject");if(!e)Check(E_NOINTERFACE,"DllGetClassObject export");CLSID c;Check(CLSIDFromString(id,&c),"class id");CComPtr<IClassFactory> f;Check(e(c,IID_IClassFactory,(void**)&f),"factory");CComPtr<IBaseFilter> v;Check(f->CreateInstance(nullptr,IID_IBaseFilter,(void**)&v),"filter instance");printf("loaded=%s\n",Utf8(p.c_str()).c_str());return v;}
static CComPtr<IPin> Pin(IBaseFilter *f,PIN_DIRECTION dir,bool video=false){CComPtr<IEnumPins> e;Check(f->EnumPins(&e),"enum pins");CComPtr<IPin> p;while(e->Next(1,&p,nullptr)==S_OK){PIN_DIRECTION d;p->QueryDirection(&d);PIN_INFO i{};p->QueryPinInfo(&i);if(i.pFilter)i.pFilter->Release();printf("pin=%s dir=%d\n",Utf8(i.achName).c_str(),d);if(d==dir){if(!video)return p;CComPtr<IEnumMediaTypes> t;p->EnumMediaTypes(&t);AM_MEDIA_TYPE *m=nullptr;while(t&&t->Next(1,&m,nullptr)==S_OK){bool yes=m->majortype==MEDIATYPE_Video;DumpType("offered",*m);DeleteMediaType(m);if(yes)return p;}}p.Release();}Check(VFW_E_NOT_FOUND,"video pin");return nullptr;}
#include <bcrypt.h>
#include <mmreg.h>
#include <algorithm>
#include <cstdint>
#include <cstdarg>
#include <mutex>
#include <thread>
#include <vector>
#include "LAVAudioSettings.h"

static std::atomic<int> phase{-1};
static std::atomic<ULONGLONG> requestTick{0};
static std::vector<REFERENCE_TIME> targets;
static bool referenceMode=false;
static void LogCallback(void*,int level,const char*format,va_list arguments)
{
    if(level>40)return;
    char buffer[4096]{};std::vsnprintf(buffer,sizeof(buffer),format,arguments);
    std::fprintf(stderr,"avlog phase=%d wall_ms=%llu level=%d %s",phase.load(),GetTickCount64(),level,buffer);
    std::fflush(stderr);
}
static void EnableVerboseLog(const wchar_t*directory)
{
    HMODULE library=LoadLibraryExW((std::wstring(directory)+L"\\avutil-lav-61.dll").c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    auto callback=reinterpret_cast<void(*)(void(*)(void*,int,const char*,va_list))>(GetProcAddress(library,"av_log_set_callback"));
    auto level=reinterpret_cast<void(*)(int)>(GetProcAddress(library,"av_log_set_level"));
    Check(library&&callback&&level?S_OK:E_NOINTERFACE,"FFmpeg log callback");callback(LogCallback);level(40);
}

static CComPtr<IPin> AudioPin(IBaseFilter *filter)
{
    CComPtr<IEnumPins> pins;Check(filter->EnumPins(&pins),"audio enum pins");
    CComPtr<IPin> pin;
    while(pins->Next(1,&pin,nullptr)==S_OK){
        PIN_DIRECTION direction;pin->QueryDirection(&direction);
        if(direction==PINDIR_OUTPUT){
            CComPtr<IEnumMediaTypes> types;pin->EnumMediaTypes(&types);
            AM_MEDIA_TYPE *type=nullptr;
            while(types&&types->Next(1,&type,nullptr)==S_OK){
                bool match=type->majortype==MEDIATYPE_Audio;
                DeleteMediaType(type);if(match)return pin;
            }
        }
        pin.Release();
    }
    Check(VFW_E_NOT_FOUND,"audio output pin");return nullptr;
}

static std::string SHA256(const std::vector<BYTE>&bytes)
{
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;
    ULONG size=0,length=0;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)throw E_FAIL;
    if(BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<BYTE*>(&size),sizeof(size),&length,0)<0)throw E_FAIL;
    std::vector<BYTE> object(size);BYTE digest[32]{};
    if(BCryptCreateHash(algorithm,&hash,object.data(),size,nullptr,0,0)<0)throw E_FAIL;
    if(BCryptHashData(hash,const_cast<BYTE*>(bytes.data()),static_cast<ULONG>(bytes.size()),0)<0)throw E_FAIL;
    if(BCryptFinishHash(hash,digest,sizeof(digest),0)<0)throw E_FAIL;
    BCryptDestroyHash(hash);BCryptCloseAlgorithmProvider(algorithm,0);
    const char*hex="0123456789abcdef";std::string result;
    for(BYTE value:digest){result+=hex[value>>4];result+=hex[value&15];}return result;
}

struct Sample {
    int phase=0;REFERENCE_TIME start=0,stop=0,absolute=0;ULONGLONG tick=0;
    long bytes=0;int width=0,height=0;std::string hash;
};
struct Sink;
struct TracePin final:CRendererInputPin {
    Sink*owner;
    TracePin(Sink*sink,HRESULT*hr);
    STDMETHODIMP NewSegment(REFERENCE_TIME start,REFERENCE_TIME stop,double rate)override;
    STDMETHODIMP BeginFlush()override;
    STDMETHODIMP EndFlush()override;
};
struct Sink final:CBaseRenderer {
    bool audio;
    std::atomic<bool>ready{false};
    std::atomic<unsigned>frames{0},received{0},negative{0};
    std::atomic<ULONGLONG>firstTick{0};
    std::atomic<REFERENCE_TIME>segmentStart{0},firstStart{-1},lastStart{-1};
    HANDLE reached,referenceDone;
    unsigned windowCounts[2]{};
    std::mutex samplesLock;
    std::vector<Sample>samples;
    Sink(HRESULT*hr,bool isAudio):CBaseRenderer(CLSID_NULL,isAudio?L"PCM trace sink":L"P010 hash sink",nullptr,hr),audio(isAudio){
        reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);referenceDone=CreateEventW(nullptr,TRUE,FALSE,nullptr);
        m_pInputPin=new TracePin(this,hr);
    }
    ~Sink(){CloseHandle(reached);CloseHandle(referenceDone);}
    const char*Kind()const{return audio?"audio":"video";}
    void Reset(){ready=false;frames=0;received=0;negative=0;firstTick=0;firstStart=-1;lastStart=-1;ResetEvent(reached);}
    HRESULT CheckMediaType(const CMediaType*mt)override{
        if(audio)return mt->majortype==MEDIATYPE_Audio&&mt->formattype==FORMAT_WaveFormatEx&&mt->FormatLength()>=sizeof(WAVEFORMATEX)&&
            (mt->subtype==MEDIASUBTYPE_PCM||mt->subtype==MEDIASUBTYPE_IEEE_FLOAT)?S_OK:VFW_E_TYPE_NOT_ACCEPTED;
        return mt->majortype==MEDIATYPE_Video&&mt->subtype.Data1==mmioFOURCC('P','0','1','0')&&mt->formattype==FORMAT_VideoInfo2?S_OK:VFW_E_TYPE_NOT_ACCEPTED;
    }
    HRESULT SetMediaType(const CMediaType*mt)override{
        if(audio&&mt->FormatLength()>=sizeof(WAVEFORMATEX)){
            auto*format=reinterpret_cast<const WAVEFORMATEX*>(mt->Format());
            printf("pcm_format channels=%u rate=%lu bits=%u block_align=%u tag=0x%04x\n",format->nChannels,format->nSamplesPerSec,format->wBitsPerSample,format->nBlockAlign,format->wFormatTag);
        }
        return CBaseRenderer::SetMediaType(mt);
    }
    HRESULT Receive(IMediaSample*sample)override{
        if(ready){REFERENCE_TIME a=-1,b=-1;sample->GetTime(&a,&b);unsigned n=++received;if(a<0)negative++;
            if(n<=2)printf("receive stream=%s phase=%d n=%u pts=%lld stop=%lld latency_ms=%llu preroll=%d\n",Kind(),phase.load(),n,a,b,GetTickCount64()-requestTick.load(),sample->IsPreroll()==S_OK);}
        return CBaseRenderer::Receive(sample);
    }
    HRESULT DoRenderSample(IMediaSample*sample)override{
        if(!ready)return S_OK;REFERENCE_TIME a=-1,b=-1;if(FAILED(sample->GetTime(&a,&b))||a<0)return S_OK;
        unsigned n=++frames;auto now=GetTickCount64();if(n==1){firstTick=now;firstStart=a;}lastStart=a;
        const REFERENCE_TIME absolute=a+segmentStart.load();int selected=-1;
        if(referenceMode){
            for(size_t i=0;i<targets.size();++i)if(absolute>=targets[i]&&absolute<targets[i]+5000000&&windowCounts[i]<10){selected=static_cast<int>(i)+1;windowCounts[i]++;break;}
            if(!audio&&absolute>=targets.back()+5000000)SetEvent(referenceDone);
        }else if(n<=10)selected=phase.load();
        if(selected>=0){
            Sample record;record.phase=selected;record.start=a;record.stop=b;record.absolute=absolute;record.tick=now;record.bytes=sample->GetActualDataLength();
            if(!audio){
                CMediaType type;HRESULT hr=m_pInputPin->ConnectionMediaType(&type);if(FAILED(hr))return hr;
                auto*info=reinterpret_cast<const VIDEOINFOHEADER2*>(type.Format());
                int stride=info->bmiHeader.biWidth,storageHeight=std::abs(info->bmiHeader.biHeight);
                int width=info->rcTarget.right>info->rcTarget.left?info->rcTarget.right-info->rcTarget.left:stride;
                int height=info->rcTarget.bottom>info->rcTarget.top?info->rcTarget.bottom-info->rcTarget.top:storageHeight;
                if(width<=0||height<=0||(width&1)||(height&1)||width>stride||height>storageHeight||size_t(sample->GetActualDataLength())<size_t(stride)*storageHeight*3)return E_FAIL;
                BYTE*data=nullptr;hr=sample->GetPointer(&data);if(FAILED(hr))return hr;
                auto*input=reinterpret_cast<const uint16_t*>(data);std::vector<BYTE>canonical(size_t(width)*height*3);auto*output=reinterpret_cast<uint16_t*>(canonical.data());
                size_t luma=size_t(width)*height,chroma=size_t(stride)*storageHeight;
                for(int row=0;row<height;++row)for(int col=0;col<width;++col)output[size_t(row)*width+col]=input[size_t(row)*stride+col]>>6;
                for(int row=0;row<height/2;++row)for(int col=0;col<width/2;++col){output[luma+size_t(row)*width/2+col]=input[chroma+size_t(row)*stride+col*2]>>6;output[luma*5/4+size_t(row)*width/2+col]=input[chroma+size_t(row)*stride+col*2+1]>>6;}
                try{record.hash=SHA256(canonical);}catch(...){return E_FAIL;}record.width=width;record.height=height;
            }
            {std::lock_guard<std::mutex>lock(samplesLock);samples.push_back(record);}
            printf("sample stream=%s phase=%d n=%u pts=%lld stop=%lld absolute=%lld bytes=%ld latency_ms=%llu sha256=%s\n",Kind(),selected,n,a,b,absolute,record.bytes,now-requestTick.load(),record.hash.c_str());
        }
        if(n>=10)SetEvent(reached);return S_OK;
    }
};
TracePin::TracePin(Sink*sink,HRESULT*hr):CRendererInputPin(sink,hr,L"In"),owner(sink){}
STDMETHODIMP TracePin::NewSegment(REFERENCE_TIME start,REFERENCE_TIME stop,double rate){printf("newsegment stream=%s phase=%d start=%lld stop=%lld rate=%.6f latency_ms=%llu\n",owner->Kind(),phase.load(),start,stop,rate,GetTickCount64()-requestTick.load());owner->segmentStart=start;owner->ready=true;return CBaseInputPin::NewSegment(start,stop,rate);}
STDMETHODIMP TracePin::BeginFlush(){printf("flush=begin stream=%s phase=%d wall_ms=%llu\n",owner->Kind(),phase.load(),GetTickCount64());return CRendererInputPin::BeginFlush();}
STDMETHODIMP TracePin::EndFlush(){printf("flush=end stream=%s phase=%d wall_ms=%llu\n",owner->Kind(),phase.load(),GetTickCount64());return CRendererInputPin::EndFlush();}
static ULONGLONG CpuMs(){FILETIME a{},b{},k{},u{};GetProcessTimes(GetCurrentProcess(),&a,&b,&k,&u);ULARGE_INTEGER kernel{},user{};kernel.LowPart=k.dwLowDateTime;kernel.HighPart=k.dwHighDateTime;user.LowPart=u.dwLowDateTime;user.HighPart=u.dwHighDateTime;return(kernel.QuadPart+user.QuadPart)/10000;}
static ULONGLONG ReadBytes(){IO_COUNTERS io{};GetProcessIoCounters(GetCurrentProcess(),&io);return io.ReadTransferCount;}
static void WriteSamples(FILE*output,const char*name,Sink*sink){
    std::fprintf(output,"\"%s\":[\r\n",name);for(size_t i=0;i<sink->samples.size();++i){auto&s=sink->samples[i];std::fprintf(output,"%s{\"phase\":%d,\"start\":%lld,\"stop\":%lld,\"absolute_start\":%lld,\"wall_tick_ms\":%llu,\"bytes\":%ld,\"width\":%d,\"height\":%d,\"sha256\":\"%s\"}\r\n",i?",":"",s.phase,s.start,s.stop,s.absolute,s.tick,s.bytes,s.width,s.height,s.hash.c_str());}std::fprintf(output,"]");}

int wmain(int argc,wchar_t**argv){
    SetConsoleOutputCP(CP_UTF8);setvbuf(stdout,nullptr,_IONBF,0);setvbuf(stderr,nullptr,_IONBF,0);
    if(argc!=8&&argc!=9){puts("seek-av-probe PACKAGE INPUT live|reference THREADS fast|clocked OUTPUT.json TARGET1 [TARGET2]");return 2;}
    referenceMode=std::wstring(argv[3])==L"reference";
    for(int i=7;i<argc;++i)targets.push_back(static_cast<REFERENCE_TIME>(_wtof(argv[i])*10000000.0));
    if(targets.size()>2)return 2;
    HANDLE complete=CreateEventW(nullptr,TRUE,FALSE,nullptr);std::thread watchdog([&](){if(WaitForSingleObject(complete,110000)==WAIT_TIMEOUT){puts("watchdog=timeout");fflush(stdout);TerminateProcess(GetCurrentProcess(),124);}});
    int result=0;Check(CoInitializeEx(nullptr,COINIT_MULTITHREADED),"COM");
    try{
        CComPtr<IGraphBuilder>graph;Check(graph.CoCreateInstance(CLSID_FilterGraph),"graph");
        auto source=Load(argv[1],L"LAVSplitter.ax",L"{B98D13E7-55DB-4385-A33D-09FD1BA26338}");CComQIPtr<ILAVFSettings>ss(source);Check(ss->SetRuntimeConfig(TRUE),"splitter runtime");CComQIPtr<IFileSourceFilter>file(source);Check(file->Load(argv[2],nullptr),"open original");
        auto video=Load(argv[1],L"LAVVideo.ax",L"{EE30215D-164F-4A92-A4EB-9D4C13390F9F}");CComQIPtr<ILAVVideoSettings>vs(video);Check(vs->SetRuntimeConfig(TRUE),"video runtime");Check(vs->SetHWAccel(HWAccel_None),"software");Check(vs->SetNumThreads(_wtoi(argv[4])),"threads");Check(vs->SetDeinterlacingMode(DeintMode_Disable),"deinterlace off");for(int i=0;i<LAVOutPixFmt_NB;++i)Check(vs->SetPixelFormat(static_cast<LAVOutPixFmts>(i),i==LAVOutPixFmt_P010),"P010 output only");
        auto audio=Load(argv[1],L"LAVAudio.ax",L"{E8E73B6B-4CB3-44A4-BE99-4F7BCB96E491}");CComQIPtr<ILAVAudioSettings>as(audio);Check(as->SetRuntimeConfig(TRUE),"audio runtime");for(int i=0;i<Bitstream_NB;++i)Check(as->SetBitstreamConfig(static_cast<LAVBitstreamCodec>(i),FALSE),"disable bitstream");
        HRESULT hr=S_OK;auto*capture=new Sink(&hr,false);Check(hr,"video sink");CComPtr<IBaseFilter>videoSink;Check(capture->QueryInterface(IID_IBaseFilter,(void**)&videoSink),"video sink interface");auto*pcm=new Sink(&hr,true);Check(hr,"audio sink");CComPtr<IBaseFilter>audioSink;Check(pcm->QueryInterface(IID_IBaseFilter,(void**)&audioSink),"audio sink interface");
        Check(graph->AddFilter(source,L"Exact source"),"add source");Check(graph->AddFilter(video,L"Exact video"),"add video");Check(graph->AddFilter(audio,L"Exact audio"),"add audio");Check(graph->AddFilter(videoSink,L"P010 canonical capture"),"add video sink");Check(graph->AddFilter(audioSink,L"PCM bounded capture"),"add audio sink");
        Check(graph->ConnectDirect(Pin(source,PINDIR_OUTPUT,true),Pin(video,PINDIR_INPUT),nullptr),"connect compressed video");Check(graph->ConnectDirect(Pin(video,PINDIR_OUTPUT),Pin(videoSink,PINDIR_INPUT),nullptr),"connect P010");Check(graph->ConnectDirect(AudioPin(source),Pin(audio,PINDIR_INPUT),nullptr),"connect compressed audio");Check(graph->ConnectDirect(Pin(audio,PINDIR_OUTPUT),Pin(audioSink,PINDIR_INPUT),nullptr),"connect PCM");
        EnableVerboseLog(argv[1]);
        CComQIPtr<IMediaSeeking>seeking(graph);CComQIPtr<IMediaControl>control(graph);CComQIPtr<IMediaEvent>events(graph);CComQIPtr<IMediaFilter>timing(graph);CComPtr<IReferenceClock>clock;
        const bool clocked=std::wstring(argv[5])==L"clocked";if(clocked)Check(clock.CoCreateInstance(CLSID_SystemClock),"system reference clock");Check(timing->SetSyncSource(clocked?clock.p:nullptr),"shared graph clock");
        REFERENCE_TIME duration=0;Check(seeking->GetDuration(&duration),"duration");printf("config mode=%s clocked=%d threads=%d duration=%lld audio_connected=1 no_short_stop=1\n",referenceMode?"reference":"live",clocked,_wtoi(argv[4]),duration);
        int phaseCount=referenceMode?1:static_cast<int>(targets.size())+1;
        for(int index=0;index<phaseCount;++index){
            phase=index;capture->Reset();pcm->Reset();requestTick=GetTickCount64();auto cpu=CpuMs(),io=ReadBytes();printf("phase_begin phase=%d target=%lld wall_ms=%llu\n",index,index?targets[index-1]:0,requestTick.load());
            if(index){REFERENCE_TIME target=targets[index-1];printf("setpositions_begin phase=%d target=%lld\n",index,target);auto before=GetTickCount64();hr=seeking->SetPositions(&target,AM_SEEKING_AbsolutePositioning,nullptr,AM_SEEKING_NoPositioning);printf("setpositions_end phase=%d hr=0x%08lX elapsed_ms=%llu\n",index,(unsigned long)hr,GetTickCount64()-before);Check(hr,"LIVE seek");}
            else{capture->ready=true;pcm->ready=true;Check(control->Run(),"run baseline");}
            ULONGLONG limit=referenceMode?60000:index?45000:15000,lastLog=0;bool eos=false;
            while(GetTickCount64()-requestTick.load()<limit){
                bool done=referenceMode?WaitForSingleObject(capture->referenceDone,0)==WAIT_OBJECT_0:(WaitForSingleObject(capture->reached,0)==WAIT_OBJECT_0&&WaitForSingleObject(pcm->reached,0)==WAIT_OBJECT_0);if(done)break;
                long code=0;LONG_PTR a=0,b=0;while(events->GetEvent(&code,&a,&b,0)==S_OK){printf("event phase=%d code=%ld p1=%lld\n",index,code,(long long)a);events->FreeEventParams(code,a,b);if(code==EC_ERRORABORT)throw(HRESULT)a;if(code==EC_COMPLETE)eos=true;}
                if(eos)break;auto elapsed=GetTickCount64()-requestTick.load();if(elapsed-lastLog>=1000){lastLog=elapsed;printf("progress phase=%d elapsed_ms=%llu video=%u audio=%u cpu_ms=%llu read_bytes=%llu\n",index,elapsed,capture->frames.load(),pcm->frames.load(),CpuMs()-cpu,ReadBytes()-io);}Sleep(10);
            }
            printf("phase_result phase=%d video_frames=%u audio_chunks=%u video_first_ms=%llu audio_first_ms=%llu video_first_pts=%lld audio_first_pts=%lld elapsed_ms=%llu cpu_delta_ms=%llu read_delta_bytes=%llu\n",index,capture->frames.load(),pcm->frames.load(),capture->firstTick.load()?capture->firstTick.load()-requestTick.load():0,pcm->firstTick.load()?pcm->firstTick.load()-requestTick.load():0,capture->firstStart.load(),pcm->firstStart.load(),GetTickCount64()-requestTick.load(),CpuMs()-cpu,ReadBytes()-io);
            if(!referenceMode&&(capture->frames.load()<10||pcm->frames.load()<10)){result=3;break;}
        }
        Check(control->Stop(),"stop");if(referenceMode){for(size_t i=0;i<targets.size();++i){if(capture->windowCounts[i]!=10||pcm->windowCounts[i]!=10){printf("reference_missing_window index=%zu video=%u audio=%u\n",i,capture->windowCounts[i],pcm->windowCounts[i]);result=3;}}}FILE*output=nullptr;Check(_wfopen_s(&output,argv[6],L"wb")?E_FAIL:S_OK,"JSON output");
        std::fprintf(output,"{\"pointer_bits\":%zu,\"mode\":\"%s\",\"clocked\":%s,\"threads\":%d,\"result\":%d,\"targets\":[",sizeof(void*)*8,referenceMode?"reference":"live",clocked?"true":"false",_wtoi(argv[4]),result);for(size_t i=0;i<targets.size();++i)std::fprintf(output,"%s%lld",i?",":"",targets[i]);std::fprintf(output,"],\r\n");WriteSamples(output,"video_samples",capture);std::fprintf(output,",\r\n");WriteSamples(output,"audio_samples",pcm);std::fprintf(output,"}\r\n");std::fclose(output);printf("result=finished code=%d\n",result);
    }catch(HRESULT hr){printf("result=failed hr=0x%08lX\n",(unsigned long)hr);result=1;}
    CoUninitialize();SetEvent(complete);watchdog.join();CloseHandle(complete);return result;
}
