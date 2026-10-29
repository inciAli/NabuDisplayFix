# NabuDisplayFix

Fixes the half-black screen and dead touch you get on the Xiaomi Pad 5 (Windows on ARM) after the
screen sleeps with `ForceActive` set to 0.

This is a PowerShell script that patches the display driver already on your tablet.
The script takes your own copy, signs it with a certificate it creates on your tablet, and sets it up
next to the original. Your original driver package isn't touched.

It only works on the nabu C-PHY display driver, `qcdxkm8150.sys` 27.20.2140.0 (SHA-256
`8c62afde3009041bf05bcc5213582f3914c4a0aa3fab6ec242cce61665470b45`). To make Qualcomm's driver work
with nabu's panel, that build replaced some instructions with `nop`s, including a display lane setting
that gets lost when the display powers down. The fix fills six of those `nop`s back in, using the same
values your tablet's UEFI sets at boot:

| File offset | Now | After the fix | What it does |
|---|---|---|---|
| `0x1297F0` | `d503201f` `nop` | `b906192b` `str w11, [x9, #0x618]` | brings back Qualcomm's own write: lanes 0–2 = `0x40` |
| `0x12A0B0` | `d503201f` `nop` | `f947dae8` `ldr x8, [x23, #0xfb0]` | finds the display registers |
| `0x12A0B4` | `d503201f` `nop` | `8b140108` `add x8, x8, x20` | picks the right display link |
| `0x12A0B8` | `d503201f` `nop` | `91425109` `add x9, x8, #0x94, lsl #12` | points at its PHY |
| `0x12A0BC` | `d503201f` `nop` | `528000c8` `mov w8, #0x6` | |
| `0x12A0C0` | `d503201f` `nop` | `b9079928` `str w8, [x9, #0x798]` | lane 3 = `0x06`, and nothing else on lane 3 |

Apart from these six words, only the checksum and the signature change.

So far this has only been tested on one Xiaomi Pad 5 with the CSOT (Huaxing) panel. It should behave
the same on the Tianma panel, but that hasn't been tried yet.

## Installing

You need the C-PHY display driver above, test signing on (`bcdedit /set testsigning on`, then
restart), and Secure Boot off. Open PowerShell as administrator in the folder with the script:

```
Set-ExecutionPolicy -Scope Process Bypass
.\Install-NabuDisplayFix.ps1 -Action Install
.\Install-NabuDisplayFix.ps1 -Action IdleOn
```

Then restart. `Install` sets up the fixed driver in `C:\Windows\System32\drivers\NabuDisplayFix\`,
along with the two firmware files the driver expects next to itself. `IdleOn` sets `ForceActive` to 0.
`IdleOff` sets it back, `Uninstall` switches back to the original driver (restart afterwards), and
`Status` shows what's running.

`Live` loads the fix right away without a restart, for the current session only. The screen goes black
for a few seconds, and touch may need a quick screen off/on. Only use it with Qualcomm's stock Type-C
drivers or UsbNabu 1.0.14 or newer; older NabuTypeC builds crash Windows when the display adapter
restarts.

The script makes a certificate called "NabuDisplayFix Local Test Signing" and trusts it on your tablet
only. Don't expect big standby battery gains from `ForceActive` 0 yet: deep standby on nabu is still
held back by other parts of the system.

## Thanks

- Qualcomm, for the Adreno display driver. It's their work and their copyright; this script only
  changes the six instructions above in your own copy.
- WOA-Project and the woa-msmnile nabu driver pack, for the platform drivers and for adapting the
  display driver to nabu's C-PHY panel.
- Windows On Andromeda, for the UEFI and platform that make Windows on the Pad 5 possible.

This is provided as is, without any warranty; use it at your own risk. If the tablet won't boot after
`Install`, set the `ImagePath` value of the `QCDX` service back to the original driver path from an
offline registry editor. Licensed under GPL-2.0 (see [LICENSE](LICENSE)); that covers the script and
this README, not Qualcomm's driver.
