# Bundled font

`PinLockDigits-Regular.ttf` is a subset of **Roboto** (regular weight, width 100), used only for the
digits on the PIN keypad.

The subset was built from the official variable font published at
[google/fonts, `ofl/roboto`](https://github.com/google/fonts/tree/main/ofl/roboto):

```
fonttools varLib.instancer -o Roboto-Regular.ttf "Roboto[wdth,wght].ttf" wght=400 wdth=100
fonttools subset Roboto-Regular.ttf --unicodes="30-39" --output-file=PinLockDigits-Regular.ttf
```

This keeps the bundled file to a couple of kilobytes (just the ten digit glyphs) instead of shipping
the full ~480 KB variable font. `OFL.txt` is Roboto's original license, included here as required by
its terms.
