"""Palette port of `PaletteGridTests.swift` plus the palette half of `PreferencesTests.swift`
(firstColor ladder, the coloured marker) — pure pytest, no Qt.

Rule from the Mac side: never hard-code a palette hex in a test — read the module's
tables — except for the tables pinned in PORT.md, which are the point of the pin.
"""
from __future__ import annotations

import math

import pytest

from playout.model import palette as P
from playout.model.palette import (
    CATEGORICAL,
    FAMILIES,
    WELL_TEXT_FLOOR,
    Family,
    color_at,
    contrasting_shade,
    first_color_avoiding,
    hsv_to_rgb,
    label_is_white,
    luminance,
    matches,
    normalized,
    parse_hex,
    ramp,
    rgb_to_hsv,
    shades,
)


def hsb(hex_text: str) -> tuple[float, float, float]:
    rgb = parse_hex(hex_text)
    assert rgb is not None, hex_text
    return rgb_to_hsv(*rgb)


def every_shade() -> list[str]:
    return [shade for family in FAMILIES for hue in family.hues for shade in shades(hue)]


def label_is_dark(hex_text: str) -> bool:
    return not label_is_white(hex_text)


# MARK: - Column shape


def test_each_column_keeps_its_base_colour_in_the_middle():
    for family in FAMILIES:
        for hue in family.hues:
            column = shades(hue, count=5)
            assert len(column) == 5
            assert matches(column[2], hue), f"{family.label}: {hue} came back as {column[2]}"
            # Verbatim, not merely equivalent — a re-encoded base would still match.
            assert column[2] == hue


def test_columns_run_light_to_dark():
    for family in FAMILIES:
        for hue in family.hues:
            column = shades(hue)
            for i in range(1, len(column)):
                assert luminance(column[i]) < luminance(column[i - 1]), (
                    f"{family.label} {hue}: {column[i - 1]} → {column[i]} did not darken"
                )


def test_no_column_repeats_a_shade():
    for family in FAMILIES:
        for hue in family.hues:
            column = shades(hue)
            assert len(set(column)) == len(column), f"{family.label} {hue} repeats a shade: {column}"


def test_no_shade_could_be_mistaken_for_an_empty_well():
    # Empty wells are drawn at about #DEDEDE, luminance 0.73.
    for shade in every_shade():
        if hsb(shade)[1] < 0.15:
            assert luminance(shade) < 0.72, (
                f"{shade} is as pale as an unpainted well and has no hue to say otherwise"
            )


# MARK: - Families


def test_every_family_is_eight_columns_ending_in_a_neutral():
    for family in FAMILIES:
        assert len(family.hues) == 8, family.label
        assert hsb(family.hues[7])[1] < 0.15, f"{family.label} has no neutral column"
        assert len(set(family.hues)) == 8, f"{family.label} repeats a hue"
        for hue in family.hues:
            assert parse_hex(hue) is not None, f"{family.label}: {hue} is not a colour"


def test_family_metadata_matches_the_mac_popover():
    assert FAMILIES == (Family.standard, Family.colourBlind, Family.muted)
    assert [f.raw for f in FAMILIES] == ["standard", "colourBlind", "muted"]
    assert [f.label for f in FAMILIES] == ["Standard", "Colour-blind", "Muted"]
    assert Family.standard.note == "Default hues for new conditions."
    assert Family.colourBlind.note == "Okabe–Ito: stays separable with red/green colour blindness."
    assert Family.muted.note == "Softer tints, for a plate that is mostly full."
    assert Family("colourBlind") is Family.colourBlind


def test_the_auto_assigned_colours_are_all_in_the_grid():
    in_grid = {normalized(hue) for family in FAMILIES for hue in family.hues}
    for index in range(8):
        assigned = normalized(color_at(index))
        assert assigned in in_grid, f"condition {index + 1} gets {assigned}, which no column offers"


def test_categorical_cycle_is_twenty_and_negative_safe():
    assert len(CATEGORICAL) == 20
    assert len(set(CATEGORICAL)) == 20
    for hue in CATEGORICAL:
        assert parse_hex(hue) is not None
        assert normalized(hue) == hue  # stored canonical, so `matches` and equality agree
    for i in range(-45, 45):
        assert color_at(i) == CATEGORICAL[i % 20]


