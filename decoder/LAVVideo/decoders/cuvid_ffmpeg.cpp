/*
 *      Copyright (C) 2026 LAV Filters contributors
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#include "stdafx.h"
#include "cuvid_ffmpeg.h"

extern "C"
{
#include "libavutil/hwcontext.h"
#include "libavutil/pixdesc.h"
}

ILAVDecoder *CreateDecoderCUVIDFFmpeg()
{
    return new CDecCUVIDFFmpeg();
}

CDecCUVIDFFmpeg::~CDecCUVIDFFmpeg()
{
    DestroyDecoder();
    if (m_hCUVID)
        FreeLibrary(m_hCUVID);
    if (m_hCUDA)
        FreeLibrary(m_hCUDA);
}

STDMETHODIMP CDecCUVIDFFmpeg::Init()
{
    CDecAvcodec::Init();
    if (!avcodec_find_decoder_by_name("h264_cuvid"))
        return E_FAIL;

    m_hCUDA = LoadLibraryExW(L"nvcuda.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    m_hCUVID = LoadLibraryExW(L"nvcuvid.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!m_hCUDA || !m_hCUVID)
        return E_FAIL;

    m_cuInit = reinterpret_cast<decltype(m_cuInit)>(GetProcAddress(m_hCUDA, "cuInit"));
    m_cuDeviceGetCount = reinterpret_cast<decltype(m_cuDeviceGetCount)>(GetProcAddress(m_hCUDA, "cuDeviceGetCount"));
    m_cuDeviceGet = reinterpret_cast<decltype(m_cuDeviceGet)>(GetProcAddress(m_hCUDA, "cuDeviceGet"));
    m_cuDeviceGetName = reinterpret_cast<decltype(m_cuDeviceGetName)>(GetProcAddress(m_hCUDA, "cuDeviceGetName"));
    if (!m_cuInit || !m_cuDeviceGetCount || !m_cuDeviceGet || !m_cuDeviceGetName || m_cuInit(0) != 0)
        return E_FAIL;

    return GetHWAccelNumDevices() ? S_OK : E_FAIL;
}

STDMETHODIMP CDecCUVIDFFmpeg::Check()
{
    return GetHWAccelNumDevices() ? S_OK : E_FAIL;
}

STDMETHODIMP_(DWORD) CDecCUVIDFFmpeg::GetHWAccelNumDevices()
{
    int count = 0;
    return m_cuDeviceGetCount && m_cuDeviceGetCount(&count) == 0 && count > 0 ? count : 0;
}

STDMETHODIMP CDecCUVIDFFmpeg::GetHWAccelDeviceInfo(DWORD dwIndex, BSTR *pstrDeviceName,
                                                 DWORD *dwDeviceIdentifier)
{
    if (pstrDeviceName)
        *pstrDeviceName = nullptr;
    if (dwDeviceIdentifier)
        *dwDeviceIdentifier = 0;
    if (dwIndex >= GetHWAccelNumDevices())
        return E_INVALIDARG;

    char name[256] = {};
    int device;
    if (m_cuDeviceGet(&device, dwIndex) != 0 || m_cuDeviceGetName(name, sizeof(name), device) != 0)
        return E_FAIL;
    if (pstrDeviceName)
    {
        WCHAR wideName[256] = {};
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, name, -1, wideName, countof(wideName)))
            return E_FAIL;
        *pstrDeviceName = SysAllocString(wideName);
        if (!*pstrDeviceName)
            return E_OUTOFMEMORY;
    }
    return S_OK;
}

STDMETHODIMP CDecCUVIDFFmpeg::GetHWAccelActiveDevice(BSTR *pstrDeviceName)
{
    CheckPointer(pstrDeviceName, E_POINTER);
    *pstrDeviceName = nullptr;
    if (m_dwActiveDevice == LAVHWACCEL_DEVICE_DEFAULT)
        return E_UNEXPECTED;
    return GetHWAccelDeviceInfo(m_dwActiveDevice, pstrDeviceName, nullptr);
}

const AVCodec *CDecCUVIDFFmpeg::FindDecoder(AVCodecID codec)
{
    // Discover the wrapper by codec ID so additional FFmpeg CUVID codecs can
    // use this path without a second per-codec decode implementation.
    void *iterator = nullptr;
    const AVCodec *decoder;
    while ((decoder = av_codec_iterate(&iterator)))
    {
        if (decoder->id == codec && av_codec_is_decoder(decoder) && decoder->wrapper_name &&
            strcmp(decoder->wrapper_name, "cuvid") == 0)
            return decoder;
    }
    return nullptr;
}

AVPixelFormat CDecCUVIDFFmpeg::GetSoftwareFormat(AVCodecContext *ctx, const AVPixelFormat *formats)
{
    // CUVID can copy its surfaces to software AVFrames. Hardware pointers must
    // never reach the DirectShow CPU pixel converter.
    for (const AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++)
    {
        const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(*format);
        if (desc && !(desc->flags & AV_PIX_FMT_FLAG_HWACCEL))
            return *format;
    }
    return AV_PIX_FMT_NONE;
}

HRESULT CDecCUVIDFFmpeg::AdditionaDecoderInit()
{
    m_dwActiveDevice = LAVHWACCEL_DEVICE_DEFAULT;
    m_bOutputInterlaced = FALSE;
    m_bOutputHWDeint = FALSE;
    m_rtPreviousPTS = AV_NOPTS_VALUE;
    m_rtSourceDuration = 0;
    const CMediaType &mt = m_pCallback->GetInputMediaType();
    videoFormatTypeHandler(mt.Format(), mt.FormatType(), nullptr, &m_rtSourceDuration, nullptr, nullptr);
    m_rtOutputDuration = m_rtSourceDuration;
    // The base DTS cache assumes the software decoder's display delay. CUVID
    // queues pictures independently and also generates second-field PTS.
    // Keep these inputs on the software path until display-order DTS handling
    // is available, rather than reporting misleading presentation timestamps.
    if ((m_pCallback->GetDecodeFlags() & LAV_VIDEO_DEC_FLAG_ONLY_DTS) ||
        (m_pAVCtx->codec_id == AV_CODEC_ID_MPEG4 &&
         m_pCallback->GetInputMediaType().formattype != FORMAT_MPEG2Video))
        return VFW_E_UNSUPPORTED_VIDEO;

    // Probe the actual input chroma/depth before CUVID consumes packets. A
    // delayed capability failure would otherwise discard its startup queue
    // before DecodeManager can retry the current packet in software.
    LAVPinInfo pinInfo = {};
    if (SUCCEEDED(m_pCallback->GetLAVPinInfo(pinInfo)) && pinInfo.pix_fmt != AV_PIX_FMT_NONE)
    {
        const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(pinInfo.pix_fmt);
        if (desc && !(desc->flags & AV_PIX_FMT_FLAG_HWACCEL))
            m_pAVCtx->pix_fmt = pinInfo.pix_fmt;
    }
    DWORD device = m_pSettings->GetHWAccelDeviceIndex(HWAccel_CUVIDFFmpeg, nullptr);
    if (device == LAVHWACCEL_DEVICE_DEFAULT)
        device = m_pCallback->GetGPUDeviceIndex();
    if (device >= GetHWAccelNumDevices())
        device = 0;

    char deviceString[16];
    _snprintf_s(deviceString, sizeof(deviceString), _TRUNCATE, "%u", device);
    if (av_hwdevice_ctx_create(&m_pAVCtx->hw_device_ctx, AV_HWDEVICE_TYPE_CUDA, deviceString, nullptr, 0) < 0)
        return E_FAIL;
    m_dwActiveDevice = device;

    m_pAVCtx->get_format = GetSoftwareFormat;
    m_pAVCtx->thread_count = 1;
    m_pAVCtx->thread_type = 0;
    // CUVID uses this to rescale DirectShow PTS and time the second field.
    m_pAVCtx->pkt_timebase = {1, 10000000};

    // Keep CUDA decode references intact when settings change during playback.
    // The opt-in FFmpeg path changes display processing for each queued picture.
    if (av_opt_set_int(m_pAVCtx->priv_data, "dynamic_deint", 1, 0) < 0)
        return E_FAIL;
    // Preserve a known container cadence when the bitstream omits timing.
    // A valid sequence rate still takes precedence for other codecs.
    if (m_rtSourceDuration > 0)
    {
        AVRational rate;
        av_reduce(&rate.num, &rate.den, 10000000, m_rtSourceDuration, INT_MAX);
        if (av_opt_set_q(m_pAVCtx->priv_data, "deint_framerate_fallback", rate, 0) < 0)
            return E_FAIL;
    }
    // MPEG-4's CUVID sequence rate can differ from its container cadence.
    // Use the known input picture duration when timing generated fields.
    if (m_pAVCtx->codec_id == AV_CODEC_ID_MPEG4 && m_rtSourceDuration > 0)
    {
        AVRational rate;
        av_reduce(&rate.num, &rate.den, 10000000, m_rtSourceDuration, INT_MAX);
        if (av_opt_set_q(m_pAVCtx->priv_data, "deint_framerate", rate, 0) < 0)
            return E_FAIL;
    }
    return ConfigureDeinterlacing();
}

HRESULT CDecCUVIDFFmpeg::ConfigureDeinterlacing()
{
    const LAVDeintMode mode = m_pSettings->GetDeinterlacingMode();
    const LAVDeintFieldOrder order = m_pSettings->GetDeintFieldOrder();
    const BOOL hardware = m_pSettings->GetHWAccelDeintMode() == HWDeintMode_Hardware && mode != DeintMode_Disable;
    const BOOL singleRate = m_pSettings->GetHWAccelDeintOutput() == DeintOutput_FramePer2Field;
    if (av_opt_set(m_pAVCtx->priv_data, "deint", hardware ? "adaptive" : "weave", 0) < 0 ||
        av_opt_set_int(m_pAVCtx->priv_data, "drop_second_field",
                       singleRate, 0) < 0 ||
        av_opt_set_int(m_pAVCtx->priv_data, "force_deint", mode == DeintMode_Force, 0) < 0 ||
        av_opt_set_int(m_pAVCtx->priv_data, "aggressive_deint", mode == DeintMode_Aggressive, 0) < 0 ||
        av_opt_set_int(m_pAVCtx->priv_data, "deint_field_order",
                       order == DeintFieldOrder_Auto ? -1 : (order == DeintFieldOrder_TopFieldFirst), 0) < 0)
        return E_FAIL;
    m_bHWDeint = hardware;
    return S_OK;
}

STDMETHODIMP CDecCUVIDFFmpeg::Decode(const BYTE *buffer, int buflen, REFERENCE_TIME rtStart, REFERENCE_TIME rtStop,
                                   BOOL bSyncPoint, BOOL bDiscontinuity, IMediaSample *pSample)
{
    if (buffer && buflen > 0)
    {
        const HRESULT hr = ConfigureDeinterlacing();
        if (FAILED(hr))
            return hr;
    }
    return CDecAvcodec::Decode(buffer, buflen, rtStart, rtStop, bSyncPoint, bDiscontinuity, pSample);
}

HRESULT CDecCUVIDFFmpeg::PostDecode()
{
    if (m_pFrame && m_pFrame->data[0])
    {
        // Frames can outlive a live setting change. Use the processing state
        // captured with this picture, rather than the latest hardware mode.
        const AVDictionaryEntry *deint = av_dict_get(m_pFrame->metadata, "lav.cuvid.deinterlaced", nullptr, 0);
        if (!deint || (strcmp(deint->value, "0") != 0 && strcmp(deint->value, "1") != 0))
            return E_FAIL;
        m_bOutputHWDeint = strcmp(deint->value, "1") == 0;
        m_bOutputInterlaced = !!(m_pFrame->flags & AV_FRAME_FLAG_INTERLACED);
        // The CUVID wrapper does not fill LAV's sequence extension. Its frame
        // flags are authoritative and prevent aggressive software deinterlace
        // from treating progressive pictures as interlaced.
        m_pAVCtx->progressive_sequence = !m_bOutputInterlaced;

        // MPEG-4 CUVID can report a rate/timebase unrelated to display cadence.
        // Seed from the container, then follow consecutive display timestamps.
        // Other codecs use CUVID's sequence-derived output rate directly.
        if (m_pAVCtx->codec_id == AV_CODEC_ID_MPEG4 &&
            m_pFrame->pts != AV_NOPTS_VALUE && m_rtPreviousPTS != AV_NOPTS_VALUE)
        {
            REFERENCE_TIME delta = m_pFrame->pts - m_rtPreviousPTS;
            // Ignore timestamp gaps that exceed twice the established cadence.
            if (delta > 0 && delta < 10000000 &&
                (m_rtOutputDuration <= 0 || delta <= m_rtOutputDuration * 2))
                m_rtOutputDuration = delta;
        }
        m_rtPreviousPTS = m_pFrame->pts;
    }
    return S_OK;
}

HRESULT CDecCUVIDFFmpeg::HandleDecodeError(int error)
{
    if (error == AVERROR_EOF)
        return S_FALSE;
    // A capability or driver failure can occur only after the first sequence
    // header. Return failure so DecodeManager retries this packet in software.
    DbgLog((LOG_ERROR, 10, L"FFmpeg CUVID decode failed (%d), requesting software fallback", error));
    return E_FAIL;
}

BOOL CDecCUVIDFFmpeg::IsHardwareDeinterlaced()
{
    return m_bOutputHWDeint;
}

STDMETHODIMP_(BOOL) CDecCUVIDFFmpeg::IsInterlaced(BOOL bAllowGuess)
{
    if (m_bOutputHWDeint)
        return FALSE;
    if (m_bHWDeint)
        return m_bOutputInterlaced;
    return CDecAvcodec::IsInterlaced(bAllowGuess);
}

STDMETHODIMP CDecCUVIDFFmpeg::EndOfStream()
{
    return Decode(nullptr, 0, AV_NOPTS_VALUE, AV_NOPTS_VALUE, FALSE, FALSE, nullptr);
}

STDMETHODIMP CDecCUVIDFFmpeg::Flush()
{
    m_rtPreviousPTS = AV_NOPTS_VALUE;
    m_rtOutputDuration = m_rtSourceDuration;
    return CDecAvcodec::Flush();
}

STDMETHODIMP_(REFERENCE_TIME) CDecCUVIDFFmpeg::GetFrameDuration()
{
    // A known MPEG-4 container rate is now supplied to CUVID, whose queued
    // picture snapshot includes any single/double-rate display processing.
    // Learn from timestamps only when no container cadence was available.
    return m_pAVCtx && m_pAVCtx->codec_id == AV_CODEC_ID_MPEG4 && m_rtSourceDuration <= 0 && m_rtOutputDuration > 0
               ? m_rtOutputDuration : CDecAvcodec::GetFrameDuration();
}
