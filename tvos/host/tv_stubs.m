// tv_stubs.m - the Mac-only features the Apple TV build leaves out, as the no-ops the rest of the runtime calls.
//   report.m, report_github.m, report_submit.m   problem reports (screenshots, Finder, GitHub): logs only (tvos/tv.sh log)
//   cliprec.mm                                   video clips to Movies/NFSMW: no Movies folder on the Apple TV
//   pub_discord.c                                Discord status: no Discord client on the Apple TV
// Their F10 rows are hidden (tv_app.m, tv_hide_rows).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "host.h"
#include "tv_host.h"

#ifndef PORT_BUILD_ID
#define PORT_BUILD_ID "tvOS"
#endif
const char *port_build_id(void) { return PORT_BUILD_ID; }

// ---- report.m: notes go to the log; no reports, screenshots or watchdog dumps ----
void report_init(void) {}
void report_frame(uint64_t frame, uint32_t flow) { (void)frame; (void)flow; }
void report_note(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    fprintf(stderr, "note: %s\n", line);
}
void report_auto(const char *why, const char *diag_file) { fprintf(stderr, "report: %s (%s)\n", why ? why : "?", diag_file ? diag_file : "-"); }
void report_save_async(const char *category, const char *note) { (void)category; (void)note; }
const char *report_last_path(void) { return ""; }
const char *report_session_dir(void) { return log_dir(); }
void report_request_shot(void) {}
int report_shot(char *path, size_t n) { (void)path; (void)n; return 0; }
void report_shot_ready(const char *path) { (void)path; }
void report_live(float *fps, float *p99, float *gpu) { if (fps) *fps = 0; if (p99) *p99 = 0; if (gpu) *gpu = 0; }
const char *report_audio_device(void) {
    static char name[128];
    tv_audio_route_name(name, sizeof name);
    return name;
}

// ---- report_github.m: the in-menu report form ----
int report_github_active(void) { return 0; }
void report_github_close(void) {}
void report_github_draw(CGContextRef ctx, double height, CGRect viewport, int xbox) { (void)ctx; (void)height; (void)viewport; (void)xbox; }
void report_github_key_event(int key, int down, int repeat) { (void)key; (void)down; (void)repeat; }
void report_github_mouse(int kind, double x, double y, double scroll) { (void)kind; (void)x; (void)y; (void)scroll; }
void report_github_pad(int direction, uint32_t edge) { (void)direction; (void)edge; }
void report_github_pad_release(uint32_t physical) { (void)physical; }

// ---- cliprec.mm ----
void cliprec_action(int unused) { (void)unused; }
void cliprec_open_folder(int unused) { (void)unused; }
void cliprec_status(char *buf, int size) { if (size > 0) buf[0] = 0; }
void cliprec_present(id<MTLCommandBuffer> __unsafe_unretained cb, id<MTLTexture> __unsafe_unretained src,
                     id<CAMetalDrawable> __unsafe_unretained drawable, float headroom) {
    (void)cb; (void)src; (void)drawable; (void)headroom;
}

int cliprec_live_start(void) { return 0; }
void replay_arm_action(int unused) { (void)unused; }
void replay_save_action(int unused) { (void)unused; }
void replay_status(char *buf, int size) { if (size > 0) buf[0] = 0; }
void replay_save_status(char *buf, int size) { if (size > 0) buf[0] = 0; }

// ---- gpuclients.m: other processes' GPU use comes from the IOKit registry, which tvOS doesn't open to apps ----
#include <math.h>
#include "gpuclients.h"
GPUClients *gpuclients_create(void) { return NULL; }
void gpuclients_destroy(GPUClients *s) { (void)s; }
void gpuclients_sample(GPUClients *s, GPUClientsSample *out) {
    (void)s;
    memset(out, 0, sizeof *out);
    out->dev_util = out->self_ms = out->other_ms = NAN;
    strcpy(out->top, "-"); strcpy(out->mhz, "-"); strcpy(out->states, "-"); strcpy(out->clock_status, "unavailable on tvOS");
}
void gpuclients_publish(const GPUClientsSample *s) { (void)s; }

// ---- pub_discord.c ----
void pub_discord_tick(uint32_t flow) { (void)flow; }

// ---- stream_key.m: the stream key is typed into an AppKit panel; no live streaming from the Apple TV ----
void stream_key_edit(int unused) { (void)unused; }
void stream_key_forget(int unused) { (void)unused; }
void stream_key_go(int unused) { (void)unused; }
void stream_key_stop(int unused) { (void)unused; }
void stream_key_status(char *buf, int size) { if (size > 0) snprintf(buf, size, "Not on Apple TV"); }
void stream_key_close(void) {}
int stream_key_editing(void) { return 0; }
