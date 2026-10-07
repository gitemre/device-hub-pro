/* fastinput-helper: a resident process that keeps one CoreDevice UniversalHID
   service connection (touch) and one HID button connection open for a phone and
   turns a line protocol on stdin into HID reports.

   Derived from `ipb_bench.m` (a local benchmark written on top of ipb, see
   PROVENANCE.md). Protocol, one command per line, exactly one answer line each:
     down|move|up <x> <y>      normalised 0..1, portrait, top-left origin
     tap <x> <y> <holdMs>
     edge down|move|up <x> <y>  bottom-edge gesture (home swipe, App Switcher hold) over the digitizer
                                connection, normalised like down/move/up; err 7 when that connection is missing
     button home|volumeUp|volumeDown|appSwitcher
     hid <page-hex> <usage-hex> down|up   one edge of any HID button (hex, 0x optional; page and
                                usage 1..0xffff): the button stays as the last edge left it, so
                                holds and combinations come from the caller's down and up lines
     key <usage> [down|up|tap]  HID keyboard usage 1..0xE7 (decimal or 0x hex), default tap
     text <utf8>                US layout: printable ASCII; anything else answers
                                "err 8 unsupported character" and sends nothing
     keys [<usage>...]          one keyboard report with exactly these usages held (up to 16, each
                                1..0xE7, decimal or 0x hex; none = all up), then a barrier: the
                                Mac drives the held set, as a real keyboard's reports do
     ping
     quit
   Answers: "ok" or "err <code> <message>". At start: "ready <serviceID>" or
   "fatal <code> <message>" followed by exit (4 tunnel not connected, 3 socket
   refused, 2 usage). Error codes on commands: 1 send failed, 2 bad command,
   6 connection lost, 7 button, digitizer or keyboard connection unavailable, 8 unsupported character.
   Nothing that identifies the phone is ever printed. */
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#include <uuid/uuid.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct OS_xpc_remote_connection *xpc_remote_connection_t;
extern void _coredevice_xpc_add_bundle(NSBundle *bundle);
extern void _coredevice_xpc_init_services(void);
extern xpc_remote_connection_t xpc_remote_connection_create_with_connected_fd(int fd, dispatch_queue_t target_queue, uint64_t version_flags, uint64_t connection_mode);
extern void xpc_remote_connection_set_event_handler(xpc_remote_connection_t connection, xpc_handler_t handler);
extern void xpc_remote_connection_activate(xpc_remote_connection_t connection);
extern void xpc_remote_connection_cancel(xpc_remote_connection_t connection);
extern int coredevice_send_universalhid_hid_report(xpc_remote_connection_t connection, const void *report_words, uint64_t service_id) __attribute__((weak_import));
extern int coredevice_send_universalhid_barrier(xpc_remote_connection_t connection) __attribute__((weak_import));
extern int coredevice_send_hid_button_custom(xpc_remote_connection_t connection, uint64_t usage_page, uint64_t usage_code, uint8_t state) __attribute__((weak_import));
extern int coredevice_send_hid_button_barrier(xpc_remote_connection_t connection) __attribute__((weak_import));
extern int coredevice_send_hid_digitizer_cgpoint(xpc_remote_connection_t connection, double x1, double y1, double x2, double y2, uint64_t second_point_tag, uint64_t event_type, uint64_t edge, uint64_t target_low, uint64_t target_high) __attribute__((weak_import));
extern int coredevice_print_connected_descriptors_async_raw(xpc_remote_connection_t connection) __attribute__((weak_import));
extern int uhid_make_keyboard_set_hid_report(const uint32_t *usages, int count, void *output) __attribute__((weak_import));
extern int uhid_make_keyboard_chord_hid_report(uint32_t modifier, uint32_t usage, int pressed, void *output) __attribute__((weak_import));
extern int uhid_make_digitizer_hid_report(double x, double y, int touching, int in_range, void *output) __attribute__((weak_import));

enum { EXIT_SEND_ = 1, EXIT_USAGE_ = 2, EXIT_SOCKET_ = 3, EXIT_TUNNEL_ = 4 };

