#!/usr/bin/env python3
"""Build the pinned, minimal FFmpeg dependency for the private FMV experiment."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path,
                        help="New build directory; existing directories are rejected")
    parser.add_argument("--archive", type=Path, help="Optional local FFmpeg source archive")
    parser.add_argument("--target", choices=("native", "armhf"), default="native")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    root = Path(__file__).resolve().parents[1]
    dependency = root / "third_party/fmv"
    provenance = json.loads((dependency / "PROVENANCE.json").read_text())
    patch = dependency / "ffmpeg-7.1.1-nds.patch"
    if hashlib.sha256(patch.read_bytes()).hexdigest() != provenance["patch_sha256"]:
        raise RuntimeError("Dependency patch hash mismatch")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    archive = args.archive.resolve() if args.archive else output / "ffmpeg-7.1.1.tar.xz"
    if not args.archive:
        with urllib.request.urlopen(provenance["ffmpeg"]["url"], timeout=60) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != provenance["ffmpeg"]["sha256"]:
        raise RuntimeError("FFmpeg archive hash mismatch")
    with tarfile.open(archive) as source_archive:
        for member in source_archive.getmembers():
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or
                    path.parts[0] != "ffmpeg-7.1.1" or
                    not (member.isfile() or member.isdir())):
                raise RuntimeError("Unexpected archive member: " + member.name)
        source_archive.extractall(output)
    source = output / "ffmpeg-7.1.1"
    subprocess.run(["patch", "-p1", "-i", str(patch)], cwd=source, check=True)
    for name, expected in provenance["patched_files"].items():
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError("Patched source hash mismatch: " + name)
    build = output / "build"
    build.mkdir()
    command = [str(source / "configure"), "--prefix=" + str(output / "install")]
    if args.target == "armhf":
        command += ["--enable-cross-compile", "--target-os=linux", "--arch=arm",
                    "--cpu=cortex-a9", "--cross-prefix=arm-linux-gnueabihf-",
                    "--extra-cflags=-O3 -mfpu=neon -mfloat-abi=hard"]
    command += ["--disable-everything", "--disable-programs", "--disable-doc",
                "--disable-avdevice", "--disable-avformat", "--disable-avfilter",
                "--disable-swscale", "--disable-swresample", "--disable-network",
                "--disable-autodetect", "--disable-shared", "--enable-static",
                "--enable-gpl", "--enable-version3",
                "--enable-decoder=mobiclip,actimagine_vx"]
    subprocess.run(command, cwd=build, check=True)
    subprocess.run(["make", "-j", str(args.jobs)], cwd=build, check=True)
    subprocess.run(["make", "install"], cwd=build, check=True)
    print("NDS4MISTER_FFMPEG_ROOT=" + str(output / "install"))


if __name__ == "__main__":
    main()
