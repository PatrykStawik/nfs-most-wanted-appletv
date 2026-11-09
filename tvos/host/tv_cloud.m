// tv_cloud.m - the game's saves in iCloud (the key-value store), so they survive tvOS clearing the app's caches, a
// reinstall, or a move to another Apple TV signed in to the same Apple Account.
//
// The saves are the files under <BOOT_USERDATA>/NFS Most Wanted (one folder per profile, about 64 KB each, about a tenth
// of that compressed). Each file is one key, "save/<relative path>", holding {data: zlib bytes, mtime, size}; the store
// takes 1 MB per app.
//   at launch    (before the game reads anything) a cloud copy newer than the local file, or one with no local file
//                that this Apple TV never had, is written locally; the newest file wins, there is no merge
//   while playing  every 5 s, and when the app leaves the screen, a file that changed is sent; a file the game
//                deleted (a profile deleted in the game) is deleted in the cloud too
// cloud.json (beside the saves) remembers what this Apple TV last sent or received, which tells a profile deleted here
// from one that only exists in the cloud. Changes from another Apple TV arrive at the next launch: files are never
// replaced under a running game. Needs the iCloud key-value capability (tvos/app/NFSMW.entitlements) and an Apple Account
// signed in on the Apple TV; without them the store stays local and nothing is lost.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static NSString *g_root;                 // <BOOT_USERDATA>/NFS Most Wanted
static NSString *g_manifest_path;
static NSMutableDictionary<NSString *, NSDictionary *> *g_manifest;   // relative path -> {mtime, size}
static dispatch_queue_t g_q;
static NSString *const kPrefix = @"save/";

static BOOL safe_relative(NSString *rel) {
    if (rel.length == 0 || rel.length > 512 || [rel hasPrefix:@"/"]) return NO;
    for (NSString *part in [rel componentsSeparatedByString:@"/"])
        if (part.length == 0 || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    return YES;
}
static BOOL is_temp(NSString *name) { return [name containsString:@".nfs-save-"] || [name hasPrefix:@"."]; }

static void manifest_save(void) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:g_manifest options:0 error:nil];
    [d writeToFile:g_manifest_path atomically:YES];
}

// Local save files: relative path -> {mtime, size}.
static NSDictionary<NSString *, NSDictionary *> *scan(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:g_root];
    for (NSString *rel in e) {
        if (is_temp(rel.lastPathComponent)) continue;
        struct stat st;
        NSString *full = [g_root stringByAppendingPathComponent:rel];
        if (lstat(full.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || !safe_relative(rel)) continue;
        out[rel] = @{@"mtime": @(st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9), @"size": @(st.st_size)};
    }
    return out;
}