static const char *kTouchFeature = "com.apple.coredevice.feature.remote.universalhidservice";
static const char *kButtonFeature = "com.apple.coredevice.feature.remote.hid.button";

static const char *kDigitizerFeature = "com.apple.coredevice.feature.remote.hid.digitizer";

static _Atomic int g_digitizer_lost = 0;
static _Atomic int g_touch_lost = 0;
static _Atomic int g_button_lost = 0;

static void fatal(int code, const char *message) {
    printf("fatal %d %s\n", code, message);
    fflush(stdout);
    exit(code);
}

/* Opens a service socket for `feature`. Returns NULL and sets *exit_code on failure. */
static xpc_remote_connection_t open_remote(xpc_connection_t conn, const char *device, const char *feature,
                                           _Atomic int *lost, int *exit_code, int *fd_out) {
    uuid_t inv;
    uuid_generate(inv);
    char inv_s[37];
    uuid_unparse_upper(inv, inv_s);

    xpc_object_t input = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(input, "featureIdentifier", feature);
    xpc_object_t msg = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(msg, "CoreDevice.actionIdentifier", "com.apple.coredevice.action.createservicesocket");
    xpc_dictionary_set_string(msg, "CoreDevice.deviceIdentifier", device);
    xpc_object_t version = xpc_dictionary_create_empty();
    xpc_object_t comps = xpc_array_create_empty();
    xpc_array_append_value(comps, xpc_uint64_create(636));
    xpc_array_append_value(comps, xpc_uint64_create(3));
    xpc_dictionary_set_value(version, "components", comps);
    xpc_dictionary_set_int64(version, "originalComponentsCount", 2);
    xpc_dictionary_set_string(version, "stringValue", "636.3");
    xpc_dictionary_set_value(msg, "CoreDevice.coreDeviceVersion", version);
    xpc_dictionary_set_int64(msg, "CoreDevice.CoreDeviceDDIProtocolVersion", 1);
    xpc_dictionary_set_string(msg, "CoreDevice.invocationIdentifier", inv_s);
    xpc_dictionary_set_value(msg, "CoreDevice.input", input);

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, msg);
    xpc_object_t output = reply ? xpc_dictionary_get_dictionary(reply, "CoreDevice.output") : NULL;
    if (!output) {
        xpc_object_t err = reply ? xpc_dictionary_get_dictionary(reply, "CoreDevice.error") : NULL;
        const char *domain = err ? xpc_dictionary_get_string(err, "domain") : NULL;
        int64_t code = err ? xpc_dictionary_get_int64(err, "code") : 0;
        *exit_code = (domain && strcmp(domain, "com.apple.dt.CoreDeviceError") == 0 && code == 4000) ? EXIT_TUNNEL_ : EXIT_SOCKET_;
        return NULL;
    }
    int fd = xpc_dictionary_dup_fd(output, "fileDescriptor");
    uint64_t vflags = xpc_dictionary_get_uint64(output, "remoteXPCVersionFlags");
    if (fd < 0) { *exit_code = EXIT_SOCKET_; return NULL; }
    dispatch_queue_t rq = dispatch_queue_create("fastinput-remote", DISPATCH_QUEUE_SERIAL);
    xpc_remote_connection_t remote = xpc_remote_connection_create_with_connected_fd(fd, rq, vflags, 0);
    if (!remote) { close(fd); *exit_code = EXIT_SOCKET_; return NULL; }
    xpc_remote_connection_set_event_handler(remote, ^(xpc_object_t e) {
        if (e && xpc_get_type(e) == XPC_TYPE_ERROR) atomic_store(lost, 1);
    });
    xpc_remote_connection_activate(remote);
    *fd_out = fd;
    return remote;
}

/* Runs the descriptor dump with stdout pointed at a temporary file and finds the service ids of
   the touchscreen and the keyboard ("CoreDevice keyboard"); 0 for one that was not found. */
