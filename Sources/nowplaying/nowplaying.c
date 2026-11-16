// Loaded by /usr/bin/perl (an Apple-signed process, which MediaRemote still answers; it ignores third-party callers
// since macOS 15.4). np_stream() prints one JSON line to stdout whenever the now-playing app or its state changes.
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nowplaying.h"

typedef void (^ClientCB)(void *);
typedef void (^InfoCB)(CFDictionaryRef);
typedef void (*GetInfo)(dispatch_queue_t, InfoCB);
typedef void (^BoolCB)(Boolean);
typedef void (*GetClient)(dispatch_queue_t, ClientCB);
typedef void (*GetPlaying)(dispatch_queue_t, BoolCB);
typedef CFStringRef (*ClientBundle)(void *);
typedef void (*Register)(dispatch_queue_t);

static GetInfo getInfo; static GetClient getClient; static GetPlaying getPlaying; static ClientBundle clientBundle;

static void emit(void) {
    getClient(dispatch_get_main_queue(), ^(void *client) {
        char *bundle = calloc(256, 1);
        if (client) { CFStringRef b = clientBundle(client); if (b) CFStringGetCString(b, bundle, 256, kCFStringEncodingUTF8); }
        getPlaying(dispatch_get_main_queue(), ^(Boolean p) {
            getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef d) {
                int title = 0; double rate = 0, age = -1;
                if (d) {
                    title = CFDictionaryGetValue(d, CFSTR("kMRMediaRemoteNowPlayingInfoTitle")) != NULL;
                    CFNumberRef r = CFDictionaryGetValue(d, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));
                    if (r) CFNumberGetValue(r, kCFNumberDoubleType, &rate);
                    CFDateRef t = CFDictionaryGetValue(d, CFSTR("kMRMediaRemoteNowPlayingInfoTimestamp"));
                    if (t) age = CFAbsoluteTimeGetCurrent() - CFDateGetAbsoluteTime(t);
                }
                printf("{\"bundle\":\"%s\",\"playing\":%s,\"title\":%s,\"rate\":%g,\"age\":%g}\n", bundle, p ? "true" : "false", title ? "true" : "false", rate, age);
                fflush(stdout); free(bundle);
            });
        });
    });
}
static void changed(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef u) { emit(); }

void np_stream(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) return;
    getClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    getInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    clientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    Register reg = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getClient || !getPlaying || !clientBundle || !reg) return;
    reg(dispatch_get_main_queue());
    const char *names[] = { "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                            "kMRMediaRemoteNowPlayingInfoDidChangeNotification" };
    for (int i = 0; i < 3; i++) {
        CFStringRef s = CFStringCreateWithCString(NULL, names[i], kCFStringEncodingUTF8);
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, changed, s, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    emit();
    CFRunLoopRun();
}
