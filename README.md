# FOID Linux

**F**reedom. **O**pen. **I**ndependent. **D**istributed.

A tiny Linux distribution built completely from scratch: no Debian, Arch or Alpine underneath. Glory to FOID.

> **Status: 0.1-preview.** A text-mode live system. It boots on real hardware (UEFI and BIOS), gets network over Ethernet and ships a handful of tools. No installer, no graphical session yet. This is a preview, not a daily driver.

## What is inside

| Part | What |
|---|---|
| libc / toolchain | musl, cross-toolchain built with [musl-cross-make](https://github.com/richfelker/musl-cross-make) |
| kernel | Linux 6.18 LTS, own config (`-foid`), everything needed for boot built in |
| userland | static BusyBox |
| init | [runit](https://smarden.org/runit/) as PID 1 (stage banners by "foidinit") |
| bootloader | [Limine](https://limine-bootloader.github.io/) (BIOS + UEFI hybrid ISO) |
| tools | nano, htop, curl + git with HTTPS (OpenSSL), dropbear (ssh client; server is off by default) |
| networking | DHCP on the wired interface via BusyBox udhcpc, started as a runit service |
| extras | `foidfetch`, glory messages on every boot stage, FOID Noir colours |

Everything is statically linked. The live system runs from a squashfs image with an overlay in RAM; nothing is written to your disks.

## Try it

Download `foid-linux.iso`, check the hash (`sha256sum -c foid-linux.iso.sha256`) and boot it.

**In QEMU:**

```sh
qemu-system-x86_64 -m 2G -enable-kvm -cdrom foid-linux.iso
```

**On real hardware:** write the image straight to a USB stick (this erases the stick):

```sh
sudo dd if=foid-linux.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Check the device with `lsblk` first. Turn **Secure Boot off**: the bootloader is not signed.
Ventoy: use "normal mode" (not Grub2 mode). Writing with `dd` is the more reliable way.

Log in as `root`; the password is empty (live system, no network services are enabled by default). Run `foidfetch` and `help`.

## Build it yourself

You need a Linux host with `base-devel`-style tools, `curl`, `xz`, `bzip2`, `perl`, `squashfs-tools`, `libisoburn`, `cpio`, `limine` and (for testing) `qemu`.

```sh
git clone https://github.com/foidlinux/foidlinux ~/foid && cd ~/foid
./build-all.sh          # toolchain, kernel, busybox, runit, apps, git, ISO (takes a while)
./test-iso.sh           # boot it in QEMU (FOID_UEFI=1 for UEFI)
```

Individual stages are separate scripts (`build-00-toolchain.sh` ... `build-08-git.sh`), see the header of each. Everything is idempotent; `FOID_FORCE=1 ./build-all.sh` rebuilds all.

## Not in 0.1 (the roadmap)

- `foidwm`: our own window manager, keyboard-first by design (the mouse is for browsers and games only)
- `foidinit`: our own init
- a package manager written in Go
- a graphical session (Sway/wlroots on musl as a stepping stone)
- an installer

## FAQ

**Is it a meme distro?** Yes, on purpose. It also boots, though.
**Why no manual?** RTFM. There is none. You are the manual. (`help` exists out of mercy.)
**Is it based on  Arch/Alpine?** No. It only happened to be built on one of them.

## License

FOID has its own license: see [LICENSE](LICENSE) (the FOID LICENSE, v1.0). Short version: do what you want, keep the notice, do not call your fork "FOID", and no systemd. Packages built by the scripts (Linux, BusyBox, musl, runit, OpenSSL, curl, git, ...) keep their own licenses.
