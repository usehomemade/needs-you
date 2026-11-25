"""Builds the Needs You UI sounds from CC0 recordings in the Versilian Community
Sample Library (https://github.com/sgossner/VCSL). It renders four sets; the app
ships the "marimba" set as Rosewood (Resources/Sounds/Rosewood, HM-1348).

Needs a VCSL checkout (or the files listed in ACKNOWLEDGEMENTS.md) and
Python with numpy, scipy, soundfile and pyloudnorm.
Run: python3 tools/sounds/build_rosewood.py <VCSL dir> <out dir>
then copy <out dir>/marimba/*.wav to Resources/Sounds/Rosewood/.
"""
import sys, os, re, glob, json
from fractions import Fraction
import numpy as np, soundfile as sf
from scipy import signal
import pyloudnorm as pyln

SRC, OUT = sys.argv[1], sys.argv[2]
SR = 44100
rng = np.random.default_rng(7)
NOTES = {'C':0,'C#':1,'D':2,'D#':3,'E':4,'F':5,'F#':6,'G':7,'G#':8,'A':9,'A#':10,'B':11}
def midi(n):
    m = re.match(r'([A-G]#?)(-?\d)', n); return NOTES[m[1]] + 12*(int(m[2])+1)
FLAT = {'Ab':'G#','Bb':'A#','Db':'C#','Eb':'D#','Gb':'F#'}
def norm_name(n):
    for k,v in FLAT.items(): n = n.replace(k, v)
    return n

def load(path):
    x, sr = sf.read(path, always_2d=True); x = x.mean(1)
    assert sr == SR, (path, sr)
    a = np.abs(x); on = int(np.argmax(a > a.max()*0.03))
    x = x[max(0, on-int(0.0015*SR)):]
    x = x - np.mean(x[:64]) if len(x) > 64 else x
    f = np.ones(len(x)); n = int(0.001*SR); f[:n] = np.linspace(0,1,n)
    return (x*f)/np.abs(x).max()

# --- sample banks: note name -> file (filtered glob) ---
B = SRC + '/'
BANKS = {
  'piano':  (B+'Chordophones/Zithers/Upright Piano, Knight/Sustains/Player_vl1_rr1_{}.wav', ['F2','G2','A2','B2','C#3','D#3','F3','G3','A3','B3','C#4','D#4','F4','G4','A4']),
  'vibes':  (B+'Idiophones/Struck Idiophones/Vibraphone/Soft Mallets/Vibes_soft_{}_v1_*.wav', ['A2','C3','E3','G3','B3','D4','F4','A4','C5']),
  'marimba':(B+'Idiophones/Struck Idiophones/Marimba/*Outrigger_{}_soft_01.wav', ['C2','G2','B2','F3','C4','G4','B4']),
  'chimes': (B+'Idiophones/Struck Idiophones/Hand Chimes/*/sus_{}_r01_main.wav', ['C3','D3','E3','F#3','G#3','A#3','C4','D4','E4','F#4','G#4','A4','C5']),
}
_cache = {}
def bank_file(inst, n):
    pat = BANKS[inst][0].format(n)
    fs = glob.glob(pat) or glob.glob(pat.replace('/*/', '/'))
    assert fs, pat
    return fs[0]
def resample(x, ratio):
    fr = Fraction(ratio).limit_denominator(400)
    return signal.resample_poly(x, fr.denominator, fr.numerator)
USED = set()
LOG = {}; CUR = [None]
def T(ev): CUR[0] = ev
def logsrc(path):
    if CUR[0]: LOG.setdefault(CUR[0], set()).add(path)
def note(inst, name, prefer=None):
    """Recorded note at pitch `name`, from the nearest sample (shift <= 3 semitones)."""
    name = norm_name(name); tgt = midi(name)
    avail = BANKS[inst][1]
    src = prefer or min(avail, key=lambda a: (abs(midi(a)-tgt), midi(a) < tgt))
    key = (inst, src)
    if key not in _cache:
        x = load(bank_file(inst, src))
        if inst == 'vibes':   # soft vibes have nothing musical above 3.5 kHz; the C3 take has a mallet rattle there
            x = signal.sosfiltfilt(signal.butter(4, 3500, 'low', fs=SR, output='sos'), x)
        _cache[key] = x
    USED.add(bank_file(inst, src)); logsrc(bank_file(inst, src))
    x = _cache[key]; st = tgt - midi(src)
    assert abs(st) <= 4, (inst, name, src)
    return resample(x, 2**(st/12)) if st else x.copy()

