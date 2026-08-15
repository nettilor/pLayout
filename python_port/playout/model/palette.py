"""Palette: categorical cycle, swatch families, shades, ramp, contrast rules —
mirrors `Sources/PLayout/Model/Palette.swift` (and the NSColor extensions there). M1.

Pure Python, no Qt. AppKit's HSB↔RGB on an sRGB colour is plain HSV in sRGB;
`rgb_to_hsv`/`hsv_to_rgb` below follow AppKit's evaluation order (and its fused
multiply-add) so the results are bit-identical to `NSColor`, not merely close.
RGB channels are clamped to [0, 1] after conversion, luminance is computed on the
unquantised floats, and hex channels round half-away-from-zero like
`CGFloat.rounded()`. Verified against NSColor: 0 mismatches over every shade of
every family and categorical hue and every ramp of counts 1…12 over the
categorical bases, plus thousands of random colours. The one known residue: when
a *custom* base is bright enough that its lightest shade asks for a brightness
above 1, AppKit clamps through ColorSync in float32 and a channel sitting exactly
on a half-step can round the other way (about 1 in 7000 random hexes, one unit in
one channel of one swatch); no palette colour is affected.
"""
from __future__ import annotations

import math
from fractions import Fraction
from dataclasses import dataclass
from enum import Enum
from typing import Iterable, Sequence

RGB = tuple[float, float, float]
HSV = tuple[float, float, float]

# MARK: - The categorical cycle

#: Categorical colours chosen for separation at small well sizes. Three of these
#: are Tableau's own hues lifted in brightness until near-black text clears
#: `WELL_TEXT_FLOOR` on them: the blue, the brown and the grey.
CATEGORICAL: tuple[str, ...] = (
    "#5889BC", "#F28E2B", "#59A14F", "#E15759", "#B07AA1",
    "#76B7B2", "#EDC948", "#FF9DA7", "#A17962", "#8CD17D",
    "#A0CBE8", "#FFBE7D", "#D4A6C8", "#499894", "#D7B5A6",
    "#B6992D", "#86BCB6", "#FABFD2", "#928785", "#F1CE63",
)


def color_at(index: int) -> str:
    """`Palette.color(at:)` — the categorical list cycled, negative-safe."""
    n = len(CATEGORICAL)
    return CATEGORICAL[((index % n) + n) % n]


# MARK: - Hex plumbing (the NSColor(hex:) / hexString extension)


def parse_hex(text: str) -> RGB | None:
    """`NSColor(hex:)`: trim whitespace, drop one leading '#', then exactly six hex
    digits → (r, g, b) in [0, 1]; anything else → None."""
    if not isinstance(text, str):
        return None
    s = text.strip()
    if s.startswith("#"):
        s = s[1:]
    if len(s) != 6:
        return None
    try:
        v = int(s, 16)
    except ValueError:
        return None
    if s[0] in "+-" or any(ch not in "0123456789abcdefABCDEF" for ch in s):
        return None
    return (((v >> 16) & 0xFF) / 255, ((v >> 8) & 0xFF) / 255, (v & 0xFF) / 255)


def _channel(c: float) -> int:
    # `CGFloat.rounded()` is half-away-from-zero; Python's round() is banker's.
    c = min(1.0, max(0.0, c))
    return int(math.floor(c * 255 + 0.5))


def hex_of(r: float, g: float, b: float) -> str:
    """`NSColor.hexString` — `"#%02X%02X%02X"` of each channel rounded to 8 bits."""
    return "#%02X%02X%02X" % (_channel(r), _channel(g), _channel(b))


def normalized(hex_text: str) -> str:
    """Hex normalised the way `matches` compares, so it can live in a set:
    parse → canonical upper `#RRGGBB`, else the raw text upper-cased."""
    rgb = parse_hex(hex_text)
    return hex_of(*rgb) if rgb is not None else hex_text.upper()


def matches(a: str, b: str) -> bool:
    """Hex comparison that survives case and a missing '#'; when either side is
    not a colour, both fall back to a case-insensitive text compare."""
    x, y = parse_hex(a), parse_hex(b)
    if x is None or y is None:
        return a.casefold() == b.casefold()
    return hex_of(*x) == hex_of(*y)