static BOOL write_local(NSString *rel, NSData *data, double mtime) {
    NSString *full = [g_root stringByAppendingPathComponent:rel];
    [NSFileManager.defaultManager createDirectoryAtPath:full.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    if (![data writeToFile:full atomically:YES]) return NO;
    struct timeval tv[2] = {{(time_t)mtime, (suseconds_t)((mtime - floor(mtime)) * 1e6)}, {(time_t)mtime, (suseconds_t)((mtime - floor(mtime)) * 1e6)}};
    utimes(full.fileSystemRepresentation, tv);
    return YES;
}

// Launch: bring the cloud's newer saves in, before the game starts.
void tv_cloud_start(const char *userdata) {
    g_root = [[NSString stringWithUTF8String:userdata] stringByAppendingPathComponent:@"NFS Most Wanted"];
    g_manifest_path = [[NSString stringWithUTF8String:userdata] stringByAppendingPathComponent:@"cloud.json"];
    g_q = dispatch_queue_create("nfsmw.cloud", DISPATCH_QUEUE_SERIAL);
    NSData *m = [NSData dataWithContentsOfFile:g_manifest_path];
    NSDictionary *loaded = m ? [NSJSONSerialization JSONObjectWithData:m options:0 error:nil] : nil;
    g_manifest = [loaded isKindOfClass:NSDictionary.class] ? [loaded mutableCopy] : [NSMutableDictionary dictionary];

    NSUbiquitousKeyValueStore *kv = NSUbiquitousKeyValueStore.defaultStore;
    [kv synchronize];
    NSDictionary *local = scan();
    int got = 0;
    for (NSString *key in kv.dictionaryRepresentation) {
        if (![key hasPrefix:kPrefix]) continue;
        NSString *rel = [key substringFromIndex:kPrefix.length];
        NSDictionary *v = [kv dictionaryForKey:key];
        NSData *z = v[@"data"];
        double mtime = [v[@"mtime"] doubleValue];
        if (!safe_relative(rel) || ![z isKindOfClass:NSData.class]) continue;
        NSDictionary *mine = local[rel];
        if (!mine && g_manifest[rel]) continue;                      // deleted on this Apple TV: the next pass deletes it there
        if (mine && [mine[@"mtime"] doubleValue] >= mtime - 0.001) continue;   // ours is as new or newer
        NSData *data = [z decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
        if (!data || data.length != [v[@"size"] unsignedLongLongValue]) { fprintf(stderr, "cloud: %s damaged in iCloud, kept local\n", rel.UTF8String); continue; }
        if (write_local(rel, data, mtime)) {
            g_manifest[rel] = @{@"mtime": @(mtime), @"size": @(data.length)};
            fprintf(stderr, "cloud: %s from iCloud (%lu bytes)\n", rel.UTF8String, (unsigned long)data.length);
            ++got;
        }
    }
    if (got) manifest_save();
    // A profile folder with nothing in it (a save that never completed) can't load: the game would list it as damaged.
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:g_root error:nil]) {
        NSString *dir = [g_root stringByAppendingPathComponent:name];
        if (rmdir(dir.fileSystemRepresentation) == 0) fprintf(stderr, "cloud: removed empty profile folder %s\n", name.UTF8String);
    }
    fprintf(stderr, "cloud: %d save file(s) in iCloud, %d brought in\n",
            (int)[[kv.dictionaryRepresentation.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@", kPrefix]] count], got);

    // From now on: send what the game changes.
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    void tv_cloud_push(void);
    dispatch_source_set_event_handler(t, ^{ tv_cloud_push(); });
    dispatch_resume(t);
    static dispatch_source_t keep; keep = t;
}

static void push_now(void) {
    NSUbiquitousKeyValueStore *kv = NSUbiquitousKeyValueStore.defaultStore;
    NSDictionary *local = scan();
    int changed = 0;
    for (NSString *rel in local) {
        NSDictionary *was = g_manifest[rel], *now = local[rel];
        if (was && [was[@"mtime"] doubleValue] == [now[@"mtime"] doubleValue] && [was[@"size"] isEqual:now[@"size"]]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[g_root stringByAppendingPathComponent:rel]];
        NSData *z = [data compressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
        if (!z || z.length > 900 * 1024) { fprintf(stderr, "cloud: %s not sent (%lu bytes)\n", rel.UTF8String, (unsigned long)z.length); continue; }
        [kv setDictionary:@{@"data": z, @"mtime": now[@"mtime"], @"size": @(data.length)} forKey:[kPrefix stringByAppendingString:rel]];
        g_manifest[rel] = now;
        fprintf(stderr, "cloud: %s to iCloud (%lu bytes, %lu compressed)\n", rel.UTF8String, (unsigned long)data.length, (unsigned long)z.length);
        ++changed;
    }
    for (NSString *rel in g_manifest.allKeys) {
        if (local[rel]) continue;
        [kv removeObjectForKey:[kPrefix stringByAppendingString:rel]];   // the game deleted it (a deleted profile)
        [g_manifest removeObjectForKey:rel];
        fprintf(stderr, "cloud: %s deleted in iCloud\n", rel.UTF8String);
        ++changed;
    }
    if (changed) { manifest_save(); [kv synchronize]; }
}
void tv_cloud_push(void) { if (g_q) @autoreleasepool { push_now(); } }
// The app leaves the screen: send now (tvOS may suspend it in a few seconds).
void tv_cloud_flush(void) { if (g_q) dispatch_sync(g_q, ^{ @autoreleasepool { push_now(); } }); }
