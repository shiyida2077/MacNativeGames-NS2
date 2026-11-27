// Switch 2 Pro Controller over Bluetooth LE, for the MacNative runtime.
//
// The controller does not speak HID over GATT: it uses Nintendo's own service and only starts reporting after the
// handshake in switch2_proto.h. This file is the CoreBluetooth transport (the protocol itself is switch2_proto.h,
// taken from the nxnative prototype, MIT): scan, bond, handshake, input reports, HD rumble and the player LED.
//
// Everything runs on the main queue; the game thread only reads the pad state and hands over rumble values, both
// under one lock. The runtime is off unless the app's Info.plist has NSBluetoothAlwaysUsageDescription; MN_SW2=0
// turns it off even then, MN_SW2_VERBOSE=1 logs every step, MN_SW2_HOST=aa:bb:cc:dd:ee:ff skips reading this Mac's
// own Bluetooth address (the address a bonded controller wakes toward).
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <IOBluetooth/IOBluetooth.h>
#endif
#include "switch2_ble.h"
#include "switch2_proto.h"
#include <math.h>
#include <os/lock.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t sw2_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// Kept while this runtime is new: an app started from Finder has no stderr to look at. MN_SW2_LOG picks another
// path. This is a development aid, not part of the upstream shape of the file.
static FILE *g_log;
static void s2log(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    va_list aq; va_copy(aq, ap);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (!g_log) {
        const char *p = getenv("MN_SW2_LOG");
        g_log = fopen(p ? p : "/tmp/macnative-switch2.log", "a");
        if (g_log) setvbuf(g_log, NULL, _IOLBF, 0);
    }
    if (g_log) vfprintf(g_log, fmt, aq);
    va_end(aq);
}

@class S2Session;

static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static Switch2Pad g_pad;                 // what the game reads
static s2_cal g_cal[2];                  // left stick, right stick
static s2_haptic g_hap[2];               // left, right, as the game sets them
static uint64_t g_hap_at[2];

static CBCentralManager *g_central;
static id g_delegate;                    // S2Central
static S2Session *g_session;
static uint8_t g_host[6];                // this Mac's Bluetooth address, little endian
static int g_host_known, g_started, g_verbose, g_failed, g_stats;
static uint64_t g_reports, g_packets;   // for MN_SW2_STATS=1
static void (*g_input_hook)(void);      // the runtime's "read the pad again" callback (gamepad.m)

// The six-axis fusion lives in motion_fusion.c; gamepad_feedback.m feeds it for GameController pads, so this transport
// feeds it directly. All four are optional: a build without motion_fusion keeps working.
extern void runtime_motion_feed(const double raw_acc[3], const double raw_gyro[3], uint64_t now) __attribute__((weak_import));
extern void runtime_motion_live(int on) __attribute__((weak_import));
extern void runtime_motion_deadzone_default(double deg) __attribute__((weak_import));
extern int runtime_dsu_motion_active(void) __attribute__((weak_import));


// The runtime's physical button order (controller_map.h): south, east, west, north, L3, R3, L1, R1, L2, R2, menu,
// view, left, up, right, down, touchpad. A, B, X, Y are placed by position: the Switch's south is B, east is A.
static uint64_t sw2_physical(uint32_t b) {
    uint64_t m = 0;
    if (b & S2_B) m |= 1ull << 0;
    if (b & S2_A) m |= 1ull << 1;
    if (b & S2_Y) m |= 1ull << 2;
    if (b & S2_X) m |= 1ull << 3;
    if (b & S2_LSTICK) m |= 1ull << 4;
    if (b & S2_RSTICK) m |= 1ull << 5;
    if (b & S2_L) m |= 1ull << 6;
    if (b & S2_R) m |= 1ull << 7;
    if (b & S2_ZL) m |= 1ull << 8;
    if (b & S2_ZR) m |= 1ull << 9;
    if (b & S2_PLUS) m |= 1ull << 10;
    if (b & S2_MINUS) m |= 1ull << 11;
    if (b & S2_LEFT) m |= 1ull << 12;
    if (b & S2_UP) m |= 1ull << 13;
    if (b & S2_RIGHT) m |= 1ull << 14;
    if (b & S2_DOWN) m |= 1ull << 15;
    return m;   // Home, Capture, C and the rear buttons have no place in this layout
}

