// tv_host.h - the Apple TV host (tvos/host/tv_app.m) as the runtime sees it.
//
// On the Mac the game runs on the main thread and pumps Cocoa events itself (user32.m). On the Apple TV UIKit owns the
// main thread: tv_app.m makes the window and its CAMetalLayer view there, then runs boot.c's main() (compiled as
// nfsmw_main) on a thread of its own. user32.m attaches the game window to that view and receives the focus changes and
// keyboard keys the host forwards; media.cpp asks the host about the audio route.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __OBJC__
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
UIWindow *tv_host_window(void);          // the scene's window (nil before the scene connects)
UIView *tv_host_view(void);              // its view (only touched on the main thread)
CAMetalLayer *tv_host_layer(void);       // the view's layer, safe to use from the game and render threads
#endif

#ifdef __cplusplus
extern "C" {
#endif
int tv_host_active(void);                // the scene is in front (not the Home screen, the screensaver or Control Center)
int tv_host_is_game_thread(void);        // the calling thread runs boot.c's main() (the Mac's main thread)
int tv_host_background(void);            // the app is in the background: no GPU work is allowed
void tv_host_wait_foreground(void);      // blocks until the app is in front again
void tv_host_screen(int *w_points, int *h_points, double *scale, int *hz);
void tv_host_wait(double seconds);       // the game thread waits for a host event (focus, key) or the time to pass
void tv_host_wake(void);

// Audio route (AVAudioSession), for media.cpp. The session is a playback session made active on first use.
int tv_audio_route_channels(void);       // output channels the route takes now (2, 6 or 8 over HDMI)
int tv_audio_route_labels(uint32_t *labels, int max);   // AudioChannelLabel per output channel, 0 when unknown
void tv_audio_route_name(char *out, size_t n);
uint64_t tv_audio_route_generation(void);   // rises when the route changes (TV, receiver, AirPods)
double tv_audio_io_seconds(void);        // the hardware I/O buffer duration
int tv_audio_activate(int channels);     // asks for that many output channels; returns what the route gives

// user32.m, called by the host on the main thread.
void user32_tv_focus(int active);        // the scene became active / resigned active
void user32_tv_key(uint32_t hid_usage, int down);   // a GCKeyboard key (HID usage page 7)
#ifdef __cplusplus
}
#endif