# MARK: - HSV wrappers


def rgb_to_hsv(r: float, g: float, b: float) -> HSV:
    """`NSColor.getHue(_:saturation:brightness:alpha:)` on an sRGB colour.

    Mathematically plain HSV (`colorsys.rgb_to_hsv` agrees to within 1–2 ulp),
    but written the way AppKit evaluates it so the hue is bit-identical: each
    sextant is `k ± (max − mid)/(max − min)`, over 6, and a pure red (g == b)
    reports hue 1.0 rather than 0.0. Verified against NSColor over 30 000 inputs
    including every tie. The ulps matter only where a derived colour lands on an
    exact half-channel — `contrasting_shade` of an 8-bit colour does — but the
    point of the port is that a Mac and a Windows file agree to the hex."""
    mx = max(r, g, b)
    mn = min(r, g, b)
    d = mx - mn
    v = mx
    s = 0.0 if mx == 0.0 else d / mx
    if d == 0.0:
        return (0.0, s, v)
    if r == mx:
        h6 = 1.0 - (r - g) / d if g > b else 5.0 + (r - b) / d
    elif g == mx:
        h6 = 3.0 - (g - b) / d if b >= r else 1.0 + (g - r) / d
    else:
        h6 = 5.0 - (b - r) / d if r >= g else 3.0 + (b - g) / d
    return (h6 / 6.0, s, v)


def _fma(a: float, b: float, c: float) -> float:
    """a*b + c with a single rounding — what the arm64 compiler emits for AppKit's
    HSB→RGB (`v * (1 - s*f)` contracts to a fused multiply-add). Emulated exactly
    through rationals; a few hundred calls per palette pass, so cost is nil."""
    return float(Fraction(a) * Fraction(b) + Fraction(c))


def hsv_to_rgb(h: float, s: float, v: float) -> RGB:
    """`NSColor(hue:saturation:brightness:alpha:)` in sRGB, channels clamped to
    [0, 1]. Same sextant algorithm as `colorsys.hsv_to_rgb`, but the two mixed
    channels are formed with a fused multiply-add so the result is bit-identical
    to AppKit's (verified against NSColor over 5000 random inputs)."""
    if s == 0.0:
        c = min(1.0, max(0.0, v))
        return (c, c, c)
    h6 = h * 6.0
    i = math.floor(h6)
    f = h6 - i
    i = int(i) % 6
    p = v * (1.0 - s)
    q = v * _fma(-s, f, 1.0)
    t = v * _fma(-s, 1.0 - f, 1.0)
    r, g, b = ((v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q))[i]
    return (min(1.0, max(0.0, r)), min(1.0, max(0.0, g)), min(1.0, max(0.0, b)))


def hsv_hex(h: float, s: float, v: float) -> str:
    return hex_of(*hsv_to_rgb(h, s, v))


# MARK: - Luminance


def _linear(v: float) -> float:
    return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4


def luminance(color: str | Sequence[float]) -> float:
    """WCAG relative luminance (`NSColor.perceivedLuminance`) of a hex string or an
    (r, g, b) triple of floats — computed on the unquantised channels."""
    if isinstance(color, str):
        rgb = parse_hex(color)
        if rgb is None:
            raise ValueError(f"not a colour: {color!r}")
    else:
        rgb = (float(color[0]), float(color[1]), float(color[2]))
    r, g, b = rgb
    return 0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b)


def _hsv_luminance(h: float, s: float, v: float) -> float:
    return luminance(hsv_to_rgb(h, s, v))


# MARK: - Keeping well text one colour

#: WCAG puts 4.5:1 against black at relative luminance 0.175; this sits just above
#: it. The *base* hues are lifted further (about 0.22) so the two steps below a base
#: in its shade column still land above this line.
WELL_TEXT_FLOOR: float = 0.19


def brightness_clearing(hue: float, saturation: float, floor: float) -> float:
    """`Palette.brightness(hue:saturation:clearing:)` — the brightness at which this
    hue first clears `floor`, by a 14-step bisection; 1.0 when even full brightness
    does not clear it."""
    if _hsv_luminance(hue, saturation, 1.0) <= floor:
        return 1.0
    lo, hi = 0.0, 1.0
    for _ in range(14):
        mid = (lo + hi) / 2
        if _hsv_luminance(hue, saturation, mid) < floor:
            lo = mid
        else:
            hi = mid
    return hi


