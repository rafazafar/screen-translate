# Screen Translate

A macOS menu-bar app that translates everything on your screen in place, like Android's long-press-home translate. Press a hotkey and the translated text is painted over the original.

- Global hotkey (default `⌃⌥T`, changeable from the menu bar icon)
- Whole-screen capture on every display, OCR with Apple Vision, translation with Apple's on-device Translation framework
- Default Japanese → English; any pair from the menu works, plus Swap
- Dismiss with Esc, a click, a scroll, or the hotkey again

Requires macOS 26 and Xcode's command-line tools.

## Build and run

```sh
./build.sh
open build/ScreenTranslate.app
```

Set `SIGN_ID="Apple Development: …"` to sign with a stable identity; with the default ad-hoc signature macOS asks for Screen Recording permission again after each rebuild.

First run: allow Screen Recording in System Settings → Privacy & Security, quit and reopen the app, then accept the language download sheet.

## Test without screen-recording permission

```sh
build/ScreenTranslate.app/Contents/MacOS/ScreenTranslate --test in.png out.png ja en
```

Runs OCR, translation and overlay on an image and writes the result to `out.png`.

## Limits

Vertical text isn't grouped into paragraphs, original fonts and weights aren't matched, and OCR is tuned for 2× Retina captures.
