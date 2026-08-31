// Private display-service declarations used by AppleSiliconDDC.
// Based on AppleSiliconDDC by Istvan T. (@waydabber), MIT licensed.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOKit/i2c/IOI2CInterface.h>

typedef CFTypeRef IOAVService;

extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(
    IOAVService service,
    uint32_t chipAddress,
    uint32_t offset,
    void *outputBuffer,
    uint32_t outputBufferSize
);
extern IOReturn IOAVServiceWriteI2C(
    IOAVService service,
    uint32_t chipAddress,
    uint32_t dataAddress,
    const void *inputBuffer,
    uint32_t inputBufferSize
);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID displayID);
