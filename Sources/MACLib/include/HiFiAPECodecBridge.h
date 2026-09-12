//  HiFiAPECodecBridge.h
//  Hi-Fi
//
//  Created by 董超 on 2026/9/12.
//
//  Monkey's Audio (BSD-3, Copyright 2000-2026 Matthew T. Ashland) 解码桥接。
//  Swift 经 C ABI 调用，不直接接触 C++ 类。详见 ThirdParty/MAC/LICENSE-Monkeys-Audio.txt。

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t sampleRate;
    int32_t channelCount;
    int32_t bitsPerSample;
    int32_t bytesPerSample;
    int32_t compressionLevel;
    int32_t fileVersion;
    int32_t formatFlags;
    int32_t isFloat;
    int64_t totalBlocks;
    int32_t blockAlign;
    int64_t lengthMS;
} HiFiAPEInfo;

/// 不透明解码句柄；Swift 侧按 UnsafeMutableRawPointer 持有。
typedef void * HiFiAPEHandle;

HiFiAPEHandle hifi_ape_open(const char * utf8Path, int * errorCodeOut);
void hifi_ape_close(HiFiAPEHandle file);
int hifi_ape_info(HiFiAPEHandle file, HiFiAPEInfo * infoOut);
int hifi_ape_decode(HiFiAPEHandle file, unsigned char * outBuffer, int64_t maxBlocks, int64_t * blocksDecodedOut);
int hifi_ape_seek(HiFiAPEHandle file, int64_t blockOffset);

#ifdef __cplusplus
} // extern "C"
#endif
