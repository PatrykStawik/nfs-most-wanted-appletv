// tv_app.m - the Apple TV app around the game: UIKit, the game thread, folders, preferences, logs, the audio session.
//
// The tvOS counterpart of runtime/app.m. UIApplicationMain owns the main thread; the scene makes a window whose view is
// backed by a CAMetalLayer, then boot.c's main() (compiled as nfsmw_main by tvos/build.sh) runs the game on a thread of
// its own, which is what the Mac calls the main thread (user32.m pumps its messages there, render.m draws from it).
//   the game          the app's Game folder (read only; tvos/build.sh copies the player's PC folder into the app)
//   saves, settings   Library/Caches/NFSMW (BOOT_USERDATA): registry.txt, app.txt, the saves, the shader cache, Logs/
// tvOS may purge Caches when the disk is full; nothing else on the Apple TV is writable for an app.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "host.h"
#include "durable.h"
#include "settings.h"
#include "tv_host.h"

int nfsmw_main(int argc, char **argv);     // runtime/boot.c's main()
int app_bundled = 1;
static const char *model(void);

// ---------------- folders ----------------
static char g_support[1024], g_game[1024];

static void mkdirs(const char *p) {
    char t[1200];
    snprintf(t, sizeof t, "%s", p);
    for (char *s = t + 1; *s; ++s) if (*s == '/') { *s = 0; mkdir(t, 0755); *s = '/'; }
    mkdir(t, 0755);
}

const char *log_dir(void) {
    static char dir[1100];
    if (!dir[0]) { snprintf(dir, sizeof dir, "%s/Logs", g_support[0] ? g_support : "/tmp"); mkdirs(dir); }
    return dir;
}
const char *log_name(void) { return "NFSMW"; }

// ---------------- USERDATA/app.txt (the Mac's code, runtime/app.m's "offline prefs" block, extracted by build.sh) ----------------
#include "app_prefs.inc"

// ---------------- logs ----------------
// The log goes to Library/Caches/NFSMW/Logs/NFSMW.log (the previous run's kept as NFSMW.previous.log), where
// `tvos/tv.sh log` fetches it from. BOOT_LOG=- keeps stdout/stderr on the console (`tvos/tv.sh run` and `launch` set it).
static void log_setup(void) {
    const char *e = getenv("BOOT_LOG");
    if (!(e && !strcmp(e, "-"))) {
        char path[1200], prev[1200];
        snprintf(path, sizeof path, "%s/NFSMW.log", log_dir());
        snprintf(prev, sizeof prev, "%s/NFSMW.previous.log", log_dir());
        rename(path, prev);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { fflush(stdout); fflush(stderr); dup2(fd, 1); dup2(fd, 2); close(fd); }
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);
    time_t now = time(NULL);
    char when[64];
    strftime(when, sizeof when, "%Y-%m-%d %H:%M:%S", localtime(&now));
    NSString *ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    printf("boot: NFSMW %s (Apple TV), %s, tvOS %s\n", ver ? ver.UTF8String : "?", when,
           NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
}

// ---------------- what app.m gives the runtime ----------------
int app_fullscreen_resolve(const char *mode, int builtin) {
    if (!mode) return 0;
    if (!strcasecmp(mode, "native")) return 1;
    return !strcasecmp(mode, "auto") && builtin;
}
int app_fullscreen_is_auto(void) { return 0; }
int app_native_fullscreen(void) { return 0; }   // the game always fills the TV
int app_screen_is_builtin(void) { return 0; }
void app_cocoa_init(void) {}
void app_restart_game_exited(int successful) { (void)successful; }

static int confirm_twice(double *armed_until, const char *what) {
    void portmenu_status(const char *fmt, ...);
    double now = host_ticks() / 1e9;
    if (now > *armed_until) {
        *armed_until = now + 4;
        portmenu_status("Press again within 4 s to %s; race progress since the last save is lost.", what);
        return 0;
    }
    *armed_until = 0;
    return 1;
}
// F10 > Quit game: the game's own exit path (WM_CLOSE); the process ends when the game calls ExitProcess.
void app_quit_game(int unused) {
    (void)unused;
    static double armed_until;
    if (!confirm_twice(&armed_until, "quit")) return;
    if (!prefs_save()) fprintf(stderr, "boot: quit: settings save failed\n");
    fprintf(stderr, "boot: quit requested from the menu\n");
    if (!user32_request_close()) { fflush(NULL); exit(0); }
}
// An app can't start itself again on the Apple TV: the game closes and the player opens it again from the Home screen.
void app_restart_game(int unused) {
    (void)unused;
    void portmenu_status(const char *fmt, ...);
    static double armed_until;
    if (!confirm_twice(&armed_until, "close the game (open it again from the Home screen)")) return;
    if (!prefs_save()) { portmenu_status("Could not save settings; restart cancelled."); return; }
    fprintf(stderr, "boot: restart requested: the game closes, the player reopens it\n");
    if (!user32_request_close()) { fflush(NULL); exit(0); }
}

// A fatal runtime error (boot.c's die): an alert on the TV, then the caller exits.
void app_fatal(const char *msg) {
    if (getenv("BOOT_HEADLESS") || [NSThread isMainThread]) return;
    NSString *text = [NSString stringWithFormat:@"%s\n\nThe log is in the app's Caches/NFSMW/Logs (tvos/tv.sh log).", msg];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = tv_host_window().rootViewController;
        if (!root) { dispatch_semaphore_signal(done); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"NFSMW stopped because of an error" message:text
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Quit" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            (void)x; dispatch_semaphore_signal(done);
        }]];
        [root presentViewController:a animated:YES completion:nil];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

