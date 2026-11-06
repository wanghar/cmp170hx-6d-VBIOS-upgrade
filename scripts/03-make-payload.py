#!/usr/bin/env python3
"""Build a GSP VBIOS-override payload from a full ROM dump.

The GSP firmware accepts a *single-chain legacy image* and stages at most
512 KiB (staged = payload_size - 0x5E00).  Dual-bank dumps (the second bank
repeats the image at +0x60000) must be trimmed to the first bank.

Usage:
  ./03-make-payload.py 268495.rom -o payload-300w.bin [--expect-md5 a58a...] [--full]
"""
import argparse, hashlib, sys

BANK0 = 0x60000           # first bank size in the CMP 170HX 6D dump
SKIP  = 0x5E00            # driver stages size - SKIP bytes to the firmware
CAP   = 0x80000           # firmware hard cap on the staged bytes (512 KiB)


def legacy_images(data: bytes):
    """Yield (offset, length) of valid x86 legacy images (mirrors the in-driver parser)."""
    size = len(data)
    off = 0
    while off <= size - 0x200:
        if data[off] == 0x55 and data[off + 1] == 0xAA:
            relative = data[off + 0x18] | (data[off + 0x19] << 8)
            if relative <= size - off - 0x18:
                pcir = off + relative
                if (data[pcir:pcir + 4] == b"PCIR" and data[pcir + 0x14] == 0):
                    length = (data[pcir + 0x10] | (data[pcir + 0x11] << 8)) * 512
                    if 0 < length <= size - off and pcir - off <= length and length - (pcir - off) >= 0x18:
                        if sum(data[off:off + length]) % 256 == 0:
                            yield off, length
        off += 0x200


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--expect-md5", default=None)
    ap.add_argument("--full", action="store_true", help="emit the whole dump (archival only)")
    args = ap.parse_args()

    raw = open(args.rom, "rb").read()
    md5 = hashlib.md5(raw).hexdigest()
    print(f"input : {args.rom}  {len(raw)} bytes  md5={md5}")
    if args.expect_md5 and md5 != args.expect_md5.lower():
        sys.exit(f"md5 mismatch: expected {args.expect_md5}, got {md5}")

    images = list(legacy_images(raw))
    if not images:
        sys.exit("no valid legacy image found (need 55AA + PCIR, checksum 0)")
    print(f"images: " + ", ".join(f"legacy @0x{o:06x} len=0x{l:x}" for o, l in images))

    if args.full:
        payload = raw
    else:
        if len(raw) < BANK0:
            sys.exit(f"dump shorter than one bank ({len(raw)} < 0x{BANK0:x})")
        payload = raw[:BANK0]

    # The payload itself must still contain at least one valid legacy image.
    if not list(legacy_images(payload)):
        sys.exit("payload contains no valid legacy image")

    staged = len(payload) - SKIP
    print(f"payload: {len(payload)} bytes (staged {staged} bytes = 0x{staged:x})")
    if staged > CAP:
        print(f"WARNING: staged {staged} > cap 0x{CAP:x} - the firmware will silently "
              f"fall back to the EEPROM VBIOS", file=sys.stderr)

    out = args.output or "payload.bin"
    open(out, "wb").write(payload)
    print(f"written: {out}")
    print(f"SIZE={len(payload)}")
    print(f"sha256={hashlib.sha256(payload).hexdigest()}")


if __name__ == "__main__":
    main()