static int32_t sw2_axis(float v) {
    float x = v * (float)DM_STICK_MAX;
    if (x > DM_STICK_MAX) x = DM_STICK_MAX;
    if (x < -DM_STICK_MAX) x = -DM_STICK_MAX;
    return (int32_t)lrintf(x);
}

@interface S2Command : NSObject
@property (nonatomic) uint8_t cmd, sub;
@property (nonatomic, copy) NSData *payload;
@property (nonatomic, copy) void (^done)(NSData *);
@end
@implementation S2Command
@end

@interface S2Session : NSObject <CBPeripheralDelegate> {
    CBCharacteristic *_wr, *_rsp, *_inp, *_vib;
    NSMutableArray<S2Command *> *_queue;
    BOOL _pending, _live, _handshaken, _dead;
    uint8_t _pendingCmd, _vseq, _offLeft;
    NSUInteger _seq;
    void (^_cb)(NSData *);
    NSTimer *_led, *_statsTimer;
    s2_cal _cal[2];
    s2_rest _rest;   // gyro offset learned while the controller lies still
    char _serial[15];
}
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, copy) void (^onClosed)(void);
@property (nonatomic) BOOL pairing;   // the advertisement named no host: bond while connected
@property (nonatomic) uint8_t offLeft;   // silent packets still to send after the last buzz
@property (nonatomic, readonly) BOOL live;
- (instancetype)initWith:(CBPeripheral *)p;
- (void)begin;
- (void)writeRumble:(const uint8_t *)packet length:(size_t)n;
@end

@interface S2Central : NSObject <CBCentralManagerDelegate>
@end

static NSTimer *g_rumble_timer;
static uint8_t g_rseq;

static void sw2_rumble_tick(NSTimer *t);
static void sw2_rumble_timer_update(void);

