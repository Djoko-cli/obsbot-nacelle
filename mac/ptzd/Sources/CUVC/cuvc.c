#include "cuvc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

struct cuvc_device {
    IOUSBDeviceInterface245 **interface;
    uint8_t video_control_interface;
    uint8_t camera_terminal;
};

static IOReturn device_request(IOUSBDeviceInterface245 **interface, uint8_t type, uint8_t request,
                               uint16_t value, uint16_t index, void *data, uint16_t length,
                               uint32_t *transferred) {
    IOUSBDevRequestTO rq = {0};
    rq.bmRequestType = type;
    rq.bRequest = request;
    rq.wValue = value;
    rq.wIndex = index;
    rq.wLength = length;
    rq.pData = data;
    rq.noDataTimeout = 1000;
    rq.completionTimeout = 1000;
    IOReturn result = (*interface)->DeviceRequestTO(interface, &rq);
    if (transferred) {
        *transferred = rq.wLenDone;
    }
    return result;
}

/// Lit le descripteur de configuration ; repère l'interface VideoControl
/// (classe 0x0E, sous-classe 1) et son Camera Terminal (type 0x0201).
static IOReturn find_camera_terminal(cuvc_device *device) {
    uint8_t header[9];
    uint32_t transferred = 0;
    IOReturn result = device_request(device->interface, 0x80, 6, 0x0200, 0, header, sizeof header, &transferred);
    if (result != kIOReturnSuccess) {
        return result;
    }
    uint16_t total = (uint16_t)(header[2] | header[3] << 8);
    uint8_t *buffer = malloc(total);
    if (!buffer) {
        return kIOReturnNoMemory;
    }
    result = device_request(device->interface, 0x80, 6, 0x0200, 0, buffer, total, &transferred);
    if (result != kIOReturnSuccess) {
        free(buffer);
        return result;
    }
    int found = 0;
    int interface_number = -1, interface_class = -1, interface_subclass = -1;
    for (uint32_t i = 0; i + 2 <= transferred && buffer[i] > 0; i += buffer[i]) {
        uint8_t type = buffer[i + 1];
        if (type == 4 && i + 7 <= transferred) {
            interface_number = buffer[i + 2];
            interface_class = buffer[i + 5];
            interface_subclass = buffer[i + 6];
        } else if (type == 0x24 && interface_class == 0x0E && interface_subclass == 1 && i + 6 <= transferred
                   && buffer[i + 2] == 2 && (buffer[i + 4] | buffer[i + 5] << 8) == 0x0201) {
            device->video_control_interface = (uint8_t)interface_number;
            device->camera_terminal = buffer[i + 3];
            found = 1;
            break;
        }
    }
    free(buffer);
    return found ? kIOReturnSuccess : kIOReturnNotFound;
}

cuvc_device *cuvc_open(uint16_t vendor_id, uint16_t product_id, int32_t *error) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    int vendor = vendor_id, product = product_id;
    CFNumberRef vendor_number = CFNumberCreate(NULL, kCFNumberIntType, &vendor);
    CFNumberRef product_number = CFNumberCreate(NULL, kCFNumberIntType, &product);
    CFDictionarySetValue(matching, CFSTR("idVendor"), vendor_number);
    CFDictionarySetValue(matching, CFSTR("idProduct"), product_number);
    CFRelease(vendor_number);
    CFRelease(product_number);

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) {
        if (error) *error = kIOReturnNotFound;
        return NULL;
    }
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                        kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (result != kIOReturnSuccess || !plugin) {
        if (error) *error = result != kIOReturnSuccess ? result : kIOReturnError;
        return NULL;
    }
    IOUSBDeviceInterface245 **interface = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID245), (LPVOID *)&interface);
    IODestroyPlugInInterface(plugin);
    if (!interface) {
        if (error) *error = kIOReturnUnsupported;
        return NULL;
    }
    cuvc_device *device = calloc(1, sizeof *device);
    if (!device) {
        (*interface)->Release(interface);
        if (error) *error = kIOReturnNoMemory;
        return NULL;
    }
    device->interface = interface;
    result = find_camera_terminal(device);
    if (result != kIOReturnSuccess) {
        cuvc_close(device);
        if (error) *error = result;
        return NULL;
    }
    if (error) *error = kIOReturnSuccess;
    return device;
}

void cuvc_close(cuvc_device *device) {
    if (!device) {
        return;
    }
    if (device->interface) {
        (*device->interface)->Release(device->interface);
    }
    free(device);
}

int32_t cuvc_camera_control(cuvc_device *device, uint8_t request, uint8_t selector,
                            void *data, uint16_t length) {
    if (!device) {
        return kIOReturnNotAttached;
    }
    uint8_t type = (request & 0x80) ? 0xA1 : 0x21;
    uint16_t index = (uint16_t)(device->camera_terminal << 8 | device->video_control_interface);
    return device_request(device->interface, type, request, (uint16_t)(selector << 8), index, data, length, NULL);
}
