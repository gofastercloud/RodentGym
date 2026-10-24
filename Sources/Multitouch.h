// Shared types for Apple's private MultitouchSupport framework, and access to the latest
// touch frame RodentGym has captured for each device slot.
//
// MIT License — see LICENSE.

#pragma once

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;
typedef struct {
    int frame; double timestamp; int identifier, state, fingerID, handID;
    MTReadout normalized; float size; int zero1;
    float angle, majorAxis, minorAxis;
    MTReadout mm; int zero2[2]; float unk2;
} MTFinger;

#define MAX_TOUCHES 16

/// Copies the most recent touches for a device slot into `out` (room for MAX_TOUCHES) and returns the count.
/// Normalised coordinates run 0–1, with y = 0 at the edge nearest the user.
int RGCopyTouches(int slot, MTFinger *out);