@implementation S2Session
- (BOOL)live { return _live; }
- (instancetype)initWith:(CBPeripheral *)p {
    if ((self = [super init])) {
        _peripheral = p; p.delegate = self; _queue = [NSMutableArray new];
        for (int i = 0; i < 2; i++) s2_cal_default(&_cal[i]);
    }
    return self;
}
- (void)begin {
    [_peripheral discoverServices:nil];
    __weak S2Session *w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        S2Session *s = w; if (s && !s->_handshaken) [s fail:@"the handshake timed out"];
    });
}
- (void)log:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    char buf[1024];
    vsnprintf(buf, sizeof buf, fmt.UTF8String, ap);
    va_end(ap);
    s2log("[sw2] Pro Controller 2: %s\n", buf);
}
- (void)fail:(NSString *)why {
    if (_dead) return;
    _dead = YES;
    [self log:@"%@", why];
    [g_central cancelPeripheralConnection:_peripheral];
    if (!_live) [self closed];
}
- (void)closed {   // idempotent: the connection's delegate and a failed handshake both end here
    if (_live) [self log:@"disconnected"];
    _live = _handshaken = NO;
    [_led invalidate]; _led = nil;
    [_statsTimer invalidate]; _statsTimer = nil;
    if (_peripheral.state == CBPeripheralStateConnected) [_peripheral setNotifyValue:NO forCharacteristic:_inp];
    os_unfair_lock_lock(&g_lock);
    memset(&g_pad, 0, sizeof g_pad);
    os_unfair_lock_unlock(&g_lock);
    if (self.onClosed) self.onClosed();
    if (runtime_motion_live && !(runtime_dsu_motion_active && runtime_dsu_motion_active())) runtime_motion_live(0);
    if (g_input_hook) g_input_hook();
    sw2_rumble_timer_update();
}
- (void)send:(uint8_t)cmd sub:(uint8_t)sub payload:(const uint8_t *)pl len:(size_t)n done:(void (^)(NSData *))done {
    S2Command *c = [S2Command new];
    c.cmd = cmd; c.sub = sub; c.payload = [NSData dataWithBytes:pl length:n]; c.done = done;
    [_queue addObject:c];
    [self pump];
}
- (void)pump {
    if (_pending || !_queue.count || !_wr) return;
    S2Command *c = _queue.firstObject; [_queue removeObjectAtIndex:0];
    uint8_t f[8 + 255];
    size_t n = s2_command(f, sizeof f, c.cmd, c.sub, c.payload.bytes, c.payload.length);
    if (!n) { if (c.done) c.done(nil); [self pump]; return; }
    _pending = YES; _pendingCmd = c.cmd; _cb = c.done;
    NSUInteger mine = ++_seq; uint8_t id = c.cmd;
    __weak S2Session *w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        S2Session *s = w;
        if (!s || !s->_pending || s->_seq != mine) return;
        s->_pending = NO; void (^d)(NSData *) = s->_cb; s->_cb = nil;
        if (g_verbose) [s log:@"command 0x%02x timed out", id];
        if (d) d(nil);
        [s pump];
    });
    [_peripheral writeValue:[NSData dataWithBytes:f length:n] forCharacteristic:_wr type:CBCharacteristicWriteWithoutResponse];
}
- (void)readMemory:(uint8_t)len at:(uint32_t)addr done:(void (^)(NSData *))done {
    uint8_t p[8]; s2_memory_payload(p, len, addr);
    [self send:S2_CMD_MEMORY sub:S2_SUB_MEMORY_READ payload:p len:8 done:^(NSData *r) {
        done(r.length >= S2_REPLY_DATA + len && ((const uint8_t *)r.bytes)[8] == len ? [r subdataWithRange:NSMakeRange(S2_REPLY_DATA, len)] : nil);
    }];
}
- (void)readCal:(int)slot done:(void (^)(void))done {
    __weak S2Session *w = self;
    uint32_t user = slot ? S2_ADDR_USER_STICK2 : S2_ADDR_USER_STICK1;
    uint32_t factory = slot ? S2_ADDR_STICK2 : S2_ADDR_STICK1;
    [self readMemory:S2_STICK_BLOCK at:factory done:^(NSData *f) {
        S2Session *s = w; if (!s) return;
        [s readMemory:0x0B at:user done:^(NSData *u) {
            S2Session *x = w; if (!x) return;
            int from = s2_cal_from_flash(f.bytes, f.length, u.bytes, u.length, &x->_cal[slot]);
            if (g_verbose) [x log:@"stick %d calibration from the %s (dead zone %.0f%%)", slot,
                           from == 2 ? "user's" : from ? "factory's" : "typical values", s2_cal_dead_share(&x->_cal[slot]) * 100];
            done();
        }];
    }];
}
- (void)setLEDs {
    if (!_wr) return;
    uint8_t l[4] = {s2_led_pattern[0], 0, 0, 0};   // this runtime has one player: light 1
    uint8_t f[12];
    size_t n = s2_command(f, sizeof f, S2_CMD_LEDS, S2_SUB_LEDS_SET, l, 4);
    if (n) [_peripheral writeValue:[NSData dataWithBytes:f length:n] forCharacteristic:_wr type:CBCharacteristicWriteWithoutResponse];
}
- (void)handshake {
    __weak S2Session *w = self;
    [self readMemory:0x40 at:S2_ADDR_INFO done:^(NSData *info) {
        S2Session *s = w; if (!s) return;
        uint16_t vid = 0, pid = 0; char serial[15] = {0};
        if (!info || !s2_info_parse(info.bytes, info.length, &vid, &pid, serial) || vid != S2_VENDOR_ID || pid != S2_PID_PRO) {
            [s fail:@"not a Switch 2 Pro Controller (the identity read did not answer)"]; return;
        }
        memcpy(s->_serial, serial, sizeof s->_serial);
        void (^calibrate)(void) = ^{
            S2Session *a = w; if (!a) return;
            [a readCal:0 done:^{
                S2Session *b = w; if (!b) return;
                [b readCal:1 done:^{ S2Session *c = w; if (c) [c finish]; }];
            }];
        };
        if (s->_pairing) [s bond:calibrate]; else calibrate();
    }];
}
- (void)bond:(void (^)(void))done {
    if (!g_host_known) { [self log:@"this Mac's Bluetooth address is unknown: the controller is used without pairing (press Sync next time)"]; done(); return; }
    __weak S2Session *w = self;
    uint8_t host[S2_PAIR_HOST_LEN], k1[16], k2[16], key1[S2_PAIR_KEY_LEN], key2[S2_PAIR_KEY_LEN], last = 0;
    arc4random_buf(k1, sizeof k1); arc4random_buf(k2, sizeof k2);
    s2_pair_host_payload(host, g_host); s2_pair_key_payload(key1, k1); s2_pair_key_payload(key2, k2);
    NSData *h = [NSData dataWithBytes:host length:sizeof host], *a = [NSData dataWithBytes:key1 length:sizeof key1];
    NSData *b = [NSData dataWithBytes:key2 length:sizeof key2], *z = [NSData dataWithBytes:&last length:1];
    void (^step)(NSData *, const char *, void (^)(void)) = ^(NSData *r, const char *what, void (^next)(void)) {
        S2Session *s = w; if (!s) return;
        if (!r) { [s log:@"pairing stopped at %s (no answer); it plays now but needs Sync again next time", what]; done(); return; }
        if (g_verbose) [s log:@"paired: %s written", what];
        next();
    };
    [self send:S2_CMD_PAIR sub:S2_SUB_PAIR_HOST payload:h.bytes len:h.length done:^(NSData *r1) { step(r1, "the host address", ^{
        S2Session *s = w; if (!s) return;
        [s send:S2_CMD_PAIR sub:S2_SUB_PAIR_KEY1 payload:a.bytes len:a.length done:^(NSData *r2) { step(r2, "the first key", ^{
            S2Session *t = w; if (!t) return;
            [t send:S2_CMD_PAIR sub:S2_SUB_PAIR_KEY2 payload:b.bytes len:b.length done:^(NSData *r3) { step(r3, "the second key", ^{
                S2Session *u = w; if (!u) return;
                [u send:S2_CMD_PAIR sub:S2_SUB_PAIR_DONE payload:z.bytes len:z.length done:^(NSData *r4) { step(r4, "the last step", ^{
                    S2Session *v = w; if (!v) return;
                    [v log:@"paired with this Mac: a button press connects it from now on, no Sync needed"];
                    done();
                }); }];
            }); }];
        }); }];
    }); }];
}
- (void)finish {
    __weak S2Session *w = self;
    uint8_t feat[4] = {S2_FEATURES, 0, 0, 0};
    [self send:S2_CMD_FEATURE sub:S2_SUB_FEATURE_SET payload:feat len:4 done:^(NSData *r1) {
        (void)r1; S2Session *s = w; if (!s) return;
        uint8_t on[4] = {S2_FEATURES, 0, 0, 0};
        [s send:S2_CMD_FEATURE sub:S2_SUB_FEATURE_ENABLE payload:on len:4 done:^(NSData *r2) {
            S2Session *t = w; if (!t) return;
            if (!r2) { [t fail:@"enabling the controller's features was refused"]; return; }
            [t attach];
        }];
    }];
}
- (void)attach {
    os_unfair_lock_lock(&g_lock);
    g_cal[0] = _cal[0]; g_cal[1] = _cal[1];
    memset(&g_pad, 0, sizeof g_pad); g_pad.present = 1;
    os_unfair_lock_unlock(&g_lock);
    _live = YES; _handshaken = YES;
    [self log:@"connected: buttons and sticks reach the game, rumble goes back"];
    if (runtime_motion_deadzone_default) runtime_motion_deadzone_default(0);
    if (runtime_motion_live) runtime_motion_live(1);
    if (g_input_hook) g_input_hook();
    if (g_verbose) [self log:@"serial %s", _serial];
    if (g_verbose) [self log:@"characteristics: write %d reply %d input %d rumble %d", _wr != nil, _rsp != nil, _inp != nil, _vib != nil];
    [self setLEDs];
    [_peripheral setNotifyValue:YES forCharacteristic:_inp];
    __weak S2Session *w = self;
    _led = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        S2Session *s = w; if (!s || !s->_live) { [t invalidate]; return; }
        [s setLEDs];   // the link drops after about ten seconds without a write
    }];
    if (g_stats) {
        __weak S2Session *ws = self;
        _statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            S2Session *q = ws; if (!q || !q->_live) { [t invalidate]; return; }
            Switch2Pad p; switch2_pad_state(&p);
            s2log("[sw2] stats: present=%d buttons=0x%llx lx=%d ly=%d rx=%d ry=%d reports=%llu rumble_packets=%llu\n",
                    p.present, (unsigned long long)p.buttons, p.lx, p.ly, p.rx, p.ry,
                    (unsigned long long)g_reports, (unsigned long long)g_packets);
        }];
    }
    sw2_rumble_timer_update();
}
- (void)writeRumble:(const uint8_t *)packet length:(size_t)n {
    if (!_live || !_vib) return;
    if (!_peripheral.canSendWriteWithoutResponse) { static int skipped; if (g_verbose && skipped++ < 3) [self log:@"rumble: Bluetooth queue full, packet skipped"]; return; }
    static int sent; if (g_verbose && sent++ < 3) [self log:@"rumble: packet sent (%zu bytes)", n];
    [_peripheral writeValue:[NSData dataWithBytes:packet length:n] forCharacteristic:_vib type:CBCharacteristicWriteWithoutResponse];
}
- (void)report:(NSData *)d {
    s2_report r;
    if (!s2_report_parse(d.bytes, d.length, &r)) return;
    float lx, ly, rx, ry;
    s2_cal_apply(&g_cal[0], r.lx, r.ly, &lx, &ly);
    s2_cal_apply(&g_cal[1], r.rx, r.ry, &rx, &ry);
    uint64_t buttons = sw2_physical(r.buttons);
    g_reports++;
    if ((g_reports % 240) == 0) s2log("[sw2] reports %llu, buttons %#llx, sticks %d,%d,%d,%d\n",
                                      (unsigned long long)g_reports, (unsigned long long)buttons,
                                      g_pad.lx, g_pad.ly, g_pad.rx, g_pad.ry);
    os_unfair_lock_lock(&g_lock);
    g_pad.present = 1;
    g_pad.buttons = buttons;
    g_pad.lx = sw2_axis(lx); g_pad.ly = sw2_axis(ly);
    g_pad.rx = sw2_axis(rx); g_pad.ry = sw2_axis(ry);
    os_unfair_lock_unlock(&g_lock);
    if (g_input_hook) g_input_hook();   // main thread: let the runtime merge this report into the game's pad state
    // The game's six-axis fusion takes the same samples GameController's GCMotion would have delivered.
    s2_rest_update(&_rest, r.raw);
    if (runtime_motion_feed && !(runtime_dsu_motion_active && runtime_dsu_motion_active())) {
        float a[3], w[3];
        s2_motion(r.raw, s2_map_pro, _rest.have ? _rest.bias : NULL, S2_GYRO_RAD, a, w);
        const double da[3] = {a[0], a[1], a[2]}, dw[3] = {w[0], w[1], w[2]};
        runtime_motion_feed(da, dw, sw2_now_ns());
    }
}
// ---- CBPeripheralDelegate ----
- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(NSError *)e {
    if (e) { [self fail:[NSString stringWithFormat:@"service discovery: %@", e.localizedDescription]]; return; }
    for (CBService *s in p.services) [p discoverCharacteristics:nil forService:s];
}
- (void)peripheral:(CBPeripheral *)p didDiscoverCharacteristicsForService:(CBService *)s error:(NSError *)e {
    if (e) { [self fail:[NSString stringWithFormat:@"characteristic discovery: %@", e.localizedDescription]]; return; }
    CBUUID *wr = [CBUUID UUIDWithString:@S2_UUID_CMD_WR], *rs = [CBUUID UUIDWithString:@S2_UUID_CMD_RSP];
    CBUUID *in = [CBUUID UUIDWithString:@S2_UUID_INPUT], *vp = [CBUUID UUIDWithString:@S2_UUID_VIB_PRO];
    for (CBCharacteristic *c in s.characteristics) {
        if ([c.UUID isEqual:wr]) _wr = c;
        else if ([c.UUID isEqual:rs]) _rsp = c;
        else if ([c.UUID isEqual:in]) _inp = c;
        else if ([c.UUID isEqual:vp]) _vib = c;
    }
    if (_wr && _rsp && _inp && !_handshaken && !_live) [p setNotifyValue:YES forCharacteristic:_rsp];
}
- (void)peripheral:(CBPeripheral *)p didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)c error:(NSError *)e {
    (void)p;
    if (e) { [self fail:[NSString stringWithFormat:@"notifications: %@", e.localizedDescription]]; return; }
    if (c == _rsp && !_live) [self handshake];
}
- (void)peripheral:(CBPeripheral *)p didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)e {
    (void)p;
    if (e || !c.value.length) return;
    if (c == _inp) { [self report:c.value]; return; }
    if (c == _rsp && _pending && s2_reply_is(c.value.bytes, c.value.length, _pendingCmd)) {
        _pending = NO; void (^d)(NSData *) = _cb; _cb = nil;
        if (d) d(c.value);
        [self pump];
    }
}
- (void)peripheral:(CBPeripheral *)p didModifyServices:(NSArray<CBService *> *)invalidated {
    (void)p; (void)invalidated;
    [self fail:@"the controller reset the link"];
}
@end