static void discover_services(xpc_remote_connection_t remote, uint64_t *touch_id, uint64_t *keyboard_id) {
    *touch_id = 0;
    *keyboard_id = 0;
    setenv("HIDCTL_QUIET", "1", 1);
    FILE *tmp = tmpfile();
    if (!tmp) return;
    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    dup2(fileno(tmp), STDOUT_FILENO);
    int rc = coredevice_print_connected_descriptors_async_raw(remote);
    fflush(stdout);
    dup2(saved, STDOUT_FILENO);
    close(saved);
    if (rc == 0) {
        rewind(tmp);
        char *line = NULL;
        size_t cap = 0;
        while (getline(&line, &cap, tmp) > 0) {
            if (strncmp(line, "connectedDescriptor[", 20) != 0) continue;
            const char *p = strstr(line, "serviceID:");
            if (!p) continue;
            if (!*touch_id && strstr(line, "string:\"CoreDevice touchscreen(")) *touch_id = strtoull(p + 10, NULL, 0);
            else if (!*keyboard_id && strstr(line, "string:\"CoreDevice keyboard\"")) *keyboard_id = strtoull(p + 10, NULL, 0);
        }
        free(line);
    }
    fclose(tmp);
}

static int send_report(xpc_remote_connection_t remote, uint64_t sid, double x, double y, bool down) {
    uint64_t words[2] = {0, 0};
    int n = uhid_make_digitizer_hid_report(x, y, down ? 1 : 0, down ? 1 : 0, words);
    if (n != (int)sizeof(words)) return -1;
    return coredevice_send_universalhid_hid_report(remote, words, sid);
}

static int send_keyboard(xpc_remote_connection_t remote, uint64_t sid, uint32_t modifier, uint32_t usage, bool down) {
    uint64_t words[2] = {0, 0};
    int n = uhid_make_keyboard_chord_hid_report(modifier, usage, down ? 1 : 0, words);
    if (n != (int)sizeof(words)) return -1;
    return coredevice_send_universalhid_hid_report(remote, words, sid);
}

static int send_keyboard_set(xpc_remote_connection_t remote, uint64_t sid, const uint32_t *usages, int count) {
    uint64_t words[2] = {0, 0};
    int n = uhid_make_keyboard_set_hid_report(usages, count, words);
    if (n != (int)sizeof(words)) return -1;
    return coredevice_send_universalhid_hid_report(remote, words, sid);
}

static int keyboard_barrier(xpc_remote_connection_t remote) {
    return coredevice_send_universalhid_barrier ? coredevice_send_universalhid_barrier(remote) : 0;
}

/* US layout: the usage (and whether Shift is held) that types printable ASCII `c`. */
static bool ascii_usage(char c, uint32_t *usage, bool *shift) {
    static const char shifted_digits[] = ")!@#$%^&*(";
    *shift = false;
    if (c >= 'a' && c <= 'z') { *usage = 0x04 + (c - 'a'); return true; }
    if (c >= 'A' && c <= 'Z') { *usage = 0x04 + (c - 'A'); *shift = true; return true; }
    if (c >= '1' && c <= '9') { *usage = 0x1e + (c - '1'); return true; }
    if (c == '0') { *usage = 0x27; return true; }
    const char *sd = c ? strchr(shifted_digits, c) : NULL;
    if (sd) { int d = (int)(sd - shifted_digits); *usage = d == 0 ? 0x27 : 0x1e + (d - 1); *shift = true; return true; }
    static const struct { char plain, shifted; uint32_t usage; } punct[] = {
        {'-', '_', 0x2d}, {'=', '+', 0x2e}, {'[', '{', 0x2f}, {']', '}', 0x30}, {'\\', '|', 0x31},
        {';', ':', 0x33}, {'\'', '"', 0x34}, {'`', '~', 0x35}, {',', '<', 0x36}, {'.', '>', 0x37}, {'/', '?', 0x38},
    };
    if (c == ' ') { *usage = 0x2c; return true; }
    for (size_t i = 0; i < sizeof(punct) / sizeof(punct[0]); i++) {
        if (c == punct[i].plain) { *usage = punct[i].usage; return true; }
        if (c == punct[i].shifted) { *usage = punct[i].usage; *shift = true; return true; }
    }
    return false;
}

