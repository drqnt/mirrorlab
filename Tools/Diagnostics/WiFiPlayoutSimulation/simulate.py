#!/usr/bin/env python3
"""Offline comparison of the AirPlay video playout schedulers (0.3.48 vs 0.3.49).

Synthetic, not a device measurement. The trace model is a 60 fps TCP mirror stream
over Wi-Fi: small exponential jitter, short stalls (frames sent during the stall are
released together, head-of-line) and rare long stalls. The 0.3.49 classes are a
line-by-line port of AirPlayPlayoutClock / AirPlayPresentationStore; keep them in sync
when tuning the Swift constants.

    python3 simulate.py            # 60 Hz and 120 Hz tables
"""
import bisect
import math
import random
import statistics

FPS = 60.0
PROFILES = {
    #        short-stall every s, short-stall ms, long stall every s
    "clean": (5.0, (10, 25), 1e9),
    "home": (1.1, (30, 90), 12.0),
    "busy": (0.6, (40, 140), 6.0),
}


def make_trace(seed, duration, profile):
    """[(source_pts_seconds, decoded_host_time)] for one mirror session."""
    rng = random.Random(seed)
    every, stall_ms, long_every = PROFILES[profile]
    clock_offset, drift = 1234.5, 30e-6
    stalls, t = [], 0.0
    while t < duration:
        t += rng.expovariate(1.0 / every)
        stalls.append((t, rng.uniform(*stall_ms) / 1000.0))
    t = 0.0
    while t < duration:
        t += rng.expovariate(1.0 / long_every)
        stalls.append((t, rng.uniform(0.18, 0.45)))
    stalls.sort()
    out, last_arrival, last_decode = [], -1e9, -1e9
    for i in range(int(duration * FPS)):
        pts = i / FPS
        size_delay = 0.035 if i == 0 else rng.expovariate(1 / 0.002)  # first IDR is big
        arrival = pts + 0.004 + 0.008 + size_delay + rng.expovariate(1 / 0.003)
        for start, length in stalls:
            if start <= arrival <= start + length:
                arrival = start + length + rng.uniform(0, 0.002)
                break
        arrival = max(arrival, last_arrival + 0.0003)  # TCP is in order
        last_arrival = arrival
        decoded = max(arrival + 0.004 + rng.uniform(0, 0.002), last_decode + 0.0002)
        last_decode = decoded
        out.append((pts, decoded + clock_offset + pts * drift))
    return out, clock_offset


class Store0348:
    """AirPlayPresentationStore from 0.3.48 (one-frame anchor + 40 ms, 180 ms reset)."""
    target, max_queue, catch_up, reset = 0.040, 10, 0.020, 0.180

    def __init__(self):
        self.q, self.source_anchor, self.host_anchor = [], None, None

    def sched(self, pts):
        return self.host_anchor + (pts - self.source_anchor)

    def enqueue(self, pts, arrival):
        if self.source_anchor is None:
            self.source_anchor, self.host_anchor = pts, arrival + self.target
        elif abs(arrival - self.sched(pts)) > self.reset:
            self.source_anchor, self.host_anchor = pts, arrival + self.target
            self.q = []
        bisect.insort(self.q, pts)
        if len(self.q) > self.max_queue:
            del self.q[:len(self.q) - self.max_queue]

    def select(self, t):
        if self.source_anchor is None:
            return None
        while len(self.q) > 1 and self.sched(self.q[0]) < t - self.catch_up and self.sched(self.q[1]) <= t + 0.0015:
            self.q.pop(0)
        if self.q and self.sched(self.q[0]) <= t + 0.0015:
            return self.q.pop(0)
        return None


MODES = {  # minimumDelay, maximumDelay, coveredFraction, peakHold
    "lowLatency": (0.025, 0.060, 0.90, 6.0),
    "balanced": (0.040, 0.120, 0.98, 10.0),
    "smooth": (0.070, 0.250, 0.995, 15.0),
}