@implementation S2Central {
    NSMutableDictionary<NSUUID *, NSDate *> *_tried;
}
- (void)scan:(CBCentralManager *)c {
    [c scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @YES}];
    s2log("[sw2] Pro Controller 2: press a button on a paired one; to pair it, hold Sync until the player lights sweep\n");
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)c {
    if (c.state == CBManagerStatePoweredOn) {
#if TARGET_OS_OSX
        static BOOL asked;
        if (!g_host_known && !asked) {
            asked = YES;
            __weak CBCentralManager *wc = c;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                const char *addr = IOBluetoothHostController.defaultController.addressAsString.UTF8String;
                unsigned a[6]; BOOL ok = addr && sscanf(addr, "%x%*c%x%*c%x%*c%x%*c%x%*c%x", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5]) == 6 && (a[0] | a[1] | a[2] | a[3] | a[4] | a[5]);
                uint64_t packed = 0; for (int i = 0; i < 6; i++) packed |= (uint64_t)(ok ? (uint8_t)a[5 - i] : 0) << (8 * i);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) { for (int i = 0; i < 6; i++) g_host[i] = (uint8_t)(packed >> (8 * i)); g_host_known = 1; }
                    else s2log("[sw2] this Mac's Bluetooth address could not be read: controllers play without pairing\n");
                    CBCentralManager *cm = wc; if (cm && cm.state == CBManagerStatePoweredOn) [self scan:cm];
                });
            });
            return;
        }
