// tv_rumble.m - controller rumble on the Apple TV: runtime/rumble.m's interface, played through GameController haptics.
//
// feedback.c runs the X360 rumble model and gives a heavy (left) and a light (right) motor level each frame. The Mac sends
// them to a DualSense as HID reports (IOKit, not on tvOS). Here each pad's CoreHaptics engines play them: one engine per
// handle when the pad has two (DualSense, DualShock 4, Xbox), heavy on the left and light on the right, else one engine
// with the stronger of the two. Each engine loops a continuous event whose intensity follows the level.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <math.h>
#include <stdatomic.h>

#include "host.h"

static dispatch_queue_t q;                   // everything below runs on it
static GCController *pad;
static CHHapticEngine *engines[2];
static id<CHHapticAdvancedPatternPlayer> players[2];
static int running[2];
static float sent[2] = {-1, -1};
static _Atomic uint32_t want;                // heavy | light << 8
static _Atomic int queued, closed, suppressed;
static int rumble_off = -1;                  // NFS_RUMBLE=off, or off in the F10 menu

static void teardown(void) {
    for (int i = 0; i < 2; ++i) {
        if (players[i]) [players[i] stopAtTime:CHHapticTimeImmediate error:nil];
        if (engines[i]) [engines[i] stopWithCompletionHandler:nil];
        players[i] = nil; engines[i] = nil; running[i] = 0; sent[i] = -1;
    }
    pad = nil;
}
static id<CHHapticAdvancedPatternPlayer> make_player(CHHapticEngine *e) {
    NSError *err = nil;
    CHHapticEventParameter *in = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1];
    CHHapticEventParameter *sh = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.4f];
    CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[in, sh]
                                                    relativeTime:0 duration:30];
    CHHapticPattern *p = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:&err];
    id<CHHapticAdvancedPatternPlayer> pl = p ? [e createAdvancedPlayerWithPattern:p error:&err] : nil;
    pl.loopEnabled = YES;
    if (!pl && diag_on) diag_event("rumble: no haptic player: %s", err.localizedDescription.UTF8String ?: "?");
    return pl;
}
static void setup(GCController *c) {
    teardown();
    pad = c;
    GCDeviceHaptics *h = c.haptics;
    if (!h) { fprintf(stderr, "rumble: %s has no haptics\n", c.vendorName.UTF8String ?: "the pad"); return; }
    NSSet<GCHapticsLocality> *loc = h.supportedLocalities;
    if ([loc containsObject:GCHapticsLocalityLeftHandle] && [loc containsObject:GCHapticsLocalityRightHandle]) {
        engines[0] = [h createEngineWithLocality:GCHapticsLocalityLeftHandle];
        engines[1] = [h createEngineWithLocality:GCHapticsLocalityRightHandle];
    } else engines[0] = [h createEngineWithLocality:GCHapticsLocalityDefault];
    for (int i = 0; i < 2; ++i) {
        CHHapticEngine *e = engines[i];
        if (!e) continue;
        e.playsHapticsOnly = YES;
        int slot = i;
        // The haptics server can stop or reset an engine (the pad sleeps, the app goes to the background): start again.
        e.resetHandler = ^{ dispatch_async(q, ^{
            if (engines[slot] != e) return;
            [e startAndReturnError:nil];
            players[slot] = make_player(e); running[slot] = 0; sent[slot] = -1;
        }); };
        e.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; dispatch_async(q, ^{
            if (engines[slot] == e) { running[slot] = 0; sent[slot] = -1; }
        }); };
        NSError *err = nil;
        if (![e startAndReturnError:&err]) { fprintf(stderr, "rumble: engine %d: %s\n", i, err.localizedDescription.UTF8String ?: "?"); engines[i] = nil; continue; }
        players[i] = make_player(e);
    }
    fprintf(stderr, "rumble: %s, %s\n", c.vendorName.UTF8String ?: "pad", engines[1] ? "two motors (left heavy, right light)" : "one motor");
}
static void play(int i, float v) {
    if (!players[i]) return;
    if (sent[i] >= 0 && fabsf(v - sent[i]) < 0.02f && (v > 0) == (sent[i] > 0)) return;
    NSError *err = nil;
    if (v <= 0.004f) {
        if (running[i]) [players[i] stopAtTime:CHHapticTimeImmediate error:&err];
        running[i] = 0;
    } else {
        if (!running[i]) {
            if (!engines[i] || ![engines[i] startAndReturnError:&err]) return;
            running[i] = [players[i] startAtTime:CHHapticTimeImmediate error:&err];
        }
        CHHapticDynamicParameter *dp = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                                                                       value:v relativeTime:0];
        [players[i] sendParameters:@[dp] atTime:CHHapticTimeImmediate error:&err];
    }
    sent[i] = v;
}
static GCController *current_pad(void) {
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) return c;
    return nil;
}
static void flush(void) {
    queued = 0;
    GCController *c = current_pad();
    if (c != pad) { if (c) setup(c); else teardown(); }
    uint32_t w = closed || suppressed ? 0 : want;
    float heavy = (w & 0xFF) / 255.0f, light = (w >> 8 & 0xFF) / 255.0f;
    if (engines[1]) { play(0, heavy); play(1, light); }
    else play(0, fmaxf(heavy, light));
}
static void post_levels(uint8_t heavy, uint8_t light) {
    want = heavy | (uint32_t)light << 8;
    if (!atomic_exchange(&queued, 1)) dispatch_async(q, ^{ flush(); });
}

void rumble_stop(void) {
    if (!q) return;
    want = 0;
    dispatch_async(q, ^{ flush(); });
}
void rumble_suppress(int on) { suppressed = on; rumble_stop(); }
void rumble_close(void) {
    if (!q || atomic_exchange(&closed, 1)) return;
    dispatch_sync(q, ^{ flush(); teardown(); });
}
void rumble_signals(void) {}                 // an app on the Apple TV ends without signals from a terminal
void rumble_set_enabled(int on) {
    if (!on && rumble_off != 1) rumble_stop();
    rumble_off = !on;
    if (diag_on) diag_event("rumble: now %s", on ? "on" : "off");
}
void rumble_update(void) {
    if (rumble_off < 0) { const char *e = getenv("NFS_RUMBLE"); rumble_off = e && !strcmp(e, "off"); }
    float hf, lf;
    feedback_levels(&hf, &lf);               // the model advances whether or not anything plays it
    if (rumble_off) return;
    if (!q) { q = dispatch_queue_create("nfsmw.rumble", DISPATCH_QUEUE_SERIAL); atexit(rumble_close); }
    if (!closed) post_levels((uint8_t)lroundf(hf * 255), (uint8_t)lroundf(lf * 255));
}