# MARK: - The swatch grid


class Family(Enum):
    """A set of hues offered in the colour popover, one per column of the grid.
    The last column of every family is a neutral."""

    standard = "standard"
    colourBlind = "colourBlind"
    muted = "muted"

    @property
    def raw(self) -> str:
        return self.value

    @property
    def label(self) -> str:
        return _FAMILY_LABELS[self]

    @property
    def note(self) -> str:
        return _FAMILY_NOTES[self]

    @property
    def hues(self) -> tuple[str, ...]:
        return _FAMILY_HUES[self]


_FAMILY_LABELS = {
    Family.standard: "Standard",
    Family.colourBlind: "Colour-blind",
    Family.muted: "Muted",
}

_FAMILY_NOTES = {
    Family.standard: "Default hues for new conditions.",
    Family.colourBlind: "Okabe–Ito: stays separable with red/green colour blindness.",
    Family.muted: "Softer tints, for a plate that is mostly full.",
}

_FAMILY_HUES: dict[Family, tuple[str, ...]] = {
    Family.standard: (
        "#5889BC", "#F28E2B", "#59A14F", "#E15759",
        "#B07AA1", "#76B7B2", "#EDC948", "#928785",
    ),
    # Okabe–Ito, with its blue and its black lifted in brightness to clear
    # WELL_TEXT_FLOOR; hue and saturation untouched.
    Family.colourBlind: (
        "#008AD7", "#56B4E9", "#009E73", "#F0E442",
        "#E69F00", "#D86000", "#CC79A7", "#8B8B8B",
    ),
    Family.muted: (
        "#A0CBE8", "#FFBE7D", "#8CD17D", "#FF9DA7",
        "#D4A6C8", "#86BCB6", "#F1CE63", "#BAB0AC",
    ),
}

#: `Family.allCases`, in the popover's order.
FAMILIES: tuple[Family, ...] = (Family.standard, Family.colourBlind, Family.muted)


def shades(base_hex: str, count: int = 5) -> list[str]:
    """`Palette.shades(of:count:)` — one column of the swatch grid: steps of a single
    hue, lightest first, with the base colour itself (verbatim) in the middle."""
    if count <= 0:
        return []
    rgb = parse_hex(base_hex)
    if rgb is None:
        return [base_hex] * count
    base_hex_canonical = hex_of(*rgb)
    if count == 1:
        return [base_hex_canonical]

    h, s, b = rgb_to_hsv(*rgb)

    # A grey has no hue to say it is painted, so it must stay dark enough not to be
    # read as an empty well (~#DEDEDE). Tableau's warm greys sit at 0.08–0.09
    # saturation, hence 0.15 rather than 0.
    ceiling = 0.80 if s < 0.15 else 0.95
    # Pure black/white have no headroom; the anchor is pulled just inside the range
    # for them. The upper pull applies only to greys.
    anchor = min(max(b, 0.12), 0.94) if s < 0.15 else max(b, 0.12)
    middle = (count - 1) // 2
    minimum_step = 0.03
    lightest = max(
        anchor + minimum_step * max(middle, 1),
        min(ceiling, max(0.88, anchor + 0.22)),
    )
    darkest_saturation = s
    readable = brightness_clearing(h, darkest_saturation, WELL_TEXT_FLOOR)
    darkest = min(
        anchor - minimum_step * max(count - 1 - middle, 1),
        max(min(0.42, anchor * 0.62), readable),
    )

    out: list[str] = []
    for i in range(count):
        if i == middle:
            out.append(base_hex_canonical if anchor == b else hsv_hex(h, s, anchor))
        elif i < middle:
            u = (middle - i) / middle
            out.append(hsv_hex(h, s * (1 - 0.35 * u), anchor + (lightest - anchor) * u))
        else:
            u = (i - middle) / (count - 1 - middle)
            out.append(hsv_hex(h, darkest_saturation, anchor - (anchor - darkest) * u))
    return out