# MARK: - The colour-blind claim


def deuteranope(hex_text: str) -> tuple[float, float, float]:
    """Viénot–Brettel–Mollon deuteranope simulation in linear RGB — as in the Swift test."""
    rgb = parse_hex(hex_text)
    assert rgb is not None

    def lin(v: float) -> float:
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4

    r, g, b = (lin(c) for c in rgb)
    return (0.625 * r + 0.375 * g, 0.700 * r + 0.300 * g, 0.300 * g + 0.700 * b)


def worst_separation(hexes) -> float:
    worst = math.inf
    for i in range(len(hexes)):
        for j in range(i + 1, len(hexes)):
            a, b = deuteranope(hexes[i]), deuteranope(hexes[j])
            worst = min(worst, math.dist(a, b))
    return worst


def test_the_colour_blind_family_separates_better_than_the_standard_one():
    safe = worst_separation(Family.colourBlind.hues)
    standard = worst_separation(Family.standard.hues)
    assert safe > standard * 1.4, (
        f"Okabe–Ito separated by {safe}, standard by {standard} — the label is not earned"
    )


# MARK: - One text colour, everywhere


def test_nothing_the_app_offers_ever_flips_the_label_to_white():
    for hex_text in CATEGORICAL:
        assert label_is_dark(hex_text), f"auto-assigned {hex_text} forces a white label"
    for family in FAMILIES:
        for hue in family.hues:
            assert label_is_dark(hue), f"{family.label} base {hue} forces a white label"
            for shade in shades(hue):
                assert label_is_dark(shade), f"{family.label} shade {shade} forces a white label"
    # Series fill writes its own colours; its deep end used to be far below the floor.
    for hue in CATEGORICAL:
        for count in range(2, 13):
            for step in ramp(count, hue):
                assert label_is_dark(step), f"ramp({count}) of {hue} produced {step}"


def test_white_is_kept_only_for_colours_black_could_not_be_read_on():
    assert label_is_white("#000000")
    assert label_is_white("#1A1A1A")
    assert label_is_dark("#4E79A7"), "Tableau's own blue is 4.6:1 — it does not need white"
    assert P.contrasting_label_color("#000000").name == "white"
    assert P.contrasting_label_color("#4E79A7").name == "black85"
    assert P.contrasting_label_color("#4E79A7").rgba == (0.0, 0.0, 0.0, 0.85)

    wcag_limit = 4.5 * 0.05 - 0.05
    for step in range(0, 101):
        grey = (step / 100,) * 3
        if luminance(grey) > wcag_limit:
            assert not label_is_white(grey), (
                f"luminance {luminance(grey)} clears WCAG but still got a white label"
            )


def test_every_base_has_room_for_its_own_dark_steps():
    for family in FAMILIES:
        for hue in family.hues:
            assert luminance(hue) > WELL_TEXT_FLOOR, (
                f"{family.label} base {hue} sits on the floor, leaving its darker steps nowhere to go"
            )
    for hue in CATEGORICAL:
        assert luminance(hue) > WELL_TEXT_FLOOR, f"categorical {hue} sits on the floor"


def test_brightness_clearing_bisects_to_the_floor():
    assert WELL_TEXT_FLOOR == 0.19
    # A pure blue never clears 0.19 even at full brightness → 1.0 by definition.
    h, s, _ = rgb_to_hsv(0.0, 0.0, 1.0)
    assert P.brightness_clearing(h, s, WELL_TEXT_FLOOR) == 1.0
    for hue in CATEGORICAL:
        h, s, _ = hsb(hue)
        v = P.brightness_clearing(h, s, WELL_TEXT_FLOOR)
        assert 0.0 < v <= 1.0
        # 14 halvings of [0, 1] → a multiple of 2^-14, and the *upper* end of the bracket.
        assert (v * 2**14) == int(v * 2**14)
        assert luminance(hsv_to_rgb(h, s, v)) >= WELL_TEXT_FLOOR
        assert luminance(hsv_to_rgb(h, s, v - 2**-14)) < WELL_TEXT_FLOOR


