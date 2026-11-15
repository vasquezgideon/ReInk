# Case protocol (as implemented)

ISO 14443-A, ISO-DEP, ISO 7816 APDUs. Core NFC only hands over an ISO 7816 tag after one of the AIDs in `Info.plist` selects. ReInk lists the NFC Forum Type 4 (NDEF) AID `D2760000850101`, which these boards answer, plus `D2760000850100`. If a board instead appears through the MIFARE path, ReInk sends the same APDUs with `sendMiFareISO7816Command`.

## Session

| Step | APDU | Notes |
|---|---|---|
| Info | `00 D1 00 00 00` | TLV reply. `A0` geometry (bytes 3–4 height, 5–6 width, big-endian; some boards report height in bits), `B1` colors, `B2` firmware, `C0` flags/name, `C1` UID |
| Access | `F0 D8 00 00 05 00 00 00 00 0E` | `9000` = OK. `6985` = PIN required |
| PIN (only if 6985) | `00 20 00 01 Lc PIN` | Known PINs: `20091210` (Good Display tags), `5265699919` (Huawei FMSC). Never retried automatically |
| Upload | `F0 D3 slot last Lc block sub data…` | Frame split into 2000-byte blocks, each LZO1X-compressed, then split into ≤250-byte sub-packets. `last` = 1 on a block's final sub-packet. `Lc` = chunk length + 2 |
| Upload (raw) | `F0 D2 slot index len data…` | 250-byte packets, at most 256 of them (64,000 B). Too small for a 528×768 frame |
| Refresh | `F0 D4 P1 P2 00` | P1 bit 7 = skip panel detection, low 7 bits = power-on wait in 100 ms steps. P2 `00` = answer only after the redraw (blocking), `80` = answer at once |
| Status | `F0 DE 00 00 01` | Data byte `01` busy, `00` idle |

Every LZO block is decompressed again before it is sent. If a block fails that round trip, it is sent as a literal stream instead.

## Timing on iPhone

Core NFC drops a tag connection about 20 s after `connect(to:)`. A 528×768 BWRY redraw takes around 18–21 s. ReInk:

1. uploads, then
2. if the upload took longer than the threshold (default 13 s), restarts polling, reconnects to the same UID and sends the refresh in a fresh connection (the official apps do the same), and
3. uses blocking refresh by default, which keeps the connection alive until the case answers.

## Frame format

2 bits per pixel, 4 pixels per byte. 528 × 768 → 101,376 bytes (51 LZO blocks). Default codes: black 0, white 1, yellow 2, red 3. Default layout `columnsRTLTopDown`: columns from the right edge to the left, each column top to bottom, first pixel in the high bits. This is the JD79665 552×768 layout from solar2ain, which comes out to exactly 192 bytes per 768-pixel column. Other layouts and code permutations can be selected in the Case tab; the calibration test pattern exists to settle this on real hardware.

## Status words

`9000` OK · `6985` PIN needed · `6982` security status · `68C6` panel reset failed (retried once) · `68CA`/`698A` low voltage · `68CB` refresh timeout · `6992`/`6993` decompression error · `6995` packet index mismatch · `6A86` bad P1/P2 · `6D00` unsupported instruction. The full table is in `FMSC.swift`.

## Sources

- niw, *400x300 4-Color e-Paper NFC Protocol* (gist) and EPaperNFCSwift
- alt-core/nfc-eink
- solar2ain/ink-nfc-fmsc-by-pn532 (docs/protocol.en.md)
- Alohaq/nfc (protocol table, 552×768)
- CompassSecurity/nfcink (refresh sequence, 68C6 handling)
- NFC.cool, *I Hacked My E-Ink Phone Case So My iPhone Can Write to It*. Reports that one older case family uses an encrypted login handshake, and that a larger iPhone 17 Pro Max case needs compression and answers status only after the redraw.