def first_color_avoiding(used: Iterable[str], fallback_index: int) -> str:
    """`Palette.firstColor(avoiding:fallbackIndex:)` — the categorical hues in order,
    then rows [3, 1, 4, 0] of every hue's shade column, then `color_at(fallback)`.
    `used` holds normalised hexes (see `normalized`)."""
    used_set = used if isinstance(used, (set, frozenset)) else set(used)
    for hex_text in CATEGORICAL:
        if normalized(hex_text) not in used_set:
            return hex_text
    for row in (3, 1, 4, 0):
        for hue in CATEGORICAL:
            candidate = shades(hue)[row]
            if normalized(candidate) not in used_set:
                return candidate
    return color_at(fallback_index)


# MARK: - Ramp

_RAMP_FALLBACK_BASE = "#4E79A7"


def ramp(count: int, base_hex: str) -> list[str]:
    """`Palette.ramp(count:baseHex:)` — light-to-dark ramp of a single hue for
    numeric factors; the deep end still carries the near-black label."""
    if count <= 0:
        return []
    rgb = parse_hex(base_hex)
    if rgb is None:
        rgb = parse_hex(_RAMP_FALLBACK_BASE)
        assert rgb is not None
    if count == 1:
        return [base_hex]
    h, s, b = rgb_to_hsv(*rgb)
    sat_floor = max(s, 0.55)
    deepest = max(
        min(b, 0.92), 0.45,
        brightness_clearing(h, sat_floor, WELL_TEXT_FLOOR),
    )
    out: list[str] = []
    for i in range(count):
        t = i / (count - 1)
        sat = 0.18 + (sat_floor - 0.18) * t
        bri = 0.98 - (0.98 - deepest) * t
        out.append(hsv_hex(h, sat, bri))
    return out


# MARK: - Contrast (NSColor.contrastingLabelColor / contrastingShade)

#: `NSColor.contrastingLabelColor` flips to white at or below this luminance —
#: WCAG's own 4.5:1 line against black.
LABEL_WHITE_LUMINANCE: float = 0.175


@dataclass(frozen=True)
class LabelInk:
    """The ink for a label drawn on a colour: `is_white`, else black at 85 %."""

    is_white: bool

    @property
    def name(self) -> str:
        return "white" if self.is_white else "black85"

    @property
    def rgba(self) -> tuple[float, float, float, float]:
        return (1.0, 1.0, 1.0, 1.0) if self.is_white else (0.0, 0.0, 0.0, 0.85)


def label_is_white(color: str | Sequence[float]) -> bool:
    """White iff luminance ≤ 0.175 — nothing the app hands out reaches that."""
    return luminance(color) <= LABEL_WHITE_LUMINANCE


def contrasting_label_color(color: str | Sequence[float]) -> LabelInk:
    return LabelInk(is_white=label_is_white(color))


def contrasting_shade(color: str | Sequence[float]) -> str:
    """`NSColor.contrastingShade` — the colour pushed hard away from its own
    lightness, keeping its hue: the marker drawn on a well filled with it."""
    if isinstance(color, str):
        rgb = parse_hex(color)
        if rgb is None:
            raise ValueError(f"not a colour: {color!r}")
    else:
        rgb = (float(color[0]), float(color[1]), float(color[2]))
    h, s, b = rgb_to_hsv(*rgb)
    go_darker = luminance(rgb) > 0.16
    sat = min(1.0, s * (1.2 if go_darker else 0.85))
    bri = max(0.20, b * 0.5) if go_darker else min(1.0, max(b * 1.9, b + 0.4))
    return hsv_hex(h, sat, bri)


__all__ = [
    "CATEGORICAL",
    "FAMILIES",
    "Family",
    "LABEL_WHITE_LUMINANCE",
    "LabelInk",
    "WELL_TEXT_FLOOR",
    "brightness_clearing",
    "color_at",
    "contrasting_label_color",
    "contrasting_shade",
    "first_color_avoiding",
    "hex_of",
    "hsv_hex",
    "hsv_to_rgb",
    "label_is_white",
    "luminance",
    "matches",
    "normalized",
    "parse_hex",
    "ramp",
    "rgb_to_hsv",
    "shades",
]
