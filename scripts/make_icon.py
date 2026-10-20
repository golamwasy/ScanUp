"""Draws the ScanUp app icon: a thin-line plane inside fine radar rings on graphite, with one orange dot."""
import math, sys
from PIL import Image, ImageDraw

S = 4                       # supersampling
N = 1024 * S
C = N // 2
GRAPHITE_TOP, GRAPHITE_BOTTOM = (36, 37, 41), (16, 16, 18)
LINE = (236, 238, 242)
EMBER = (255, 150, 40)

def gradient():
    img = Image.new("RGB", (N, N))
    px = ImageDraw.Draw(img)
    for y in range(N):
        f = y / (N - 1)
        px.line([(0, y), (N, y)], fill=tuple(round(GRAPHITE_TOP[i] * (1 - f) + GRAPHITE_BOTTOM[i] * f) for i in range(3)))
    return img

def overlay(base, draw_fn):
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(layer))
    return Image.alpha_composite(base.convert("RGBA"), layer)

def ring(d, radius, width, alpha):
    d.ellipse([C - radius, C - radius, C + radius, C + radius], outline=LINE + (alpha,), width=width)

def polar(radius, degrees):  # degrees clockwise from the top
    a = math.radians(degrees)
    return C + math.sin(a) * radius, C - math.cos(a) * radius

# The plane, nose up, right half as (x, y) in units where the plane is 2 tall. Mirrored for the left half.
HALF = [(0.0, -1.0), (0.022, -0.99), (0.040, -0.955), (0.054, -0.90), (0.064, -0.80), (0.068, -0.60), (0.068, -0.22),
        (0.97, 0.24), (0.995, 0.285), (0.985, 0.335), (0.068, 0.10),
        (0.064, 0.56), (0.075, 0.70), (0.34, 0.86), (0.355, 0.905), (0.335, 0.94), (0.062, 0.90),
        (0.040, 0.975), (0.0, 1.0)]

def plane_points(scale, cx=C, cy=C, dy=0.0):
    right = [(cx + x * scale, cy + (y + dy) * scale) for x, y in HALF]
    left = [(cx - x * scale, cy + (y + dy) * scale) for x, y in reversed(HALF[1:-1])]
    return right + [(cx, cy + (HALF[-1][1] + dy) * scale)] + left

def build(size_px=1024):
    img = gradient()
    outer = 424 * S
    img = overlay(img, lambda d: [ring(d, outer, 5 * S, 120), ring(d, round(outer * 0.70), 4 * S, 70),
                                  ring(d, round(outer * 0.40), 4 * S, 45)])
    # compass ticks at N, E, S, W on the outer ring
    def ticks(d):
        for deg in (0, 90, 180, 270):
            a, b = polar(outer - 4 * S, deg), polar(outer - 40 * S, deg)
            d.line([a, b], fill=LINE + (170,), width=6 * S)
        for deg in range(0, 360, 30):
            if deg % 90:
                a, b = polar(outer - 4 * S, deg), polar(outer - 20 * S, deg)
                d.line([a, b], fill=LINE + (90,), width=4 * S)
    img = overlay(img, ticks)
    # a fading orange trail along the outer ring, ending in the dot
    def trail(d):
        end, steps, span = 38, 70, 85
        for i in range(steps):
            f = i / steps
            a0, a1 = end - span + span * f, end - span + span * (f + 1 / steps)
            p0, p1 = polar(outer, a0), polar(outer, a1 + 0.6)
            d.line([p0, p1], fill=EMBER + (round(255 * f ** 1.6),), width=int((4 + 5 * f) * S))
        x, y = polar(outer, end)
        r = 25 * S
        d.ellipse([x - r, y - r, x + r, y + r], fill=EMBER + (255,))
    img = overlay(img, trail)
    # the plane: filled with the background so the rings do not show through, then a thin outline
    pts = plane_points(290 * S, dy=0.0)
    def body(d):
        d.polygon(pts, fill=(24, 25, 28, 255))
        d.line(pts + [pts[0]], fill=LINE + (255,), width=10 * S, joint="curve")
        for x, y in pts:  # round the corners
            d.ellipse([x - 5 * S, y - 5 * S, x + 5 * S, y + 5 * S], fill=LINE + (255,))
        # a fine centre line down the fuselage
        d.line([(C, C - 0.70 * 290 * S), (C, C + 0.50 * 290 * S)], fill=LINE + (110,), width=4 * S)
    img = overlay(img, body)
    return img.convert("RGB").resize((size_px, size_px), Image.LANCZOS)

if __name__ == "__main__":
    out = sys.argv[1]
    build().save(out)
    print("wrote", out)
