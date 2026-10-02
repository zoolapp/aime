#!/usr/bin/env python3
"""Light, cheerful score + typing sounds for the AIME launch film, synthesised from scratch (no samples, no network).

Usage: compose-audio.py <cues.json> <out.wav>
cues.json comes from `render-launch.mjs --cues` so sounds land on the film's own keystrokes and scene changes.
Deterministic: fixed seed, no wall-clock input.
"""
import json
import sys
import wave

import numpy as np

SR = 48000
cues = json.load(open(sys.argv[1]))
BAR = cues['drop'] / 3          # tempo chosen so bar 3 starts exactly when the logo lands (6.0 s → 120 BPM)
BEAT = BAR / 4
BPM = 60 / BEAT
rng = np.random.default_rng(7)

DUR = cues['duration']
N = int(DUR * SR) + SR           # one spare second for reverb tails, trimmed at the end
music = np.zeros((N, 2))
sfx = np.zeros((N, 2))


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def place(buf, t, sig, pan=0.0, gain=1.0):
    i = int(round(t * SR))
    if i >= N:
        return
    sig = sig[: N - i] * gain
    left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    buf[i:i + len(sig), 0] += sig * left * 1.414
    buf[i:i + len(sig), 1] += sig * right * 1.414


def tt(dur):
    return np.arange(int(dur * SR)) / SR