#endif
        [self scan:c];
    } else if (c.state == CBManagerStateUnauthorized) {
        s2log("[sw2] Bluetooth is not allowed for this app (System Settings > Privacy & Security > Bluetooth)\n");
    } else if (c.state == CBManagerStatePoweredOff) {
        s2log("[sw2] Bluetooth is off\n");
    } else if (c.state == CBManagerStateUnsupported) {
        s2log("[sw2] Bluetooth LE is not available on this Mac\n");
    }
}
- (void)centralManager:(CBCentralManager *)c didDiscoverPeripheral:(CBPeripheral *)p advertisementData:(NSDictionary<NSString *, id> *)ad RSSI:(NSNumber *)rssi {
    (void)rssi;
    if (g_session) return;
    NSData *d = ad[CBAdvertisementDataManufacturerDataKey];
    if (d.length < 18 || s2_u16(d.bytes) != S2_COMPANY_ID) return;
    s2_advert a; if (!s2_advert_parse((const uint8_t *)d.bytes + 2, d.length - 2, &a)) return;
    if (a.pid != S2_PID_PRO) return;   // this port drives the Pro Controller; Joy-Con 2s are left to a later step
    int use = s2_advert_use(&a, g_host_known ? g_host : NULL);
    if (use == S2_ADV_IGNORE) return;
    if (!_tried) _tried = [NSMutableDictionary new];
    if (_tried[p.identifier] && -[_tried[p.identifier] timeIntervalSinceNow] < 3) return;
    _tried[p.identifier] = [NSDate date];
    S2Session *s = [[S2Session alloc] initWith:p];
    s.pairing = use == S2_ADV_PAIR || use == S2_ADV_TAKE;
    s.onClosed = ^{ g_session = nil; };
    g_session = s;
    s2log("[sw2] Pro Controller 2 %s, connecting\n", s.pairing ? "pairing" : "woke");
    [c connectPeripheral:p options:nil];
    NSUUID *id = p.identifier;
    __weak CBCentralManager *wc = c;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        S2Session *t = g_session;
        if (t && [t.peripheral.identifier isEqual:id] && t.peripheral.state != CBPeripheralStateConnected) {
            s2log("[sw2] connecting timed out\n");
            [wc cancelPeripheralConnection:t.peripheral];
            g_session = nil;
        }
    });
}
- (void)centralManager:(CBCentralManager *)c didConnectPeripheral:(CBPeripheral *)p {
    (void)c;
    if (g_session && [g_session.peripheral isEqual:p]) [g_session begin];
}
- (void)centralManager:(CBCentralManager *)c didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    (void)c;
    s2log("[sw2] connect failed: %s\n", e.localizedDescription.UTF8String ?: "unknown");
    if (g_session && [g_session.peripheral isEqual:p]) g_session = nil;
}
- (void)centralManager:(CBCentralManager *)c didDisconnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    (void)c;
    if (!g_session || ![g_session.peripheral isEqual:p]) return;
    [g_session closed];
    g_session = nil;
}
@end