// F10 rows that mean nothing on the Apple TV: windows and full screen, Finder folders, clips, problem reports, variable
// refresh, HDR output, the output format (Automatic: PCM 5.1 or stereo for the route; tvOS does Dolby itself), LAN.
static void tv_hide_rows(void) {
    static const char *const ids[] = {
        "display.window", "display.fullscreen", "display.clip_resolution", "display.cliprec", "display.clips_open",
        "graphics.variable_refresh", "graphics.hdr_output", "audio.output",
        "diag.h_report", "diag.report_category", "diag.report_note", "diag.report_save", "diag.report_open", "diag.logs_open",
        "gameplay.lan",
    };
    for (size_t i = 0; i < sizeof ids / sizeof *ids; ++i) { Setting *s = settings_find(ids[i]); if (s) s->hidden = 1; }
    Setting *r = settings_find("diag.restart_game");
    if (r) {
        r->label = "Close game";
        r->help = "Saves settings and closes the game after a second press within 4 seconds; open it again from the Home screen.";
    }
}

// The game folder inside the app (tvos/build.sh puts it at <app>/Game).
const char *app_start(int argc, char **argv) {
    (void)argc; (void)argv;
    @autoreleasepool {
        log_setup();
        tv_hide_rows();
        snprintf(g_game, sizeof g_game, "%s/Game", NSBundle.mainBundle.resourcePath.fileSystemRepresentation);
        char exe[1200];
        snprintf(exe, sizeof exe, "%s/speed.exe", g_game);
        struct stat st;
        if (stat(exe, &st)) {
            fprintf(stderr, "boot: no game in the app (%s): build it with tvos/tv.sh, which copies your game folder in\n", exe);
            app_fatal("This build of the app has no game files. Build it again with tvos/tv.sh and your game folder.");
            exit(1);
        }
        printf("boot: game folder %s\nboot: saves and settings %s\nboot: model %s\n", g_game, userdata_dir(), model());
        return g_game;
    }
}

// ---------------- the model ----------------
#include <sys/sysctl.h>
static char g_model[32];
static const char *model(void) {
    if (!g_model[0]) { size_t n = sizeof g_model; if (sysctlbyname("hw.machine", g_model, &n, NULL, 0)) strcpy(g_model, "?"); }
    return g_model;
}
// For the log: AppleTV6,2 is the 4K 1st generation (A10X), AppleTV11,1 the 2nd (A12), AppleTV14,1 the 3rd (A15).

// ---------------- environment, before the game reads anything ----------------
static void setdef(const char *k, const char *v) { if (!getenv(k)) setenv(k, v, 1); }