/* Types one character: Shift and the key in one report when it is shifted. */
static int type_char(xpc_remote_connection_t remote, uint64_t sid, uint32_t usage, bool shift) {
    int r = 0;
    if (shift) r = send_keyboard(remote, sid, 0xe1, 0, true);
    int r1 = send_keyboard(remote, sid, shift ? 0xe1 : 0, usage, true);
    usleep(12000);
    int r2 = send_keyboard(remote, sid, 0, 0, false);
    int r3 = keyboard_barrier(remote);
    usleep(8000);
    return r ? r : r1 ? r1 : r2 ? r2 : r3;
}

static void answer_send(int rc) {
    if (rc == 0) puts("ok");
    else printf("err 1 send failed (%d)\n", rc);
}

static int in_unit(double v) { return v >= 0.0 && v <= 1.0; }

int main(int argc, const char *argv[]) {
    setbuf(stdout, NULL);
    if (argc < 2 || argv[1][0] == '\0') fatal(EXIT_USAGE_, "no device identifier");
    if (!uhid_make_digitizer_hid_report || !coredevice_send_universalhid_hid_report
        || !coredevice_print_connected_descriptors_async_raw) fatal(EXIT_USAGE_, "input sender is not linked");
    const char *device = argv[1];
    uuid_t check;
    if (uuid_parse(device, check) != 0) fatal(EXIT_USAGE_, "invalid device identifier");

    @autoreleasepool {
        NSBundle *bundle = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"];
        if (!bundle) fatal(EXIT_USAGE_, "CoreDevice framework not found");
        _coredevice_xpc_add_bundle(bundle);
        _coredevice_xpc_init_services();

        dispatch_queue_t queue = dispatch_queue_create("fastinput", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t conn = xpc_connection_create("com.apple.CoreDevice.CoreDeviceService", queue);
        xpc_connection_set_event_handler(conn, ^(xpc_object_t e) { (void)e; });
        xpc_connection_resume(conn);

        int code = 0, touch_fd = -1, button_fd = -1, digitizer_fd = -1;
        xpc_remote_connection_t touch = open_remote(conn, device, kTouchFeature, &g_touch_lost, &code, &touch_fd);
        if (!touch) fatal(code, code == EXIT_TUNNEL_ ? "device tunnel is not connected" : "service socket refused");
        uint64_t sid = 0, kid = 0;
        discover_services(touch, &sid, &kid);
        if (sid == 0) fatal(EXIT_SOCKET_, "no touchscreen service found");
        /* The button socket is optional: a failure only makes `button` answer err 7. */
        xpc_remote_connection_t button = open_remote(conn, device, kButtonFeature, &g_button_lost, &code, &button_fd);
        /* Optional too: a failure only makes `edge` answer err 7. */
        xpc_remote_connection_t digitizer = open_remote(conn, device, kDigitizerFeature, &g_digitizer_lost, &code, &digitizer_fd);
        printf("ready 0x%llx\n", (unsigned long long)sid);

        char *line = NULL;
        size_t cap = 0;
        while (getline(&line, &cap, stdin) > 0) {
            size_t len = strlen(line);
            while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = 0;
            char verb[16] = {0}, arg[16] = {0};
            double x = 0, y = 0, hold = 0;
            if (strcmp(line, "ping") == 0) { puts("ok"); continue; }
            if (strcmp(line, "quit") == 0) { puts("ok"); break; }
            if (strncmp(line, "edge ", 5) == 0) {
                char phase[8] = {0};
                if (sscanf(line + 5, "%7s %lf %lf", phase, &x, &y) != 3 || !in_unit(x) || !in_unit(y)) { puts("err 2 bad command"); continue; }
                int ev = strcmp(phase, "down") == 0 ? 0 : strcmp(phase, "move") == 0 ? 1 : strcmp(phase, "up") == 0 ? 2 : -1;
                if (ev < 0) { puts("err 2 bad command"); continue; }
                if (!digitizer || !coredevice_send_hid_digitizer_cgpoint) { puts("err 7 digitizer connection unavailable"); continue; }
                if (atomic_load(&g_digitizer_lost)) { puts("err 6 connection lost"); continue; }
                /* ipb's bottom-edge call: one point, second point absent (tag 1), edge 3 = bottom, no barrier. */
                answer_send(coredevice_send_hid_digitizer_cgpoint(digitizer, x, y, 0, 0, 1, (uint64_t)ev, 3, 0, 0));
                continue;
            }
            if (strncmp(line, "hid ", 4) == 0) {
                unsigned page = 0, usage = 0;
                char edge[8] = {0};
                if (sscanf(line + 4, "%x %x %7s", &page, &usage, edge) != 3 || page == 0 || page > 0xffff
                    || usage == 0 || usage > 0xffff) { puts("err 2 bad command"); continue; }
                /* ipb's button click sends state 0 first (the press, held for its hold time) and 1 second
                   (the release), then a barrier (action_sender.m, send_coredevice_button_click); this sends
                   one of the two edges, each with its own barrier. */
                int state = strcmp(edge, "down") == 0 ? 0 : strcmp(edge, "up") == 0 ? 1 : -1;
                if (state < 0) { puts("err 2 bad command"); continue; }
                if (!button || !coredevice_send_hid_button_custom) { puts("err 7 button connection unavailable"); continue; }
                if (atomic_load(&g_button_lost)) { puts("err 6 connection lost"); continue; }
                int r1 = coredevice_send_hid_button_custom(button, page, usage, (uint8_t)state);
                int r2 = coredevice_send_hid_button_barrier ? coredevice_send_hid_button_barrier(button) : 0;
                answer_send(r1 ? r1 : r2);
                continue;
            }
            if (strncmp(line, "button ", 7) == 0 && sscanf(line + 7, "%15s", arg) == 1) {
                uint64_t usage;
                if (strcmp(arg, "home") == 0) usage = 0x40;
                else if (strcmp(arg, "volumeUp") == 0) usage = 0xE9;
                else if (strcmp(arg, "volumeDown") == 0) usage = 0xEA;
                else if (strcmp(arg, "appSwitcher") == 0) usage = 0x10;
                else { puts("err 2 unknown button"); continue; }
                /* The App Switcher is the AppleVendorKeyboard page's usage 0x10 (ipb, verified there
                   on a 12 mini, iOS 27.0); the others are Consumer page 0x0c. */
                uint64_t page = strcmp(arg, "appSwitcher") == 0 ? 0xff01 : 0x0c;
                if (!button || !coredevice_send_hid_button_custom) { puts("err 7 button connection unavailable"); continue; }
                if (atomic_load(&g_button_lost)) { puts("err 6 connection lost"); continue; }
                int r1 = coredevice_send_hid_button_custom(button, page, usage, 0);
                usleep(80000);
                int r2 = coredevice_send_hid_button_custom(button, page, usage, 1);
                int r3 = coredevice_send_hid_button_barrier ? coredevice_send_hid_button_barrier(button) : 0;
                answer_send(r1 ? r1 : r2 ? r2 : r3);
                continue;
            }
            if (strcmp(line, "keys") == 0 || strncmp(line, "keys ", 5) == 0) {
                if (!kid || !uhid_make_keyboard_set_hid_report) { puts("err 7 keyboard service unavailable"); continue; }
                if (atomic_load(&g_touch_lost)) { puts("err 6 connection lost"); continue; }
                uint32_t held[16];
                int count = 0;
                bool bad = false;
                const char *p = line + 4;
                while (*p && !bad) {
                    char *end = NULL;
                    unsigned long usage = strtoul(p, &end, 0);
                    if (end == p) { while (*p == ' ') p++; if (*p) bad = true; break; }
                    if (usage < 1 || usage > 0xe7 || count == 16) { bad = true; break; }
                    held[count++] = (uint32_t)usage;
                    p = end;
                }
                if (bad) { puts("err 2 bad command"); continue; }
                int r1 = send_keyboard_set(touch, kid, held, count);
                int r2 = keyboard_barrier(touch);
                answer_send(r1 ? r1 : r2);
                continue;
            }
            if (strncmp(line, "key ", 4) == 0 || strncmp(line, "text ", 5) == 0) {
                if (!kid || !uhid_make_keyboard_chord_hid_report) { puts("err 7 keyboard service unavailable"); continue; }
                if (atomic_load(&g_touch_lost)) { puts("err 6 connection lost"); continue; }
                if (line[0] == 'k') {
                    char *end = NULL, mode[8] = "tap";
                    unsigned long usage = strtoul(line + 4, &end, 0);
                    if (end == line + 4 || usage < 1 || usage > 0xe7 || (*end && sscanf(end, "%7s", mode) != 1)
                        || !(strcmp(mode, "tap") == 0 || strcmp(mode, "down") == 0 || strcmp(mode, "up") == 0)) {
                        puts("err 2 bad command"); continue;
                    }
                    int r1 = 0, r2 = 0;
                    if (strcmp(mode, "up") != 0) r1 = send_keyboard(touch, kid, 0, (uint32_t)usage, true);
                    if (strcmp(mode, "tap") == 0) usleep(20000);
                    if (strcmp(mode, "down") != 0) r2 = send_keyboard(touch, kid, 0, 0, false);
                    int r3 = keyboard_barrier(touch);
                    answer_send(r1 ? r1 : r2 ? r2 : r3);
                    continue;
                }
                const char *text = line + 5;
                if (*text == '\0') { puts("err 2 bad command"); continue; }
                bool ok = true;
                for (const char *c = text; *c; c++) {
                    uint32_t u; bool s;
                    if (!ascii_usage(*c, &u, &s)) { ok = false; break; }
                }
                if (!ok) { puts("err 8 unsupported character"); continue; }
                int rc = 0;
                for (const char *c = text; *c && !rc; c++) {
                    uint32_t u; bool s;
                    ascii_usage(*c, &u, &s);
                    rc = type_char(touch, kid, u, s);
                }
                answer_send(rc);
                continue;
            }
            int n = sscanf(line, "%15s %lf %lf %lf", verb, &x, &y, &hold);
            bool isTap = strcmp(verb, "tap") == 0;
            bool isDown = strcmp(verb, "down") == 0, isMove = strcmp(verb, "move") == 0, isUp = strcmp(verb, "up") == 0;
            if (!(isTap || isDown || isMove || isUp) || n < (isTap ? 4 : 3) || !in_unit(x) || !in_unit(y)
                || (isTap && (hold < 0 || hold > 5000))) { puts("err 2 bad command"); continue; }
            if (atomic_load(&g_touch_lost)) { puts("err 6 connection lost"); continue; }
            if (isTap) {
                int r1 = send_report(touch, sid, x, y, true);
                if (hold > 0) usleep((useconds_t)(hold * 1000));
                int r2 = send_report(touch, sid, x, y, false);
                int r3 = coredevice_send_universalhid_barrier ? coredevice_send_universalhid_barrier(touch) : 0;
                answer_send(r1 ? r1 : r2 ? r2 : r3);
            } else if (isUp) {
                int r1 = send_report(touch, sid, x, y, false);
                int r2 = coredevice_send_universalhid_barrier ? coredevice_send_universalhid_barrier(touch) : 0;
                answer_send(r1 ? r1 : r2);
            } else {
                answer_send(send_report(touch, sid, x, y, true));
            }
        }
        free(line);
        xpc_remote_connection_cancel(touch);
        close(touch_fd);
        if (button) { xpc_remote_connection_cancel(button); close(button_fd); }
        if (digitizer) { xpc_remote_connection_cancel(digitizer); close(digitizer_fd); }
        xpc_connection_cancel(conn);
    }
    return 0;
}