// Rumble: the game sets values at gamepad feedback's 10 ms tick; the controller plays packets of three 5 ms samples.
// A value is held until it changes or the game goes quiet (250 ms), then three silent packets end the buzz reliably.
static void sw2_rumble_tick(NSTimer *t) {
    (void)t;
    if (!g_session || !g_session.live) return;
    s2_haptic m[2] = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    uint64_t now = sw2_now_ns();
    int on = 0;
    os_unfair_lock_lock(&g_lock);
    for (int i = 0; i < 2; i++) if (g_hap_at[i] && now - g_hap_at[i] < 250000000ull) { m[i] = g_hap[i]; on |= s2_haptic_on(&m[i]); }
    os_unfair_lock_unlock(&g_lock);
    if (!on && g_session.offLeft == 0) return;
    if (on) g_session.offLeft = 3; else g_session.offLeft--;
    for (int i = 0; i < 2; i++) {
        float lo = m[i].lf_amp / 1023.f, hi = m[i].hf_amp / 1023.f;
        s2_rumble_cap(&lo, &hi);
        m[i].lf_amp = s2_amp_code(lo); m[i].hf_amp = s2_amp_code(hi);
    }
    s2_haptic a[3] = {m[0], m[0], m[0]}, b[3] = {m[1], m[1], m[1]};
    uint8_t pk[33];
    size_t n = s2_rumble_packet3(pk, a, b, g_rseq++);
    g_packets++;
    if ((g_packets % 240) == 0) s2log("[sw2] rumble packets %llu\n", (unsigned long long)g_packets);
    [g_session writeRumble:pk length:n];
}
static void sw2_rumble_timer_update(void) {
    if (g_session && g_session.live) {
        if (!g_rumble_timer) {
            g_rumble_timer = [NSTimer scheduledTimerWithTimeInterval:0.015 repeats:YES block:^(NSTimer *t) { sw2_rumble_tick(t); }];
        }
    } else if (g_rumble_timer) {
        [g_rumble_timer invalidate]; g_rumble_timer = nil;
    }
}