def extra(path):
    p = glob.glob(B+path); assert p, path; USED.add(p[0]); return load(p[0])

# --- processing helpers ---
def sos(kind, f, order=2): return signal.butter(order, f, kind, fs=SR, output='sos')
def lp(x, f, o=2): return signal.sosfilt(sos('low', f, o), x)
def hp(x, f, o=2): return signal.sosfilt(sos('high', f, o), x)
def shelf(x, f, gain_db):
    """High shelf: split at f, scale the top."""
    lo = signal.sosfiltfilt(sos('low', f, 2), x); return lo + (x-lo)*10**(gain_db/20)
def damp(x, hold, tau, dark=0.0):
    """Natural damping: ring for `hold` s, then decay with time constant `tau`.
    `dark` blends toward a low-passed copy as the note is damped (felt on the bar)."""
    t = np.arange(len(x))/SR
    g = np.where(t < hold, 1.0, np.exp(-(t-hold)/tau))
    if dark > 0:
        d = lp(x, 900); m = np.clip((t-hold)/(3*tau+1e-9), 0, 1)*dark
        x = x*(1-m) + d*m
    end = np.argmax(g < 10**(-62/20)) or len(x)
    y = (x*g)[:end]
    n = min(len(y), int(0.01*SR)); y[-n:] *= np.linspace(1, 0, n)
    return y
def swell(x, length, curve=2.2, cut=2500):
    """Reverse of a recorded note's ring, so it breathes in toward the strike."""
    seg = x[int(0.012*SR):int(0.012*SR)+int(length*SR)][::-1].copy()
    t = np.linspace(0, 1, len(seg)); seg *= t**curve
    seg = lp(seg, cut)
    n = int(0.008*SR); seg[-n:] *= np.linspace(1, 0, n)
    return seg
def mix(parts, tail=0.05):
    """parts: (start_s, signal, gain_db)."""
    end = max(int(s*SR)+len(x) for s, x, g in parts) + int(tail*SR)
    out = np.zeros(end)
    for s, x, g in parts:
        i = int(s*SR); out[i:i+len(x)] += x*10**(g/20)
    return out

# Room: a hand clap recorded in VCSL's room, direct sound removed, so only the room's reply remains.
def make_room():
    c = extra('Idiophones/Struck Idiophones/Claps/SoloClap_vl3.wav')
    pk = int(np.argmax(np.abs(c))); tail = c[pk+int(0.004*SR):].copy()
    tail = lp(hp(tail, 150), 5000)
    n = int(0.002*SR); tail[:n] *= np.linspace(0, 1, n)
    long = signal.fftconvolve(tail, tail)                 # second bounce: longer, smoother, same room
    long = long/np.abs(long).max()*np.abs(tail).max()*0.8
    ir = np.zeros(max(len(tail), len(long))); ir[:len(tail)] += tail; ir[:len(long)] += long
    t = np.arange(len(ir))/SR; ir *= np.exp(-t/0.16)
    return ir/np.sqrt((ir**2).sum())
ROOM = None
def room(x, wet_db=-12, predelay=0.012):
    y = signal.fftconvolve(x, ROOM)[:len(x)+len(ROOM)]
    y = np.concatenate([np.zeros(int(predelay*SR)), y])
    out = np.zeros(len(y)); out[:len(x)] += x; out += y*10**(wet_db/20)*0.5
    return out

