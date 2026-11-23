# brcmfmac-apple-43602

Fix for BCM43602 (`14e4:43ba`, subsystem `106b:0157`) losing 5 GHz Wi-Fi after
suspend on Apple Macs under Linux.

## Does this affect you?

All of these should match:

- `cat /sys/class/dmi/id/product_name` → `MacBookPro14,2` (or another 2016–2017
  Touch Bar Mac with this chip)
- `lspci -nnv | grep -A1 BCM43602` → subsystem `106b:0157`
- 5 GHz works after boot and stops after the first suspend, until you reboot
- 2.4 GHz keeps working after suspend
- `journalctl -b -u wpa_supplicant` shows
  `CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16`

That log line does **not** mean the AP rejected you — the driver reports it for
any failed join. PMF settings, `feature_disable` and changing the country code
do not fix it, and reloading the module does not fix it either.

## Why it happens

Apple's EFI programs GPIO 12–14 pad routing (chipcommon `chipcontrol`) and three
PMU `chipcontrol` registers on the Wi-Fi chip at cold boot, presumably for the
5 GHz front end. Neither the firmware nor the driver redoes this. When the
module loses power in suspend, that setup is gone and every 5 GHz join fails.

Confirmed by register values: after resume the registers read all zero.

```
# cold boot: state intact
learned Apple EFI state: chipcontrol 01400090 gpioout 00006000 gpioouten 00007000 pmu 100001ce 903aaa2a 16058048

# after resume: S3 zeroed everything, snapshot replayed
restored Apple EFI GPIO/chipcontrol state (was chipcontrol 00000000 gpioout 00000000 gpioouten 00000000)
```

## What this patch does differently

The prior patch for this problem hardcodes the PMU triple dumped from one
machine. This version **learns** the state from the chip on the first attach
after a cold boot and replays that snapshot on resume.

On the machine used for testing, the learned values matched the hardcoded ones
exactly — which suggests the state is generic for this chip plus Apple EFI, not
board specific. The advantage of learning is that you do not need to know these
numbers in advance, and the code cannot silently apply another machine's values.

The patch only runs when `chip == BRCM_CC_43602_CHIP_ID` **and** subsystem is
`0x0157`, so other hardware is untouched.

## Usage

The patch applies to mainline `pcie.c`. You must build against the source of
**your exact running kernel** — a module built for a different version will not
load.

```bash
# 1. get your kernel source, e.g. for this distro
cd ~/kbuild
curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.15.tar.xz
tar -xf linux-7.2.15.tar.xz && cd linux-7.2.15

# 2. reuse the distro config so the module matches the running kernel
cp /usr/src/linux-omarchy/.config .
cp /usr/src/linux-omarchy/Module.symvers .

# 3. apply
patch -p1 < /path/to/0001-brcmfmac-learn-apple-efi-state.patch

# 4. build only brcmfmac
make olddefconfig && make -j$(nproc) prepare
make -j$(nproc) LOCALVERSION="" KCFLAGS="-DDEBUG" \
     M=drivers/net/wireless/broadcom/brcm80211/brcmfmac modules
```

`build.sh` in this repo automates the Omarchy-specific parts.

### Three build gotchas

1. **`LOCALVERSION=""` is required.** With `CONFIG_LOCALVERSION_AUTO=y`, vermagic
   becomes `7.2.15-g<sha>` and the module is refused at load time. Also set
   `CONFIG_LOCALVERSION="-1-omarchy"` and disable `LOCALVERSION_AUTO` in `.config`.
2. **`KCFLAGS="-DDEBUG"` is required.** With `CONFIG_BRCMDBG=y`, `debug.h`
   declares the debugfs helpers only under `DEBUG`, but `M=` builds skip the
   parent Makefile's `subdir-ccflags-$(CONFIG_BRCMDBG) += -DDEBUG`, so `debug.c`
   fails with redefinition errors.
3. **`scripts/module.lds` must exist.** Without it `make` reports
   "no rule to make target brcmfmac.ko", which looks like a missing target
   definition but is really a missing prerequisite. `make scripts/module.lds`.

Note that `/usr/src/linux-omarchy` on Omarchy ships only Kconfig files — every
`.c` under `drivers/net/wireless` is stripped — so you cannot build in place.

### Install

Install into `updates/`, which has higher priority than `kernel/` and leaves the
original module untouched:

```bash
D=/usr/lib/modules/$(uname -r)/updates/brcmfmac
sudo mkdir -p $D
sudo cp .../brcmfmac.ko $D/
sudo zstd -q -f $D/brcmfmac.ko -o $D/brcmfmac.ko.zst && sudo rm $D/brcmfmac.ko
sudo depmod -a "$(uname -r)"
modinfo -n brcmfmac    # should point into updates/
```

Then reload: `sudo modprobe -r brcmfmac_wcc brcmfmac && sudo modprobe brcmfmac`

## Things to know

- **Back up first and keep a way to get online.** This replaces your Wi-Fi driver.
- **A kernel update invalidates the module.** Rebuild against the new kernel.
  Never let an old driver source auto-build on a new kernel — a module that fails
  to load leaves you with no Wi-Fi.
- **Secure Boot:** if enabled you must enroll your own signing key. The machine
  used here had it off and did not enforce module signatures.
- **The snapshot lives in module memory.** Reloading the module discards it; if
  the chip is already in the lost state at that point, the compiled-in fallback
  values are used. On a cold boot the state is intact, so the snapshot is always
  learned first.
- **Not a complete cure.** At weak signal joins can still be slow or fail; part
  of that is a separate, unsolved issue.

## Related

- The 2.4 GHz cold-boot failure on these Macs is a **separate** bug in the
  community NVRAM file: its `swctrlmap_2g` repeats the 5 GHz switch map. Fixed
  upstream in omarchy PR #7671. If 2.4 GHz fails on cold boot, check that first —
  it is not addressed by this patch.

## Tested on

MacBookPro14,2 / BCM43602 `14e4:43ba` / subsystem `106b:0157`,
Omarchy 4.5.0-3, kernel `7.2.15-1-omarchy`, S3 (deep) suspend.
Both 2.4 GHz and 5 GHz verified after cold boot and after resume.

## Credits

The GPIO/chipcontrol diagnosis and the original hardcoded patch are from
nonderbe's write-up (gist `648bbd5cdf6a80c96965827bb5ef30e1`). This repo only
changes how the values are obtained.