class PlayoutClock0349:
    window, min_samples, max_samples, margin = 3.0, 30, 720, 0.004
    grow_deadband, shrink_deadband, shrink_per_frame = 0.004, 0.008, 0.0005
    snap, discontinuity = 0.150, 10.0

    def __init__(self, mode):
        self.mode = mode
        lo, hi, _, _ = MODES[mode]
        self.target = (lo + hi) / 2
        self.playout, self.base, self.samples, self.peaks, self.head = None, 0.0, [], [], 0

    def clamp(self, value):
        lo, hi, _, _ = MODES[self.mode]
        return min(max(value, lo), hi)

    def observe(self, src, arrival):
        offset = arrival - src
        if self.playout is None or abs(offset - self.base) > self.discontinuity:
            running = self.playout is not None
            self.samples, self.peaks, self.head = [(arrival, offset)], [], 0
            self.base, self.playout = offset, offset + self.target
            return running
        current = self.playout
        self.samples.append((arrival, offset))
        cutoff, expired = arrival - self.window, 0
        while expired < len(self.samples) - 1 and self.samples[expired][0] < cutoff:
            expired += 1
        expired = max(expired, len(self.samples) - self.max_samples)
        del self.samples[:expired]
        self.base = min(o for _, o in self.samples)
        if len(self.samples) >= self.min_samples:
            jitter = sorted(o - self.base for _, o in self.samples)
            pct = jitter[min(len(jitter) - 1, math.ceil((len(jitter) - 1) * MODES[self.mode][2]))]
            while len(self.peaks) > self.head and self.peaks[-1][1] <= pct:
                self.peaks.pop()
            self.peaks.append((arrival, pct))
            while self.head < len(self.peaks) - 1 and self.peaks[self.head][0] < arrival - MODES[self.mode][3]:
                self.head += 1
            self.target = self.clamp(self.peaks[self.head][1] + self.margin)
        desired = self.base + self.target
        if desired - current > self.grow_deadband:
            self.playout = desired
        elif current - desired > self.shrink_deadband:
            excess = current - desired
            self.playout = desired if excess > self.snap else current - min(excess - self.shrink_deadband, self.shrink_per_frame)
        return False


class Store0349:
    catch_up = 0.020

    def __init__(self, mode):
        self.clock, self.q = PlayoutClock0349(mode), []
        self.max_queue = math.ceil(MODES[mode][1] * 60) + 12

    def sched(self, pts):
        return pts + self.clock.playout

    def enqueue(self, pts, arrival):
        if self.clock.observe(pts, arrival):
            self.q = []
        bisect.insort(self.q, pts)
        if len(self.q) > self.max_queue:
            del self.q[:len(self.q) - self.max_queue]

    def select(self, t):
        if self.clock.playout is None:
            return None
        while len(self.q) > 1 and self.sched(self.q[0]) < t - self.catch_up and self.sched(self.q[1]) <= t + 0.0015:
            self.q.pop(0)
        if self.q and self.sched(self.q[0]) <= t + 0.0015:
            return self.q.pop(0)
        return None


def run(store, trace, clock_offset, hz, select_early):
    """Drive a display at `hz`; 0.3.48 selected ~1 refresh before scan-out."""
    events, i = sorted(trace, key=lambda e: e[1]), 0
    t, period, end, shown = events[0][1], 1.0 / hz, events[-1][1] + 0.5, []
    while t < end:
        while i < len(events) and events[i][1] <= t - select_early:
            store.enqueue(*events[i])
            i += 1
        frame = store.select(t - select_early)
        if frame is not None:
            shown.append((t, frame))
        t += period
    minutes = len(trace) / FPS / 60
    pairs = list(zip(shown, shown[1:]))
    holds = sum(1 for (v0, _), (v1, _) in pairs if v1 - v0 > max(1.5 / hz, 1.5 / FPS))
    skips = sum(1 for (_, p0), (_, p1) in pairs if p1 - p0 > 1.5 / FPS)
    freezes = sum(1 for (v0, _), (v1, _) in pairs if v1 - v0 > 0.1)
    latency = statistics.median(v - clock_offset - p for v, p in shown)
    return holds / minutes, skips / minutes, freezes / minutes, latency * 1000


def table(hz):
    print(f"\n{hz:.0f} Hz display — per minute: repeated frames / skipped frames / freezes >100 ms / median glass latency")
    variants = [("0.3.48", lambda: Store0348(), 1.0 / hz)]
    variants += [(f"0.3.49 {m}", (lambda m=m: Store0349(m)), 0.0) for m in MODES]
    for name, factory, early in variants:
        cells = []
        for profile in PROFILES:
            rows = [run(factory(), *make_trace(500 + s, 60.0, profile), hz, early) for s in range(8)]
            h, k, f, l = (statistics.mean(c) for c in zip(*rows))
            cells.append(f"{profile}: {h:5.1f} / {k:5.1f} / {f:4.1f} / {l:4.0f} ms")
        print(f"{name:20s} | " + " | ".join(cells))


if __name__ == "__main__":
    table(60.0)
    table(120.0)