def finish(x, target, warm=3000, cut=-4):
    """Tone, trim, loudness. Every set gets the same mastering chain."""
    x = hp(x, 80, 2)                          # no boom on any speaker
    x = shelf(x, warm, cut)                   # warm: soften the top
    x = lp(x, 9000, 2)
    # trim tail at -70 dB under peak and fade out
    a = np.abs(x); thr = a.max()*10**(-60/20)
    last = len(x) - int(np.argmax(a[::-1] > thr))
    x = x[:min(len(x), last+int(0.02*SR))]
    n = min(len(x)//3, int(0.06*SR)); x[-n:] *= np.cos(np.linspace(0, np.pi/2, n))**2
    n = int(0.0008*SR); x[:n] *= np.linspace(0, 1, n)
    meter = pyln.Meter(SR)
    pad = np.concatenate([x, np.zeros(max(0, int(1.0*SR)-len(x)))])
    L = meter.integrated_loudness(pad)
    x = x*10**((target-L)/20)
    for _ in range(3):
        L = meter.integrated_loudness(np.concatenate([x, np.zeros(max(0, int(1.0*SR)-len(x)))]))
        x = x*10**((target-L)/20)
    tp = np.abs(signal.resample_poly(x, 4, 1)).max()
    if tp > 10**(-1.5/20): x = x*10**(-1.5/20)/tp
    return x

# ---------------------------------------------------------------- directions
TONE = {'chimes': (1500, -9)}
EVENTS = ['listening','gotIt','sending','sent','cancelled','stopped','noAnswer','dndOn','dndOff']
TARGET = {'sending': -22, 'gotIt': -21}

NAMES = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
def transpose(name, st):
    m = midi(norm_name(name)) + st; return f"{NAMES[m % 12]}{m//12 - 1}"

def grammar(inst, n0, thud, swell_src=None, ring=0.55, wet=-12, accent=0, key=0):
    # VCSL names middle C "C3" (Yamaha style). The grammar is written in scientific pitch,
    # so shift down an octave: F3 below really is 175 Hz. `key` moves a set to fit its instrument.
    n = lambda name: n0(transpose(name, -12 + key))
    """Same musical grammar for every material, tuned per instrument.
    Key of F. Fundamentals stay between F3 (175 Hz) and F4 (349 Hz)."""
    R = lambda name, hold, tau=None, dark=0.0: damp(n(name), hold, tau or ring*0.15, dark)
    s = {}; LOG.clear()
    T('listening')
    sw = swell_src if swell_src is not None else swell(n('C4'), 0.30)
    s['listening'] = room(mix([(0, sw, -9+accent),
                               (len(sw)/SR, R('F3', 0.06, 0.09), 0),
                               (len(sw)/SR+0.095, R('C4', 0.12, ring*0.17), -1)]), wet)
    T('gotIt')
    s['gotIt'] = room(mix([(0, R('C4', 0.03, 0.10, .5), -2), (0.075, R('A3', 0.05, 0.16, .4), 0)]), wet)
    T('sending')
    echo = R('C4', 0.02, 0.09, .6)
    s['sending'] = room(mix([(0, echo, 0), (0.12, lp(echo, 1800), -8), (0.24, lp(echo, 1200), -15)]), wet+2)
    T('sent')
    s['sent'] = room(mix([(0, R('G3', 0.02, 0.05, .7), -9),
                          (0.06, R('F3', 0.15, ring*0.27), 0), (0.06, R('C4', 0.15, ring*0.24), -3),
                          ]), wet)
    T('cancelled')
    th = damp(thud, 0.03, 0.06)
    s['cancelled'] = room(mix([(0, R('B3', 0.035, 0.035, .9), -1),
                               (0.11, R('F3', 0.05, 0.05, .9), 0),
                               (0.11, lp(th, 700), -10)]), wet-6)       # drier: the door closes
    T('stopped')
    s['stopped'] = room(mix([(0, R('F3', 0.02, 0.03, 1.0), -2), (0, lp(th, 600), -12),
                             (0.15, R('A3', 0.03, 0.08), -3), (0.23, R('C4', 0.08, ring*0.13), -2)]), wet)
    T('noAnswer')
    s['noAnswer'] = room(mix([(0, R('C4', 0.10, 0.12, .4), -1), (0.20, R('Ab3', 0.10, 0.14, .5), -1),
                              (0.42, R('F3', 0.15, ring*0.19, .7), 0)]), wet)
    # DND: octave close and open. On = fall and darken, Off = rise and open.
    T('dndOn')
    on1, on2 = R('F4', 0.03, 0.10, .3), R('F3', 0.10, 0.11, 1.0)
    s['dndOn'] = room(mix([(0, on1, -3), (0.12, lp(on2, 700), 0)]), wet-3)
    T('dndOff')
    off2 = R('F4', 0.10, ring*0.15)
    s['dndOff'] = room(mix([(0, swell(n('F3'), 0.16, cut=900), -10), (0.16, lp(R('F3', 0.03, 0.10), 900), 0), (0.27, off2, -2)]), wet)
    return s, {k: sorted(v) for k, v in LOG.items()}

def blend(m):
    """Three recordings as one instrument: marimba knock for the strike, soft piano for the
    body, vibraphone for the halo (Big Sur alerts were built the same way, from layered pieces)."""
    pno = note('piano', m)
    knock = damp(note('marimba', m), 0.02, 0.03)
    halo = lp(note('vibes', m), 1800)
    n = max(len(pno), len(halo)) + 400
    out = np.zeros(n)
    out[:len(pno)] += pno
    out[:len(knock)] += knock*10**(-7/20)
    out[220:220+len(halo)] += halo*10**(-8/20)     # 5 ms later: the halo blooms just after the strike
    return out/np.abs(out).max()

def build():
    global ROOM; ROOM = make_room()
    frame = extra('Membranophones/Struck Membranophones/Frame Drum/HDrumL_HitMuted_v2_rr1_Sum.wav')
    log = extra('Idiophones/Struck Idiophones/Slit Drum/LogDrumLo_MedM_v2_rr1_Sum.wav')
    bowed = extra('Idiophones/Struck Idiophones/Vibraphone/Bowed/Vibes_bowed_G3_rr1_Main.wav')
    # bowed vibes: a real bow swell on G (392 Hz, the fifth of the vibes key), cut to end where it peaks
    pk = int(np.argmax(np.abs(lp(bowed, 2000)) > np.abs(bowed).max()*0.7))
    bsw = bowed[max(0, pk-int(0.40*SR)):pk].copy()
    t = np.linspace(0, 1, len(bsw)); bsw = lp(bsw*t**1.6, 2500); bsw[-200:] *= np.linspace(1, 0, 200)
    bsw /= np.abs(bsw).max()
    sets = {
      'piano':  grammar('piano',   lambda m: note('piano', m),   frame, ring=0.60, wet=-11),
      'vibes':  grammar('vibes',   lambda m: note('vibes', m),   frame, swell_src=bsw, ring=0.70, wet=-12, accent=2, key=7),
      'marimba':grammar('marimba', lambda m: note('marimba', m), log,   ring=0.50, wet=-10, key=4),
      'blend':  grammar('blend',   blend, log, ring=0.62, wet=-11),
    }
    FR = 'Membranophones/Struck Membranophones/Frame Drum/HDrumL_HitMuted_v2_rr1_Sum.wav'
    LG = 'Idiophones/Struck Idiophones/Slit Drum/LogDrumLo_MedM_v2_rr1_Sum.wav'
    BW = 'Idiophones/Struck Idiophones/Vibraphone/Bowed/Vibes_bowed_G3_rr1_Main.wav'
    CL = 'Idiophones/Struck Idiophones/Claps/SoloClap_vl3.wav'
    thud_of = {'piano': FR, 'vibes': FR, 'marimba': LG, 'blend': LG}
    report = {}; srcs = {}
    for d in sets:
        sets[d], log_ = sets[d]
        srcs[d] = {e: sorted({os.path.relpath(u, SRC) for u in log_.get(e, [])}) for e in EVENTS}
        for e in ('cancelled', 'stopped'): srcs[d][e].append(thud_of[d])
        if d == 'vibes': srcs[d]['listening'].append(BW)
        for e in EVENTS: srcs[d][e].append(CL + ' (room reverb)')
    for d, s in sets.items():
        os.makedirs(f'{OUT}/{d}', exist_ok=True); report[d] = {}
        for e in EVENTS:
            x = finish(s[e], TARGET.get(e, -20), *TONE.get(d, (3000, -4)))
            dith = (rng.random(len(x)) - rng.random(len(x)))/32768
            sf.write(f'{OUT}/{d}/{e}.wav', x+dith, SR, subtype='PCM_16')
            report[d][e] = round(len(x)/SR, 3)
    json.dump({'durations': report, 'sources': srcs},
              open(f'{OUT}/build.json', 'w'), indent=1)
    print(json.dumps(report))

build()
