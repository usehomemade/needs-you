"""Needs You app icon: dark squircle tile, the speaking glow hugging its inner edge.
Blue (the user) on the left, orange (Claude) on the right, blended at top and bottom.
Writes the full-bleed art (for Icon Composer), the masked 1024 master with the
Big Sur+ grid (824 px body, 100 px margin, soft drop shadow) and an .iconset."""
import sys, os
import numpy as np
from PIL import Image, ImageFilter

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)
SS = 2  # supersampling


def hex3(h):
    return np.array([(h >> 16 & 255), (h >> 8 & 255), (h & 255)], float) / 255


def lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


USER = [lin(hex3(h)) for h in (0xf5f5f7, 0x9ecbff, 0xe8f2ff, 0x7fb4ff)]
CLAUDE = [lin(hex3(h)) for h in (0xd97757, 0xf0a37f, 0xc25e3c, 0xffc9a8)]


def palette(t, stops, sharp=30.0):
    """Same cyclic Gaussian palette as Glow.swift."""
    acc = np.zeros(t.shape + (3,))
    ws = np.zeros(t.shape)
    for i, c in enumerate(stops):
        d = t - i * 0.25
        d -= np.rint(d)
        w = np.exp(-d * d * sharp)
        acc += w[..., None] * c
        ws += w
    return acc / ws[..., None]


def superellipse(N, n=5.0, half=None):
    """Signed edge distance (px, positive inside) of a superellipse filling N x N."""
    half = half or N / 2
    ax = (np.arange(N) + 0.5 - N / 2) / half
    X, Y = np.meshgrid(ax, ax)
    r = (np.abs(X) ** n + np.abs(Y) ** n) ** (1 / n)
    # Gradient-normalised implicit distance: close to the true distance near the edge.
    gx = np.sign(X) * np.abs(X) ** (n - 1) * r ** (1 - n)
    gy = np.sign(Y) * np.abs(Y) ** (n - 1) * r ** (1 - n)
    g = np.maximum(np.hypot(gx, gy), 1e-6)
    return (1 - r) / g * half, X, Y


def edge_distance(N):
    """True distance (px) from the squircle edge inward, softened so the medial-axis
    crease (the X from the corners) never shows."""
    from scipy.ndimage import distance_transform_edt, gaussian_filter
    d, X, Y = superellipse(N)
    inside = d > 0
    dt = distance_transform_edt(inside).astype(float)
    # Blend: exact near the edge, smoothed further in.
    sm = gaussian_filter(dt, N * 0.035)
    w = np.clip(dt / (N * 0.08), 0, 1)
    return dt * (1 - w) + np.maximum(sm, dt * 0.0) * w, X, Y


def nested_distance(N, n=5.0):
    """Distance-like field from nested superellipses: exact at the side midpoints,
    smooth everywhere (no corner crease), zero on the tile edge."""
    half = N / 2
    ax = (np.arange(N) + 0.5 - half) / half
    X, Y = np.meshgrid(ax, ax)
    r = (np.abs(X) ** n + np.abs(Y) ** n) ** (1 / n)
    # Nested shapes crowd at the corners; stretch the field there so the glow keeps
    # the same width all the way round.
    c = (2 * np.abs(X * Y) / np.maximum(X * X + Y * Y, 1e-9)) ** 3
    c *= np.clip((r - 0.55) / 0.35, 0, 1) ** 2
    return (1 - r) * half * (1 + 0.24 * c), X, Y


def squircle(N, R=185.4 / 824, smooth=1.528, n=3.25):
    """Rounded square with continuous (squircle) corners, as a signed distance in px
    (positive inside). Corner radius 185.4 of 824, the macOS grid value; the curve
    starts 1.528 R from the corner and is a p-norm arc, like Apple's smoothed corners."""
    half = N / 2
    ax = np.arange(N) + 0.5 - half
    X, Y = np.meshgrid(ax, ax)
    Rc = R * smooth * N
    qx = np.abs(X) - (half - Rc)
    qy = np.abs(Y) - (half - Rc)
    corner = (np.maximum(qx, 0) ** n + np.maximum(qy, 0) ** n) ** (1 / n)
    sdf = corner + np.minimum(np.maximum(qx, qy), 0) - Rc
    return -sdf, X / half, Y / half


