// The Switch 2 Pro Controller as the MacNative runtime sees it: one optional Bluetooth LE pad next to the
// GameController, the generic HID pad and the DSU server. switch2_ble.m is the transport (switch2_proto.h the
// protocol); a build that does not compile that file leaves the symbols undefined, and gamepad.m's weak
// references simply find nothing (shared/runtime/gamepad.m).
#pragma once
#include <stdint.h>

typedef struct {
    int present;        // 1 while a Pro Controller 2 is connected and reporting
    uint64_t buttons;   // the runtime's physical button order (controller_map.h)
    int32_t lx, ly, rx, ry;   // -32767..32767, y up
} Switch2Pad;

// Starts scanning once (idempotent); 0 when Bluetooth is off for this build/app. Call from the main thread.
int switch2_start(void);

// Copies the pad state; 1 when a controller is present. May be missing from the link (weak import at the caller).
int switch2_pad_state(Switch2Pad *out);

// The game's rumble for one side (0 left, 1 right), amplitudes 0..1 and frequencies in Hz, as gamepad feedback
// receives them. May be missing from the link.
void switch2_rumble(int side, float amp_low, float freq_low, float amp_high, float freq_high);

// Called on the main thread whenever a report arrives or the controller goes away, so the runtime can read the pad
// again. The GameController and HID paths wake refresh_gamepads the same way. Pass NULL to stop. May be missing.
void switch2_set_input_hook(void (*hook)(void));

// 1 while the pad is present: the controller-type detection and the settings panel call this. May be missing.
int switch2_pad_present(void);