# MARK: - Matching


def test_matches_survives_case_and_a_missing_hash():
    assert matches("#4E79A7", "#4e79a7")
    assert matches("4E79A7", "#4E79A7")
    assert matches("  #4E79A7 ", "#4E79A7")
    assert not matches("#4E79A7", "#4E79A8")
    # Neither parses, so it falls back to comparing the text itself.
    assert matches("nonsense", "NONSENSE")
    assert not matches("nonsense", "#4E79A7")


def test_parse_and_normalise_follow_nscolor_hex():
    assert parse_hex("#4E79A7") == (0x4E / 255, 0x79 / 255, 0xA7 / 255)
    assert parse_hex(" 4e79a7\n") == parse_hex("#4E79A7")
    for bad in ("", "#", "#4E79A", "#4E79A7F", "##4E79A7", "#4E79G7", "4E 79A7", "#+E79A7", "not a colour"):
        assert parse_hex(bad) is None, bad
    assert normalized(" #4e79a7 ") == "#4E79A7"
    assert normalized("4e79a7") == "#4E79A7"
    assert normalized("nonsense") == "NONSENSE"
    assert P.hex_of(1.0, 0.0, 0.5) == "#FF0080"
    # Half-away-from-zero like CGFloat.rounded(): 0.5/255 rounds up, not to even.
    assert P.hex_of(0.5 / 255, 1.5 / 255, 2.5 / 255) == "#010203"
    assert P.hex_of(1.2, -0.3, 0.5) == "#FF0080"  # clamped


# MARK: - Degenerate input


def test_shades_survive_input_that_is_not_a_colour():
    assert shades("not a colour", count=3) == ["not a colour"] * 3
    assert shades("#4E79A7", count=0) == []
    assert shades("#4E79A7", count=-2) == []
    assert shades("#4E79A7", count=1) == ["#4E79A7"]


def test_black_and_white_still_produce_a_usable_column():
    for extreme in ("#000000", "#FFFFFF"):
        column = shades(extreme)
        assert len(set(column)) == len(column), f"{extreme} → {column}"
        for i in range(1, len(column)):
            assert luminance(column[i]) < luminance(column[i - 1]), f"{extreme} → {column}"


def test_ramp_degenerate_inputs():
    assert ramp(0, "#5889BC") == []
    assert ramp(-1, "#5889BC") == []
    # Count 1 hands the base back verbatim — whatever it looked like.
    assert ramp(1, "#5889bc") == ["#5889bc"]
    assert ramp(1, "nonsense") == ["nonsense"]
    # Otherwise an unparseable base ramps from the fallback blue.
    assert ramp(4, "nonsense") == ramp(4, "#4E79A7")
    for count in range(2, 13):
        steps = ramp(count, "#000000")
        assert len(steps) == count
        assert len(set(steps)) == count
        for i in range(1, count):
            assert luminance(steps[i]) < luminance(steps[i - 1])


# MARK: - The firstColor ladder (PreferencesTests)


def test_first_colour_never_repeats_while_the_grid_lasts():
    used: set[str] = set()
    picked: list[str] = []
    for i in range(100):
        hex_text = first_color_avoiding(used, i)
        assert normalized(hex_text) not in used, f"repeat at pick {i}"
        used.add(normalized(hex_text))
        picked.append(hex_text)
    # The first twenty are the plain palette in its own order, so the two modes agree
    # completely until a colour would actually have repeated.
    assert picked[:20] == list(CATEGORICAL)
    assert len(set(picked)) == 100
    # Then the shade rows in the order [3, 1, 4, 0], each swept over every hue.
    ladder = [shades(hue)[row] for row in (3, 1, 4, 0) for hue in CATEGORICAL]
    assert picked[20:] == ladder


def test_first_colour_falls_back_once_the_grid_is_spent():
    used = {normalized(hue) for hue in CATEGORICAL}
    for row in range(5):
        for hue in CATEGORICAL:
            used.add(normalized(shades(hue)[row]))
    assert first_color_avoiding(used, 3) == color_at(3)
    assert first_color_avoiding(frozenset(used), 23) == color_at(3)