static void tv_environment(void) {
    @autoreleasepool {
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        snprintf(g_support, sizeof g_support, "%s/NFSMW", caches ? caches.fileSystemRepresentation : "/tmp");
        mkdirs(g_support);
        // The container is reported under /var, a symlink to /private/var. The save code (boot.c, carsave_public.c)
        // walks the profile path with O_NOFOLLOW and refuses any symlink in it ("Profile refused: Cannot read staged
        // save", autosave off), so the game gets the real path.
        char real[PATH_MAX];
        if (realpath(g_support, real)) snprintf(g_support, sizeof g_support, "%s", real);
        setdef("BOOT_USERDATA", g_support);
        // The roots manifest (runtime/roots.h): the game in the app, caches beside the saves. No Xbox 360 roots.
        char roots[1200], cachedir[1200], tmpdir[1200];
        snprintf(roots, sizeof roots, "%s/roots.txt", g_support);
        snprintf(cachedir, sizeof cachedir, "%s/cache", g_support);
        mkdirs(cachedir);
        if (!realpath(NSTemporaryDirectory().fileSystemRepresentation, tmpdir))
            snprintf(tmpdir, sizeof tmpdir, "%s", NSTemporaryDirectory().fileSystemRepresentation);
        FILE *f = fopen(roots, "w");
        if (f) {
            fprintf(f, "# written by the Apple TV app at every launch\npc_root=%s/Game\ncaches=%s\ntmp=%s\n",
                    NSBundle.mainBundle.resourcePath.fileSystemRepresentation, cachedir, tmpdir);
            fclose(f);
        }
        setdef("NFS_ROOTS", roots);
        void tv_cloud_start(const char *userdata);
        tv_cloud_start(g_support);           // the iCloud copies of the saves, before the game reads them
        // Logs and crash reports, the Metal shader cache: under the same folder.
        setdef("TMPDIR", tmpdir);
        if (chdir(g_support)) fprintf(stderr, "app: chdir %s: %s\n", g_support, strerror(errno));
    }
}

// ---------------- the view ----------------
static UIWindow *g_window;
static UIView *g_view;
static CAMetalLayer *g_layer;
static _Atomic int g_active;
static pthread_t g_game_thread;
static int g_game_thread_set;
static int g_screen_w = 1920, g_screen_h = 1080, g_screen_hz = 60;
static double g_screen_scale = 1;

UIWindow *tv_host_window(void) { return g_window; }
UIView *tv_host_view(void) { return g_view; }
CAMetalLayer *tv_host_layer(void) { return g_layer; }
int tv_host_active(void) { return g_active; }
int tv_host_is_game_thread(void) { return g_game_thread_set && pthread_equal(pthread_self(), g_game_thread); }
void tv_host_screen(int *w, int *h, double *scale, int *hz) {
    if (w) *w = g_screen_w;
    if (h) *h = g_screen_h;
    if (scale) *scale = g_screen_scale;
    if (hz) *hz = g_screen_hz;
}

static pthread_mutex_t wait_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wait_cv = PTHREAD_COND_INITIALIZER;
static int wait_pending;
void tv_host_wait(double seconds) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long ns = ts.tv_nsec + (long)(seconds * 1e9);
    ts.tv_sec += ns / 1000000000L; ts.tv_nsec = ns % 1000000000L;
    pthread_mutex_lock(&wait_mu);
    while (!wait_pending && pthread_cond_timedwait(&wait_cv, &wait_mu, &ts) == 0) {}
    wait_pending = 0;
    pthread_mutex_unlock(&wait_mu);
}
void tv_host_wake(void) {
    pthread_mutex_lock(&wait_mu);
    wait_pending = 1;
    pthread_cond_signal(&wait_cv);
    pthread_mutex_unlock(&wait_mu);
}

// Background: set when the scene enters the background, cleared when it comes back (render_present.m waits on it).
static pthread_mutex_t bg_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t bg_cv = PTHREAD_COND_INITIALIZER;
static _Atomic int g_background;
int tv_host_background(void) { return g_background; }
void tv_host_wait_foreground(void) {
    pthread_mutex_lock(&bg_mu);
    while (g_background) pthread_cond_wait(&bg_cv, &bg_mu);
    pthread_mutex_unlock(&bg_mu);
}
static void set_background(int on) {
    pthread_mutex_lock(&bg_mu);
    g_background = on;
    pthread_cond_broadcast(&bg_cv);
    pthread_mutex_unlock(&bg_mu);
}

// The drawable is the back buffer's size (d3d9.m / user32.m set it); UIKit sets a CAMetalLayer-backed view's drawable to
// its own size whenever it lays the view out, so the game's size is put back.
@interface NFSMWView : UIView
@end
@implementation NFSMWView {
    CGSize _drawable;
}
+ (Class)layerClass { return [CAMetalLayer class]; }
- (void)layoutSubviews {
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    CGSize d = l.drawableSize;
    [super layoutSubviews];
    if (d.width > 0 && d.height > 0 && !CGSizeEqualToSize(l.drawableSize, d)) l.drawableSize = d;
}
@end

