# Bundled font

`PinLockDigits-Regular.ttf` is a subset of **Roboto** (regular weight, width 100), used only for the
digits on the PIN keypad.

Google Sans (aka "Product Sans") isn't used here because it's a proprietary Google font that was
never released for third-party redistribution — it isn't bundled with KOReader, isn't on Google
Fonts, and there's no license that would allow shipping it in a public plugin like this one. Roboto
is Google's own actively-maintained open font (SIL Open Font License), visually in the same family,
and legally clean to bundle, so it's the closest available stand-in.

The subset was built from the official variable font published at
[google/fonts, `ofl/roboto`](https://github.com/google/fonts/tree/main/ofl/roboto):

```
fonttools varLib.instancer -o Roboto-Regular.ttf "Roboto[wdth,wght].ttf" wght=400 wdth=100
fonttools subset Roboto-Regular.ttf --unicodes="30-39" --output-file=PinLockDigits-Regular.ttf
```

This keeps the bundled file to a couple of kilobytes (just the ten digit glyphs) instead of shipping
the full ~480 KB variable font. `OFL.txt` is Roboto's original license, included here as required by
its terms.
