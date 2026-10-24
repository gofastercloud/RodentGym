// Shared types for Apple's private MultitouchSupport framework, and access to the latest
// touch frame and frame statistics RodentGym has captured for each device slot.
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

/// MTFinger.state values. A finger normally goes make → touching → break before it disappears.
enum { RGTouchMake = 3, RGTouchTouching = 4, RGTouchBreak = 5 };

#define MAX_TOUCHES 16

/// Copies the most recent touches for a device slot into `out` (room for MAX_TOUCHES) and returns the count.
/// Normalised coordinates run 0–1, with y = 0 at the edge nearest the user.
int RGCopyTouches(int slot, MTFinger *out);

/// Running totals for one device slot, accumulated on the MultitouchSupport thread from every frame
/// the device sends. The counters only go up (they restart from zero when devices are rescanned), so
/// readers keep a copy and take differences.
typedef struct {
    long frames;          // frames carrying at least one contact
    long contactFrames;   // frames with a finger actually on the surface (not just hovering in range)
    long intervals;       // intervals measured between consecutive contact frames
    double sum, sumSq;    // of those intervals, in seconds
    long stalls;          // intervals well over the device's usual frame time
    long strokes;         // contacts that started
    long lost;            // contacts that vanished mid-surface without lifting off
    double typical;       // the device's usual frame interval, in seconds (0 until known)
} RGFrameStats;

/// Copies the running totals for a device slot.
void RGGetFrameStats(int slot, RGFrameStats *out);