// controllerUserInteractionEnabled = NO: a pad's B / Circle and Menu buttons reach the game instead of leaving the app.
@interface NFSMWController : GCEventViewController
@end
@implementation NFSMWController
- (void)loadView {
    NFSMWView *v = [[NFSMWView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    v.backgroundColor = UIColor.blackColor;
    v.contentScaleFactor = 1;                       // drawable pixels = the game's back buffer, scaled to the TV
    CAMetalLayer *l = (CAMetalLayer *)v.layer;
    l.opaque = YES;
    l.contentsGravity = kCAGravityResizeAspect;
    l.backgroundColor = UIColor.blackColor.CGColor;
    l.drawableSize = CGSizeMake(1920, 1080);
    self.view = v;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.controllerUserInteractionEnabled = NO;
}
@end

// ---------------- keyboard (GCKeyboard: a Bluetooth keyboard paired with the Apple TV) ----------------
static void keyboard_attach(GCKeyboard *kb) {
    if (!kb) return;
    kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *in, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) {
        (void)in; (void)key;
        user32_tv_key((uint32_t)code, pressed);
        tv_host_wake();
    };
}

// ---------------- the Siri Remote: menu keys (it can't drive; a game controller does) ----------------
// Swipes and the touch surface's edges are the arrow keys, a click is Enter, Menu (Back) is Escape, Play/Pause is Enter.
// The game's own pad code (user32.m) only reads full game controllers, so the remote reaches it as a keyboard.
enum { HID_RIGHT = 0x4F, HID_LEFT = 0x50, HID_DOWN = 0x51, HID_UP = 0x52, HID_RETURN = 0x28, HID_ESCAPE = 0x29 };
static void remote_key(uint32_t hid, int down) { user32_tv_key(hid, down); tv_host_wake(); }
static void remote_tap(uint32_t hid) {
    remote_key(hid, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ remote_key(hid, 0); });
}
static void remote_attach(GCController *c) {
    GCMicroGamepad *m = c.microGamepad;
    if (!m || c.extendedGamepad) return;
    m.reportsAbsoluteDpadValues = NO;            // swipes, not finger positions
    m.allowsRotation = NO;
    __block int armed_x = 1, armed_y = 1;        // one key per swipe: re-armed when the touch returns to the centre
    m.dpad.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        (void)pad;
        if (fabsf(x) < 0.2f) armed_x = 1;
        if (fabsf(y) < 0.2f) armed_y = 1;
        if (armed_x && fabsf(x) > 0.7f && fabsf(x) > fabsf(y)) { armed_x = 0; remote_tap(x > 0 ? HID_RIGHT : HID_LEFT); }
        else if (armed_y && fabsf(y) > 0.7f && fabsf(y) > fabsf(x)) { armed_y = 0; remote_tap(y > 0 ? HID_UP : HID_DOWN); }
    };
    m.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { (void)b; (void)v; remote_key(HID_RETURN, pressed); };
    m.buttonX.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { (void)b; (void)v; remote_key(HID_RETURN, pressed); };
    m.buttonMenu.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { (void)b; (void)v; remote_key(HID_ESCAPE, pressed); };
    fprintf(stderr, "app: %s: menu keys (swipe, click, Menu)\n", c.vendorName.UTF8String ?: "Siri Remote");
}

// ---------------- the game thread ----------------
static void *game_thread(void *arg) {
    (void)arg;
    pthread_setname_np("nfsmw game");
    static char *argv[] = {(char *)"NFSMW", NULL};
    int rc = nfsmw_main(1, argv);
    fprintf(stderr, "app: the game ended (%d)\n", rc);
    fflush(NULL);
    exit(rc);
    return NULL;
}
static void start_game(void) {
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 64u << 20);     // the translated code's host frames nest as deep as the game's calls
    // The Mac runs the game on the main thread (user-interactive); a default-QoS thread here was often put on the
    // efficiency cores (game thread ~15 ms a frame in a race).
    pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_t th;
    if (pthread_create(&th, &at, game_thread, NULL)) { fprintf(stderr, "app: the game thread could not be created\n"); return; }
    g_game_thread = th;
    g_game_thread_set = 1;
    pthread_detach(th);
}