def test_first_colour_matches_on_normalised_hex():
    # `used` holds normalised hexes; a hand-edited lower-case colour still counts as taken.
    used = {normalized(CATEGORICAL[0].lower())}
    assert first_color_avoiding(used, 0) == CATEGORICAL[1]


# MARK: - Pinned tables (PORT.md — verified against AppKit)


@pytest.mark.parametrize(
    "base, expected",
    [
        ("#5889BC", ["#9EC8F2", "#79A7D7", "#5889BC", "#5482B3", "#507CAA"]),
        ("#F28E2B", ["#FFBC78", "#FAA550", "#F28E2B", "#D17B25", "#B0671F"]),
        ("#928785", ["#CCC2C0", "#AFA4A2", "#928785", "#897F7D", "#807775"]),
        ("#008AD7", ["#55BAF2", "#28A1E5", "#008AD7", "#0084CE", "#007EC5"]),
        ("#BAB0AC", ["#CCC5C2", "#C3BAB7", "#BAB0AC", "#9C9490", "#7E7775"]),
    ],
)
def test_pinned_shade_columns(base, expected):
    assert shades(base) == expected


@pytest.mark.parametrize(
    "count, base, expected",
    [
        (5, "#5889BC", ["#CDE3FA", "#ABCAEA", "#8BB2DB", "#6E9CCB", "#5587BC"]),
        (8, "#5889BC", ["#CDE3FA", "#B9D4F1", "#A6C6E8", "#94B9DF", "#83ACD7", "#729FCE", "#6393C5", "#5587BC"]),
        (3, "#F28E2B", ["#FAE3CD", "#F2B579", "#EB8A2A"]),
    ],
)
def test_pinned_ramps(count, base, expected):
    assert ramp(count, base) == expected


# MARK: - The coloured marker (PreferencesTests)


def test_the_coloured_marker_separates_from_the_well_it_sits_on():
    for family in FAMILIES:
        for hue in family.hues:
            marker = contrasting_shade(hue)
            assert luminance(marker) < luminance(hue) * 0.55, (
                f"{hue} → {marker}, barely different from the well"
            )


def test_the_coloured_marker_keeps_its_hue():
    for hue in list(Family.standard.hues) + ["#102A44", "#0A0A2A"]:
        h1, s1, _ = hsb(hue)
        h2, _, _ = hsb(contrasting_shade(hue))
        # Greys have no hue to preserve.
        if s1 <= 0.15:
            continue
        assert abs(h1 - h2) < 0.02, f"{hue} changed hue"


def test_an_already_dark_condition_gets_a_lighter_marker_instead():
    for hex_text in ("#000000", "#0A0A0A", "#101820", "#0A0A2A"):
        assert luminance(contrasting_shade(hex_text)) > luminance(hex_text) * 2.5 + 0.01, (
            f"{hex_text} had nowhere darker to go and was not lightened either"
        )


def test_contrast_helpers_reject_non_colours():
    with pytest.raises(ValueError):
        luminance("nonsense")
    with pytest.raises(ValueError):
        contrasting_shade("nonsense")


# MARK: - HSV round trip


def test_hsv_round_trips_every_offered_colour():
    for hex_text in set(CATEGORICAL) | {hue for f in FAMILIES for hue in f.hues} | set(every_shade()):
        rgb = parse_hex(hex_text)
        assert P.hex_of(*hsv_to_rgb(*rgb_to_hsv(*rgb))) == hex_text
    # AppKit reports a pure red as hue 1.0, not 0.0; either way it comes back red.
    assert rgb_to_hsv(1.0, 0.5, 0.5)[0] == 1.0
    assert P.hsv_hex(1.0, 0.5, 1.0) == P.hsv_hex(0.0, 0.5, 1.0) == "#FF8080"
    assert rgb_to_hsv(0.5, 0.5, 0.5) == (0.0, 0.0, 0.5)
    assert rgb_to_hsv(0.0, 0.0, 0.0) == (0.0, 0.0, 0.0)
