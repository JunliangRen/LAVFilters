/*
 *      Copyright (C) 2026 LAV Filters contributors
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#pragma once

#include "avcodec.h"

// FFmpeg owns the CUVID parser, decoder, surfaces and CPU frame transfer.
// The driver entry points below are only used for device enumeration.
class CDecCUVIDFFmpeg : public CDecAvcodec
{
  public:
    virtual ~CDecCUVIDFFmpeg();

    STDMETHODIMP Init();
    STDMETHODIMP Check();
    STDMETHODIMP Decode(const BYTE *buffer, int buflen, REFERENCE_TIME rtStart, REFERENCE_TIME rtStop, BOOL bSyncPoint,
                        BOOL bDiscontinuity, IMediaSample *pSample);
    STDMETHODIMP EndOfStream();
    STDMETHODIMP Flush();
    STDMETHODIMP_(REFERENCE_TIME) GetFrameDuration();
    STDMETHODIMP_(BOOL) IsInterlaced(BOOL bAllowGuess);
    STDMETHODIMP_(const WCHAR *) GetDecoderName() { return L"cuvid (ffmpeg)"; }
    STDMETHODIMP_(DWORD) GetHWAccelNumDevices();
    STDMETHODIMP GetHWAccelDeviceInfo(DWORD dwIndex, BSTR *pstrDeviceName, DWORD *dwDeviceIdentifier);
    STDMETHODIMP GetHWAccelActiveDevice(BSTR *pstrDeviceName);

  protected:
    const AVCodec *FindDecoder(AVCodecID codec);
    HRESULT AdditionaDecoderInit();
    HRESULT PostDecode();
    HRESULT HandleDecodeError(int error);
    BOOL IsHardwareAccelerator() { return TRUE; }
    BOOL IsHardwareDeinterlaced();
    REFERENCE_TIME GetFrameAverageDuration() { return GetFrameDuration(); }
    BOOL UseSourcePixelFormatHints() { return FALSE; }
    // CUVID assembles pictures itself. The generic MPEG parser would overwrite
    // its field-rate output framerate with the encoded sequence rate.
    BOOL UseCodecParser() { return FALSE; }

  private:
    static AVPixelFormat GetSoftwareFormat(AVCodecContext *ctx, const AVPixelFormat *formats);
    HRESULT ConfigureDeinterlacing();

    HMODULE m_hCUDA = nullptr;
    HMODULE m_hCUVID = nullptr;
    int(WINAPI *m_cuInit)(unsigned int) = nullptr;
    int(WINAPI *m_cuDeviceGetCount)(int *) = nullptr;
    int(WINAPI *m_cuDeviceGet)(int *, int) = nullptr;
    int(WINAPI *m_cuDeviceGetName)(char *, int, int) = nullptr;
    DWORD m_dwActiveDevice = LAVHWACCEL_DEVICE_DEFAULT;
    BOOL m_bHWDeint = FALSE;
    BOOL m_bOutputInterlaced = FALSE;
    BOOL m_bOutputHWDeint = FALSE;
    REFERENCE_TIME m_rtSourceDuration = 0;
    REFERENCE_TIME m_rtOutputDuration = 0;
    REFERENCE_TIME m_rtPreviousPTS = AV_NOPTS_VALUE;
};