@interface NFSMWApp : UIResponder <UIApplicationDelegate>
@end
@implementation NFSMWApp
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    (void)o;
    a.idleTimerDisabled = YES;                     // pad input doesn't keep the Apple TV awake on its own
    tv_environment();
    keyboard_attach(GCKeyboard.coalescedKeyboard);
    [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { keyboard_attach(n.object); }];
    for (GCController *c in GCController.controllers) remote_attach(c);
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { remote_attach(n.object); }];
    return YES;
}
@end

@interface NFSMWScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation NFSMWScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    (void)session; (void)opts;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
    NFSMWController *vc = [NFSMWController new];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    g_window = self.window;
    g_view = vc.view;
    g_layer = (CAMetalLayer *)vc.view.layer;
    // Points are the game's pixels (1920x1080 on every Apple TV); the TV output (4K or 1080p) scales the picture.
    CGSize pt = ws.screen.bounds.size;
    g_screen_w = (int)pt.width; g_screen_h = (int)pt.height;
    g_screen_scale = 1;
    NSInteger hz = ws.screen.maximumFramesPerSecond;
    g_screen_hz = hz > 0 ? (int)hz : 60;
    fprintf(stderr, "app: screen %dx%d points (scale %.0f, native %.0fx%.0f), %d Hz\n", g_screen_w, g_screen_h,
            ws.screen.scale, ws.screen.nativeBounds.size.width, ws.screen.nativeBounds.size.height, g_screen_hz);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ start_game(); });
}
// The game pauses while the app isn't in front (Home, the screensaver, Control Center), as on a Mac on focus loss.
- (void)sceneDidBecomeActive:(UIScene *)s { (void)s; g_active = 1; user32_tv_focus(1); tv_host_wake(); }
- (void)sceneWillResignActive:(UIScene *)s { (void)s; g_active = 0; user32_tv_focus(0); tv_host_wake(); }
- (void)sceneDidEnterBackground:(UIScene *)s { (void)s; set_background(1); void tv_cloud_flush(void); tv_cloud_flush(); }
- (void)sceneWillEnterForeground:(UIScene *)s { (void)s; set_background(0); }
@end

int nfsmw_tv_run(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(NFSMWApp.class)); }
}

// ---------------- the audio route (AVAudioSession), for media.cpp ----------------
static _Atomic uint64_t route_generation;
static void audio_session_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AVAudioSession *s = AVAudioSession.sharedInstance;
        NSError *e = nil;
        if (![s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&e])
            fprintf(stderr, "audio: session category: %s\n", e.localizedDescription.UTF8String);
        [s setPreferredSampleRate:48000 error:nil];
        [s setPreferredIOBufferDuration:0.010 error:nil];
        if (![s setActive:YES error:&e]) fprintf(stderr, "audio: session activation: %s\n", e.localizedDescription.UTF8String);
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *n) { (void)n; ++route_generation; }];
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *n) { (void)n; ++route_generation; }];
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *n) {
            NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
            if (type == AVAudioSessionInterruptionTypeEnded) { [AVAudioSession.sharedInstance setActive:YES error:nil]; ++route_generation; }
        }];
    });
}
int tv_audio_activate(int channels) {
    audio_session_init();
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSInteger want = MIN((NSInteger)channels, s.maximumOutputNumberOfChannels);
    if (want > 0 && s.outputNumberOfChannels != want) {
        NSError *e = nil;
        if (![s setPreferredOutputNumberOfChannels:want error:&e])
            fprintf(stderr, "audio: %ld channels refused: %s\n", (long)want, e.localizedDescription.UTF8String);
    }
    return (int)s.outputNumberOfChannels;
}
int tv_audio_route_channels(void) {
    audio_session_init();
    return (int)AVAudioSession.sharedInstance.maximumOutputNumberOfChannels;
}
int tv_audio_route_labels(uint32_t *labels, int max) {
    audio_session_init();
    int n = 0;
    for (AVAudioSessionPortDescription *p in AVAudioSession.sharedInstance.currentRoute.outputs)
        for (AVAudioSessionChannelDescription *c in p.channels) if (n < max) labels[n++] = c.channelLabel;
    return n;
}
void tv_audio_route_name(char *out, size_t n) {
    audio_session_init();
    AVAudioSessionPortDescription *p = AVAudioSession.sharedInstance.currentRoute.outputs.firstObject;
    snprintf(out, n, "%s", p ? p.portName.UTF8String : "?");
}
uint64_t tv_audio_route_generation(void) { audio_session_init(); return route_generation; }
double tv_audio_io_seconds(void) { audio_session_init(); return AVAudioSession.sharedInstance.IOBufferDuration; }
