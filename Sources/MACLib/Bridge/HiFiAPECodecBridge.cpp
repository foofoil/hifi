//  HiFiAPECodecBridge.cpp
//  Hi-Fi
//
//  Created by 董超 on 2026/9/12.
//
//  Monkey's Audio (BSD-3) C++ 解码器的薄 C 封装：路径转换、句柄管理、块级解码与 seek。
//  所有重活在调用线程执行，禁止在 HAL 实时回调内调用。

#include "HiFiAPECodecBridge.h"

#include <new>

#include "All.h"
#include "CharacterHelper.h"
#include "MACLib.h"

namespace {

struct HiFiAPEFile {
    APE::IAPEDecompress * decompress;
};

HiFiAPEFile * unwrap(HiFiAPEHandle handle) {
    return static_cast<HiFiAPEFile *>(handle);
}

} // namespace

HiFiAPEHandle hifi_ape_open(const char * utf8Path, int * errorCodeOut) {
    if (utf8Path == nullptr) {
        if (errorCodeOut != nullptr) *errorCodeOut = -1;
        return nullptr;
    }
    APE::str_utfn * path = APE::CAPECharacterHelper::GetUTFNFromUTF8(
        reinterpret_cast<const APE::str_utf8 *>(utf8Path));
    if (path == nullptr) {
        if (errorCodeOut != nullptr) *errorCodeOut = -1;
        return nullptr;
    }
    int errorCode = 0;
    APE::IAPEDecompress * decompress = ::CreateIAPEDecompress(
        path, &errorCode, true /* read-only */, false /* lazy tag */, false /* no full read */);
    delete [] path;
    if (decompress == nullptr) {
        if (errorCodeOut != nullptr) *errorCodeOut = errorCode;
        return nullptr;
    }
    HiFiAPEFile * file = new (std::nothrow) HiFiAPEFile();
    if (file == nullptr) {
        delete decompress;
        if (errorCodeOut != nullptr) *errorCodeOut = -1;
        return nullptr;
    }
    file->decompress = decompress;
    if (errorCodeOut != nullptr) *errorCodeOut = 0;
    return static_cast<HiFiAPEHandle>(file);
}

void hifi_ape_close(HiFiAPEHandle handle) {
    HiFiAPEFile * file = unwrap(handle);
    if (file == nullptr) return;
    delete file->decompress;
    delete file;
}

int hifi_ape_info(HiFiAPEHandle handle, HiFiAPEInfo * infoOut) {
    HiFiAPEFile * file = unwrap(handle);
    if (file == nullptr || file->decompress == nullptr || infoOut == nullptr) return -1;
    APE::IAPEDecompress * decompress = file->decompress;
    const int64_t totalBlocks = decompress->GetInfo(APE::IAPEDecompress::APE_INFO_TOTAL_BLOCKS);
    if (totalBlocks <= 0) return -2;
    const int64_t blockAlign = decompress->GetInfo(APE::IAPEDecompress::APE_INFO_BLOCK_ALIGN);
    const int64_t channels = decompress->GetInfo(APE::IAPEDecompress::APE_INFO_CHANNELS);
    if (blockAlign <= 0 || channels <= 0) return -2;
    const int64_t formatFlags = decompress->GetInfo(APE::IAPEDecompress::APE_INFO_FORMAT_FLAGS);
    infoOut->sampleRate = static_cast<int32_t>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_SAMPLE_RATE));
    infoOut->channelCount = static_cast<int32_t>(channels);
    infoOut->bitsPerSample = static_cast<int32_t>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_BITS_PER_SAMPLE));
    infoOut->bytesPerSample = static_cast<int32_t>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_BYTES_PER_SAMPLE));
    infoOut->compressionLevel = static_cast<int32_t>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_COMPRESSION_LEVEL));
    infoOut->fileVersion = static_cast<int32_t>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_FILE_VERSION));
    infoOut->formatFlags = static_cast<int32_t>(formatFlags);
    infoOut->isFloat = ((formatFlags & APE_FORMAT_FLAG_FLOATING_POINT) != 0) ? 1 : 0;
    infoOut->totalBlocks = totalBlocks;
    infoOut->blockAlign = static_cast<int32_t>(blockAlign);
    infoOut->lengthMS = decompress->GetInfo(APE::IAPEDecompress::APE_INFO_LENGTH_MS);
    if (infoOut->sampleRate <= 0 || infoOut->bitsPerSample <= 0) return -2;
    return 0;
}

int hifi_ape_decode(HiFiAPEHandle handle, unsigned char * outBuffer, int64_t maxBlocks, int64_t * blocksDecodedOut) {
    if (blocksDecodedOut != nullptr) *blocksDecodedOut = 0;
    HiFiAPEFile * file = unwrap(handle);
    if (file == nullptr || file->decompress == nullptr || outBuffer == nullptr || maxBlocks <= 0) return -1;
    int64_t retrieved = 0;
    const int result = file->decompress->GetData(outBuffer, maxBlocks, &retrieved);
    if (blocksDecodedOut != nullptr) *blocksDecodedOut = retrieved;
    return result;
}

int hifi_ape_seek(HiFiAPEHandle handle, int64_t blockOffset) {
    HiFiAPEFile * file = unwrap(handle);
    if (file == nullptr || file->decompress == nullptr || blockOffset < 0) return -1;
    return file->decompress->Seek(blockOffset);
}