def band(noise, lo, hi):
    spec = np.fft.rfft(noise)
    f = np.fft.rfftfreq(len(noise), 1 / SR)
    spec[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(spec, len(noise))


# ── Instruments
def marimba(f, dur=0.9, bright=1.0):
    t = tt(dur)
    attack = np.minimum(1, t / 0.003)
    body = np.sin(2 * np.pi * f * t) * np.exp(-t * 4.5)
    tone = np.sin(2 * np.pi * f * 3.93 * t) * np.exp(-t * 22) * 0.22 * bright
    click = np.sin(2 * np.pi * f * 9.2 * t) * np.exp(-t * 90) * 0.05 * bright
    return (body + tone + click) * attack


def bell(f, dur=2.4):
    t = tt(dur)
    partials = [(1, 1, 1.6), (2.76, .35, 3.2), (5.4, .18, 6), (8.93, .07, 9)]
    sig = sum(a * np.sin(2 * np.pi * f * r * t) * np.exp(-t * d) for r, a, d in partials)
    return sig * np.minimum(1, t / 0.002)


def pad(freqs, dur):
    t = tt(dur)
    env = np.minimum(1, t / 0.45) * np.minimum(1, np.maximum(0, (dur - t) / 0.6))
    sig = np.zeros_like(t)
    for f in freqs:
        for k, a in ((1, 1), (2, .28), (3, .1)):
            for det in (-0.12, 0.12):  # cents-level detune for a soft chorus
                sig += a * np.sin(2 * np.pi * f * k * (1 + det / 100) * t + rng.uniform(0, 6.28))
    return sig * env / (len(freqs) * 4)


def bass(f, dur=0.5):
    t = tt(dur)
    env = np.minimum(1, t / 0.006) * np.exp(-t * 3.2)
    return (np.sin(2 * np.pi * f * t) + 0.18 * np.sin(4 * np.pi * f * t)) * env


def kick():
    t = tt(0.32)
    freq = 46 + 80 * np.exp(-t * 32)
    return np.sin(2 * np.pi * np.cumsum(freq) / SR) * np.exp(-t * 11)


def snap():
    n = band(rng.standard_normal(int(0.14 * SR)), 1200, 5200)
    t = tt(0.14)
    return n * np.exp(-t * 38) * 0.6


def shaker():
    n = band(rng.standard_normal(int(0.05 * SR)), 6500, 15000)
    t = tt(0.05)
    return n * np.minimum(1, t / 0.008) * np.exp(-t * 70)


def key_click():
    t = tt(0.03)
    n = band(rng.standard_normal(len(t)), 2500, 9000) * np.exp(-t * 260)
    blip = np.sin(2 * np.pi * rng.uniform(1700, 2100) * t) * np.exp(-t * 300) * 0.4
    return n + blip


def space_thock():
    t = tt(0.07)
    body = np.sin(2 * np.pi * 190 * t) * np.exp(-t * 70)
    n = band(rng.standard_normal(len(t)), 800, 4000) * np.exp(-t * 160) * 0.5
    return body + n


# ── Harmony: I – V – vi – IV in F, voicings close around middle C
CHORDS = [  # (pad voicing, arpeggio tones, bass root)
    ([53, 57, 60], [65, 69, 72, 77], 41),   # F
    ([52, 55, 60], [64, 67, 72, 76], 36),   # C/E
    ([50, 53, 57], [62, 65, 69, 74], 38),   # Dm
    ([50, 53, 58], [62, 65, 70, 74], 34),   # Bb
]
ARP = [0, 2, 1, 3, 2, 1, 3, 2]            # eighth-note pattern over the four arpeggio tones
GROOVE_FROM = 3                           # drums enter on the logo
FINAL_BAR = round(cues['end'] / BAR)      # the end card resolves to F

for bar in range(FINAL_BAR):
    t0 = bar * BAR
    voicing, tones, root = CHORDS[bar % 4]
    place(music, t0, pad([midi(n) for n in voicing], BAR + 0.5), gain=0.32)
    sparse = bar < GROOVE_FROM
    for i, step in enumerate(ARP):
        if sparse and i % 2:              # intro: quarter notes only, leaves room for the typing
            continue
        accent = 1.0 if i in (0, 4) else 0.72
        place(music, t0 + i * BEAT / 2, marimba(midi(tones[step])), pan=(-.35 if i % 2 else .3), gain=0.30 * accent)
    if sparse:
        continue
    for b in range(4):
        tb = t0 + b * BEAT
        if b in (0, 2):
            place(music, tb, kick(), gain=0.38)
            place(music, tb, bass(midi(root), 0.55), gain=0.34)
        else:
            place(music, tb, snap(), pan=0.1, gain=0.20)
            place(music, tb + BEAT / 2, bass(midi(root + 12), 0.3), gain=0.18)
        for s in (1, 3):                  # off-beat sixteenth shaker, humanised
            place(music, tb + s * BEAT / 4 + rng.uniform(-0.004, 0.004), shaker(), pan=0.45, gain=rng.uniform(0.07, 0.11))

# Final bar: a held F chord with a bell on top, no drums.
tf = FINAL_BAR * BAR
place(music, tf, pad([midi(n) for n in (53, 57, 60, 65)], DUR - tf + 0.5), gain=0.45)
for i, n in enumerate((65, 69, 72, 77)):
    place(music, tf + i * 0.06, marimba(midi(n), 2.0), pan=(-.3 + .2 * i), gain=0.28)
place(music, tf, bell(midi(81)), gain=0.20)
place(music, tf, bass(midi(41), 2.5), gain=0.3)

# Scene accents: a two-note bell lift on each scene change, a brighter one for the logo.
for k, t in enumerate(cues['scenes']):
    hi = 84 if k in (0, len(cues['scenes']) - 1) else 81
    place(music, t - 0.06, bell(midi(hi - 5)), pan=-.2, gain=0.10)
    place(music, t + BEAT / 2 - 0.06, bell(midi(hi)), pan=.2, gain=0.12)

# ── Typing and UI sounds, on the film's own keystrokes
for t in cues['keys']:
    place(sfx, t, key_click(), pan=rng.uniform(-.15, .15), gain=rng.uniform(0.10, 0.14))
for t in cues['commits']:
    place(sfx, t, space_thock(), gain=0.20)
for i, t in enumerate(cues['menu']):
    place(sfx, t, space_thock(), gain=0.16)
    if i == 3:                            # AI result appears: a small sparkle
        for j, n in enumerate((84, 88, 91)):
            place(sfx, t + 0.05 + j * 0.05, bell(midi(n), 1.2), pan=(-.3 + .3 * j), gain=0.05)


def pop(f0, f1):
    t = tt(0.16)
    freq = f0 + (f1 - f0) * np.minimum(1, t / 0.06)
    return np.sin(2 * np.pi * np.cumsum(freq) / SR) * np.minimum(1, t / 0.004) * np.exp(-t * 26)


for t in cues.get('sent', []):          # message sent: a quick rising pop
    place(sfx, t, pop(520, 980), pan=.25, gain=0.20)
for t in cues.get('received', []):      # message arrives: a softer falling pop
    place(sfx, t, pop(880, 620), pan=-.25, gain=0.15)


# ── Room: a short synthetic stereo reverb (decaying filtered noise IR) on the music bus.
def reverb(x, seconds=1.4, mix=0.18):
    t = tt(seconds)
    out = np.empty_like(x)
    for ch in range(2):
        ir = band(rng.standard_normal(len(t)), 150, 7000) * np.exp(-t * 5.0)
        ir /= np.sqrt(np.sum(ir ** 2))
        n = len(x) + len(ir)
        wet = np.fft.irfft(np.fft.rfft(x[:, ch], n) * np.fft.rfft(ir, n), n)[: len(x)]
        out[:, ch] = x[:, ch] + mix * wet
    return out


mix = reverb(music) + reverb(sfx, 0.6, 0.08)
mix = mix[: int(DUR * SR)]
t = np.arange(len(mix)) / SR
mix *= np.minimum(1, t / 0.25)[:, None]                                # gentle start
mix *= np.clip((DUR - t) / 2.6, 0, 1)[:, None] ** 1.5                  # fade out under the end card
mix = np.tanh(mix * 1.1) / np.tanh(1.1)                                # soft limiting
mix *= 10 ** (-1 / 20) / np.max(np.abs(mix))                           # peak −1 dBFS; loudness set in ffmpeg

with wave.open(sys.argv[2], 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((mix * 32767).astype('<i2').tobytes())
print(f'{sys.argv[2]}: {len(mix) / SR:.2f}s')
