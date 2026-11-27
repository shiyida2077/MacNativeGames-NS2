// The few names switch2_proto.h takes from nxnative's dm_input.h, so the protocol header stands alone here.
// The button bits keep nn::hid's order (the same the prototype used); this runtime maps them to its own physical
// controller bits in switch2_ble.m, where the pad state is made.
#pragma once
#include <stdint.h>

enum {
    DM_BTN_A = 1u << 0, DM_BTN_B = 1u << 1, DM_BTN_X = 1u << 2, DM_BTN_Y = 1u << 3,
    DM_BTN_LS = 1u << 4, DM_BTN_RS = 1u << 5, DM_BTN_L = 1u << 6, DM_BTN_R = 1u << 7,
    DM_BTN_ZL = 1u << 8, DM_BTN_ZR = 1u << 9, DM_BTN_PLUS = 1u << 10, DM_BTN_MINUS = 1u << 11,
    DM_BTN_LEFT = 1u << 12, DM_BTN_UP = 1u << 13, DM_BTN_RIGHT = 1u << 14, DM_BTN_DOWN = 1u << 15,
    DM_BTN_LSL = 1u << 24, DM_BTN_LSR = 1u << 25, DM_BTN_RSL = 1u << 26, DM_BTN_RSR = 1u << 27,
};
#define DM_STICK_MAX 32767