def art(N, small=False):
    """Full-bleed tile art, linear RGB, N x N. Distances are in units of the
    824 px icon body (u = N / 824)."""
    u = N / 824.0
    d, X, Y = squircle(N)
    d = np.maximum(d, 0) / u  # in body px
    wide = 1.9 if small else 1.0
    # Base: near black, faint cool depth gradient, lighter at the top.
    base_top = lin(hex3(0x15161c))
    base_bot = lin(hex3(0x060608))
    k = np.clip((Y + 1) / 2, 0, 1)[..., None]
    col = base_top * (1 - k) + base_bot * k
    # Very faint inner light in the middle.
    inner = np.exp(-(X ** 2 + (Y + 0.08) ** 2) / 0.22)[..., None]
    col = col + inner * lin(hex3(0x23242c)) * 0.55

    # Colour flow along the edge, frozen at one moment of the shader.
    q = (X * 412, Y * 412)
    flow = (0.20 * np.sin(q[0] * 0.0060 + 0.9) + 0.16 * np.sin(q[1] * 0.0072 - 0.4)
            + 0.12 * np.sin((q[0] - q[1]) * 0.0040 + 1.7))
    # Halo leans on the saturated stops, the rim line on the light ones.
    blue_h = palette(np.mod(flow * 0.25 + 0.8, 1), USER, 24) * np.array([0.82, 0.95, 1.1])    # around #9ecbff / #7fb4ff
    blue_l = palette(np.mod(flow * 0.4 + 0.18, 1), USER, 18)
    org_h = palette(np.mod(flow * 0.3 + 0.0, 1), CLAUDE, 18)    # #d97757 / #c25e3c
    org_l = palette(np.mod(flow * 0.5 + 0.25, 1), CLAUDE, 18)

    # Left blue, right orange: blend across the top and bottom.
    side = np.clip((X + 0.62) / 1.24, 0, 1)
    side = side * side * (3 - 2 * side)
    s = side[..., None]
    halo_c = blue_h * (1 - s) + org_h * s
    line_c = blue_l * (1 - s) + org_l * s

    shimmer = 0.88 + 0.12 * np.sin(X * 2.3 - Y * 1.7 + 0.6)
    halo = np.exp(-d / (38.0 * wide)) * 0.45 * shimmer
    near = np.exp(-d / (15.0 * wide)) * 0.6
    line = np.exp(-d / (4.5 * wide)) * 0.5
    glow = halo_c * (halo + near)[..., None] + line_c * line[..., None]
    col = col + glow
    # Gentle shoulder so the rim keeps its hue instead of clipping to white.
    col = 1 - np.exp(-col * 1.15)
    col = col / (1 - np.exp(-1.15))
    return col


def to_img(lin_rgb, alpha=None):
    rgb = (srgb(lin_rgb) * 255 + 0.5).astype(np.uint8)
    if alpha is None:
        return Image.fromarray(rgb, "RGB")
    a = (np.clip(alpha, 0, 1) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(np.dstack([rgb, a]), "RGBA")


def master(size=1024, small=False):
    N = max(size, 256) * SS
    body = round(824 / 1024 * N)
    off = (N - body) // 2
    a = art(body, small)
    d, _, _ = squircle(body)
    mask = np.clip(d + 0.5, 0, 1)
    tile = to_img(a, mask)
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    # Big Sur+ style drop shadow: soft, slightly down.
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sa = Image.new("L", (N, N), 0)
    sa.paste(Image.fromarray((mask * 255 * 0.42).astype(np.uint8)), (off, off + round(10 / 1024 * N)))
    sa = sa.filter(ImageFilter.GaussianBlur(14 / 1024 * N))
    sh.putalpha(sa)
    canvas.alpha_composite(sh)
    canvas.alpha_composite(tile, (off, off))
    return canvas.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    full = to_img(art(2048)).resize((1024, 1024), Image.LANCZOS)
    full.save(f"{OUT}/AppIcon-art-1024.png")
    m = master(1024)
    m.save(f"{OUT}/AppIcon-1024.png")
    ms = master(256, small=True)
    iconset = f"{OUT}/AppIcon.iconset"
    os.makedirs(iconset, exist_ok=True)
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            src = ms if px <= 32 else m
            im = m if px == 1024 else src.resize((px, px), Image.LANCZOS)
            im.save(f"{iconset}/icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png")
    for px in (16, 32, 64, 128, 256):
        (ms if px <= 32 else m).resize((px, px), Image.LANCZOS).save(f"{OUT}/AppIcon-{px}.png")
    print("done")
