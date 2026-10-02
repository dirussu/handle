# Handle — Design Language

_The visual system for Handle. Companion to PRODUCT.md (vision), EVALS.md
(engine), and NOTCH_UI.md (interaction + layout). This doc governs how
every surface looks; NOTCH_UI governs how it behaves._

Form reference: **Boring Notch** (`~/Downloads/boring.notch-main`) — we
keep its interaction shell and notch shape, and replace its visual
treatment with the system below.

---

## North star

**Minimalist, elegant, unmistakably Apple. The notch is the brand.**

There is no logo and no mascot. Handle's identity is two things: the black
notch pill, and the white comet that travels its edge while working.
Everything else recedes so those two read.

The single governing rule:

> **Hierarchy comes from opacity and spacing — not from color, and not
> from weight.**

If a screen needs a second color or a bolder weight to be legible, the
layout is wrong. Fix the spacing first.

---

## Color — white on black, grayscale everything else

Locked decision: **white-only, grayscale.** No brand color, no blue.

### Surface
- Notch + panel surface: **solid black** — both the closed pill and the
  open panel. No translucency, no desktop blur. The open panel reads as
  *one object dropping out of the (black) hardware notch*; opacity would
  break that seam and make the panel look like a separate floating window.
- (We trialled a translucent `NSVisualEffectView` vibrancy surface and
  rejected it: the blur diluted the contrast the white comet and text
  rely on, and the panel stopped reading as continuous with the physical
  notch. Solid black is the decision.)
- Continuous with the hardware notch at the top edge (flared top corners,
  rounded bottom — see Geometry).

### Foreground — the opacity ladder
All foreground content is **white at a fixed set of opacities**. This
ladder *is* the hierarchy:

| Role | Opacity |
|---|---|
| Primary (titles, active text, the comet head) | 100% |
| Secondary (body text, default icons) | 65% |
| Tertiary (captions, timestamps, hints) | 40% |
| Hairlines / dividers | 12% |
| Resting/idle cues | 8–10% |

Accent = **pure white** (focus rings, primary buttons, the comet). Never
a tint. The app's `AccentColor` asset is itself set to **white**, so even
default system controls (toggles, focus rings, selection) inherit white
rather than the system blue — and deleting the asset is wrong, because that
falls back to blue.

### Semantic color — the one exception
**Red is the sole chromatic exception, reserved for danger and errors** —
the error card (icon + tint) and the Confirm button of a destructive-action
card. Nothing else is ever colored: completion and success read in **white**
(a checkmark, not a green tick). No brand color, no blue, no green. If you
reach for any second hue, stop.

---

## Typography — SF Pro, tight and quiet

Locked decision: **SF Pro** (the system font; reads as native macOS).

- Use the system font via `.font(.system(...))` so Dynamic Type and
  system rendering are respected. No bundled fonts.
- **Three sizes, total:**
  | Token | Size / weight | Use |
  |---|---|---|
  | Title | ~15pt semibold | panel header, section titles |
  | Body | ~13pt regular | conversation text, inputs |
  | Caption | ~11pt regular | app-context label, timestamps, hints |
- Hierarchy is carried by **opacity + size**, not by piling on weights.
  Avoid bold for emphasis — drop opacity or add space instead.
- Generous line spacing on body text. Left-aligned. No all-caps except a
  single optional ~10pt tracking-wide label if ever needed.

---

## Geometry — one corner-radius family

Everything rounds the same way the notch does — square-ish top intent,
soft continuous bottom. Use `RoundedRectangle(cornerRadius:, style:
.continuous)` everywhere; never sharp corners.

| Element | Radius |
|---|---|
| Open notch panel (bottom corners) | ~34pt |
| Confirmation / large cards | ~22pt |
| Controls (buttons, input field, bubbles) | ~20pt |
| Cards (tool, attachment, error) | ~18pt |
| Small clips (thumbnails, code blocks) | ~14pt |
| Closed pill | **matches the hardware notch (top 6 / bottom 14) — do NOT increase, or it stops blending** |

Handle leans rounded — soft, generous corners everywhere. The single
exception is the closed pill, whose corners are dictated by the hardware
notch, not taste.

Separation between elements comes from **spacing and 12%-opacity
hairlines**, not from borders or nested filled cards. Avoid
card-within-card. One surface, content floating on it.

Spacing scale (multiples of 4): 4 / 8 / 12 / 16 / 24. Panel content inset
~16pt.

---

## Materials — restrained depth

- One solid-black surface. No stacked materials, no drop shadows on
  internal elements (the panel itself casts one soft ambient shadow to
  lift it off the desktop).
- Buttons: subtle — a 10%-white fill that lifts to ~18% on hover, white
  text/icon. The primary/send action may invert (white fill, black glyph)
  only when active/enabled, to mark it as *the* action.
- Inputs: a faint 8% fill, 12% hairline, white text, white caret. Focus =
  a thin pure-white ring, no glow.

---

## Motion — the comet is the vocabulary

All motion shares the comet's character: **slow, eased, calm — a pendulum,
never a bounce.**

- **The working comet** (NOTCH_UI §Closed pill): a pure-white head with a
  short gradient tail sweeps the notch's visible outline, there and back,
  easing to a stop and reversing at each end. This is the signature motion
  and the tuning reference for everything else.
- Open/close: a gentle spring (low bounce) dropping the panel from the
  notch.
- Content: opacity cross-fades and height-to-fit growth as text streams
  (the `relayoutToFit` behavior). No hard cuts, no slides.
- Result peek / state changes: fade, don't pop.
- Timing: prefer ~0.3–0.5s eases. Nothing snappy-cute. If it feels
  playful, slow it down.

---

## Iconography

- **SF Symbols only**, light/regular weight, white at the opacity ladder.
- Consistent optical size within a context. Hierarchical rendering off by
  default (monochrome white); use it only if a symbol genuinely needs it.
- No custom icons in v1.

---

## Do / Don't

**Do**
- Let black space and silence do the work.
- Express state through the edge (comet) and through opacity.
- Keep every screen reducible to: dark surface, white text, one comet.

**Don't**
- Add a brand color, gradient fills, or tinted accents.
- Use bold weight or a second font to create emphasis.
- Nest filled cards, add borders where spacing would do, or drop shadows
  on internal elements.
- Animate anything faster or bouncier than the comet.

---

## Status of decisions

| Decision | Choice |
|---|---|
| Primary typeface | **SF Pro** (system) |
| Panel surface | **Solid black** (translucent vibrancy trialled and rejected) |
| Accent discipline | **White-only, grayscale**; red the sole exception, for danger/errors |
| Identity | No logo; the notch + comet are the brand |
| Hierarchy mechanism | Opacity + spacing (never color or weight) |
| Primary action | Inverts to **white fill, black glyph** (the send / Confirm button) |

Open later (not blocking): non-notch-display synthesized-pill treatment.
