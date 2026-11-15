# Toward real halfway tones (custom "firmware")

## What ReInk does today

The *halfway tones* in ReInk are made in software: two inks in a fixed 50% checker or 25/75 Bayer pattern. They need no hardware changes and work on any case.

## What real intermediate tones would take

Color e-paper particles move partway when a drive is short. An intermediate tone such as "half red" means changing the **waveform**: the voltage/time sequence the panel controller applies during a refresh.

On these cases, the parts are:

- **FM1280-family NFC chip.** A secure controller running a closed applet. Its firmware can't realistically be replaced, so "our own firmware" doesn't mean the chip.
- **Stored panel driver ("recipe").** The board keeps a configuration (`DA`) and an init/refresh sequence (`DB`). `D4` replays it: reset → init → RAM transfer → power on → display refresh → wait BUSY → power off. **This is the programmable part.**
- **Panel controller** (JD79665-class for the 552×768 Huawei panels; 528×768 is likely similar). Its waveform normally lives in OTP. Some controllers accept a waveform/LUT over SPI. Whether this one does is unknown.

## A path that could work

1. **Identify the controller.** Read the panel FPC marking, then get the datasheet. Without LUT-register support there are no new tones, full stop.
2. **Find a read-back.** No known command reads the factory `DB` recipe back. Writing `DB` is **irreversible**: solar2ain warns that the factory driver can't be restored, and their own A1 recipe returned `68CA` (low voltage) where the factory one worked.
3. **Two-pass tones.** Pass 1: normal full refresh. Pass 2: a short custom waveform applied only to pixels marked "half". Encode that as a second image slot, using the code meaning "move toward red" or "leave alone". This keeps the 2-bit frame format.
4. **Power budget.** Phone NFC barely powers one redraw of a panel this size. A second pass may not complete on a phone at all.

## Safety rails in the app

- The APDU console refuses `F0 DA`, `F0 DB` (driver writes) and `24`/`2C` (PIN change/reset) unless **Case → Tools → Allow driver writes** is on.
- Nothing in the normal send path ever writes `DA`/`DB`.

Before experimenting, get a second case to sacrifice.
