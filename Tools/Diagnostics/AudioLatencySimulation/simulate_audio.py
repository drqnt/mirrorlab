#!/usr/bin/env python3
"""Offline comparison of AirPlay mirror-audio buffering: 0.3.48/0.3.49 vs 0.3.50.

Synthetic, not a device measurement. Model: AAC-ELD 44.1 kHz, 480 frames/packet over
Wi-Fi UDP with short stalls, rare unrecoverable losses, sender clock 40 ppm fast, and a
game-like pattern of quiet moments during which iOS sends 4-byte silence packets.
The Mac pulls 512 frames at 48 kHz. "Latency" = sender send time -> start of playout
of that audio (network + receiver buffer), i.e. what the receiver can influence.

    python3 simulate_audio.py
"""
import random
import statistics

SR, SPF = 44_100.0, 480
PACKET = SPF / SR
PROFILES = {"clean": (5.0, (5, 15)), "home": (1.1, (20, 70)), "busy": (0.6, (30, 120))}
POLICIES = {  # mirrors AirPlayAudioBufferPolicy (seconds)
    "lowLatency": dict(preroll=0.030, floor=0.008, cap=0.120, step=0.010, max_margin=0.080, hold=370),
    "balanced": dict(preroll=0.045, floor=0.015, cap=0.220, step=0.020, max_margin=0.120, hold=730),
    "smooth": dict(preroll=0.080, floor=0.035, cap=0.300, step=0.020, max_margin=0.160, hold=920),
}


def make_packets(seed, duration, profile):
    rng = random.Random(seed)
    every, stall_ms = PROFILES[profile]
    stalls, t = [], 0.0
    while t < duration:
        t += rng.expovariate(1 / every)
        stalls.append((t, rng.uniform(*stall_ms) / 1000))
    quiet, t = [], 2.0
    while t < duration:
        t += rng.uniform(4, 12)
        d = rng.uniform(0.4, 3.0)
        quiet.append((t, t + d))
        t += d
    out, last = [], -1.0
    for i in range(int(duration / PACKET)):
        send = i * PACKET * (1 - 40e-6)
        arrival = send + 0.006 + rng.expovariate(1 / 0.002)
        for s, d in stalls:
            if s <= arrival <= s + d:
                arrival = s + d + rng.uniform(0, 0.001)
                break
        if rng.random() < 0.004:
            continue  # lost even after redundancy/resend
        arrival = max(arrival, last + 0.00005)
        last = arrival
        out.append((arrival, i & 0xFFFF, any(a <= send < b for a, b in quiet), send))
    return out


class Ring:
    def __init__(self):
        self.level, self.rebuffering, self.preroll = 0.0, True, 0.0
        self.underflows, self.silence = 0, False
        self.items = []  # [frames, send_time or None]

    def write(self, frames, send):
        if send is not None:
            self.silence = False
        self.items.append([frames, send])
        self.level += frames

    def drop(self, frames):
        self.level -= frames
        while frames > 1e-9 and self.items:
            take = min(frames, self.items[0][0])
            self.items[0][0] -= take
            if self.items[0][1] is not None:
                self.items[0][1] += take / SR
            frames -= take
            if self.items[0][0] <= 1e-9:
                self.items.pop(0)

    def read(self, frames, now, latencies, old):
        if self.rebuffering:
            if self.level < max(self.preroll, frames):
                return
            self.rebuffering = False
        if self.level < frames:
            if old or not self.silence:
                self.underflows += 1
            self.rebuffering = True
            if not old:  # 0.3.50 plays the tail out with a fade and starts clean
                self.drop(self.level)
            return
        if self.items and self.items[0][1] is not None:
            latencies.append(now - self.items[0][1])
        self.drop(frames)


def run(packets, policy, duration, io=512, device_rate=48_000.0):
    ring, lat, i, t = Ring(), [], 0, 0.0
    old = policy is None
    if old:
        ring.preroll = max(int(SR * 0.070), SPF * 6)
        cap = max(int(SR * 0.220), ring.preroll + SPF * 4)
    expected, margin, floor_win, clean, observed, draining = None, 0.0, [], 0, 0, False
    while t < duration:
        while i < len(packets) and packets[i][0] <= t:
            _, seq, silent, send = packets[i]
            i += 1
            if old and silent:
                continue  # 0.3.48/0.3.49 dropped silence packets before sequencing
            gap = 0 if expected is None else (seq - expected) & 0xFFFF
            expected = (seq + 1) & 0xFFFF
            if old:
                if gap > 0:
                    filled = min(gap * SPF, max(0, cap - ring.level))
                    if filled > 0:
                        ring.write(filled, None)
                if ring.level + SPF > cap:
                    ring.drop(ring.level + SPF - cap)
                ring.write(SPF, send)
                continue
            p = POLICIES[policy]
            preroll = lambda: max((p["preroll"] + margin) * SR, 2 * SPF)
            if 0 < gap <= 8 and not silent:
                filled = min(gap * SPF, max(0, preroll() - ring.level))
                if filled > 0:
                    ring.write(filled, None)
            if silent:
                ring.silence, floor_win, draining = True, [], False
                continue
            if ring.underflows != observed:
                observed, clean = ring.underflows, 0
                margin = min(margin + p["step"], p["max_margin"])
                floor_win, draining = [], False
            else:
                clean += 1
                if margin > 0 and clean > p["hold"] and clean % 90 == 0:
                    margin = max(0.0, margin - 0.001)
            ring.preroll = preroll()
            floor_win = (floor_win + [ring.level])[-140:]
            frames = SPF
            if not ring.rebuffering and len(floor_win) == 140:
                floor, target = min(floor_win), (p["floor"] + margin) * SR
                if floor > target + 0.010 * SR:
                    draining = True
                elif floor <= target:
                    draining = False
                if draining:
                    excess = floor - target
                    ratio = 0.06 if excess > 0.080 * SR else 0.04 if excess > 0.030 * SR else 0.02
                    frames = SPF - min(excess, max(1, int(SPF * ratio)))
            cap = max(p["cap"] * SR, preroll() + 4 * SPF)
            if ring.level + frames > cap:
                ring.drop(ring.level + frames - cap)
            ring.write(frames, send)
        ring.read(io * SR / device_rate, t, lat, old)
        t += io / device_rate
    lat = sorted(1000 * x for x in lat)
    return lat[len(lat) // 2], lat[int(0.95 * len(lat))], ring.underflows / (duration / 60)


if __name__ == "__main__":
    print("latency = send -> playout (network + MirrorLab buffer); output device latency is extra")
    for profile in PROFILES:
        print(f"\n== Wi-Fi: {profile}")
        for name, policy in [("0.3.48/0.3.49", None)] + [(f"0.3.50 {m}", m) for m in POLICIES]:
            rows = [run(make_packets(seed, 120.0, profile), policy, 120.0) for seed in range(4)]
            med, p95, uf = (statistics.mean(c) for c in zip(*rows))
            print(f"{name:20s} median {med:6.1f} ms   p95 {p95:6.1f} ms   underruns/min {uf:5.1f}")