int switch2_start(void) {
    if (g_started) return !g_failed;
    g_started = 1;
    const char *e = getenv("MN_SW2");
    if (e && !atoi(e)) { s2log("[sw2] MN_SW2=0: Switch 2 support disabled\n"); return 0; }
    BOOL key = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSBluetoothAlwaysUsageDescription"] != nil;
    s2log("[sw2] start: bundle %s, plist key %s\n",
          NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "(none)", key ? "present" : "missing");
    if (!key && !getenv("MN_SW2_FORCE")) {
        s2log("[sw2] Switch 2 controllers are off: the app's Info.plist has no NSBluetoothAlwaysUsageDescription\n");
        g_failed = 1; return 0;
    }
    g_verbose = getenv("MN_SW2_VERBOSE") != NULL;
    g_stats = getenv("MN_SW2_STATS") != NULL;
    unsigned v[6]; char sep; e = getenv("MN_SW2_HOST");
    if (e && sscanf(e, "%x%c%x%c%x%c%x%c%x%c%x", &v[0], &sep, &v[1], &sep, &v[2], &sep, &v[3], &sep, &v[4], &sep, &v[5]) == 11) {
        for (int i = 0; i < 6; i++) g_host[i] = (uint8_t)v[5 - i];
        g_host_known = 1;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        g_delegate = [S2Central new];
        g_central = [[CBCentralManager alloc] initWithDelegate:g_delegate queue:dispatch_get_main_queue() options:nil];
    });
    return 1;
}

int switch2_pad_state(Switch2Pad *out) {
    if (!out) return 0;
    os_unfair_lock_lock(&g_lock);
    *out = g_pad;
    os_unfair_lock_unlock(&g_lock);
    return out->present;
}

void switch2_set_input_hook(void (*hook)(void)) { g_input_hook = hook; }

int switch2_pad_present(void) {
    os_unfair_lock_lock(&g_lock);
    int present = g_pad.present;
    os_unfair_lock_unlock(&g_lock);
    return present;
}

void switch2_rumble(int side, float amp_low, float freq_low, float amp_high, float freq_high) {
    if (side < 0 || side > 1) return;
    if (amp_low > 0.02f || amp_high > 0.02f) {
        static int calls;
        if (calls++ < 8 || (calls % 120) == 0)
            s2log("[sw2] rumble call %d: side %d, amps %.2f/%.2f, freqs %.0f/%.0f\n",
                  calls, side, amp_low, amp_high, freq_low, freq_high);
    }
    os_unfair_lock_lock(&g_lock);
    g_hap[side] = s2_haptic_from(amp_low, freq_low, amp_high, freq_high);
    g_hap_at[side] = sw2_now_ns();
    os_unfair_lock_unlock(&g_lock);
}
