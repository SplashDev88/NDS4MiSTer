"""Link the three Golden Sun guest routines against a verified retail layout."""
from dataclasses import dataclass
from pathlib import Path
import struct
import subprocess

HERE = Path(__file__).resolve().parent
BASE = 0x02000000


@dataclass(frozen=True)
class Layout:
    scene_delta: int
    sdk_delta: int
    data_delta: int
    hud_return: int
    title_file: int
    prologue_file: int


# The game caches a page of file allocation entries in RAM. The first file
# offset in that page identifies the title or two-camera prologue.
LAYOUTS = {
    "BO5E": Layout(0, 0, 0, 0x021C05C0, 0x033E9E00, 0x00506400),
    "BO5P": Layout(0x3C, 0xC0, 0xC0, 0x021C0760, 0x033F5800, 0x00803400),
    "BO5J": Layout(-0x24, -0x1FC, -0x200, 0x021C03C8, 0x033E9E00, 0x00506400),
}


def build_edits(code, work, prefix="arm-linux-gnueabihf-"):
    layout = LAYOUTS[code]
    sdk = layout.sdk_delta
    symbols = {
        "scene": 0x0200A328 + layout.scene_delta, "scene_reset": 0x020026F4 + layout.scene_delta,
        "wait_capture": 0x02055A4C + sdk, "stop_dma": 0x02052778 + sdk,
        "sub_dst": 0x0204FE8C + sdk, "main_dst": 0x0204FF00 + sdk,
        "copy_dma": 0x020523CC + sdk, "hblank_dma": 0x020528E8 + sdk,
        "check_timing": 0x02052808 + sdk, "check_source": 0x02052894 + sdk,
        "wait_dma": 0x0205271C + sdk, "seek": 0x02031A0C + sdk,
        "sdk_seek_twin": 0x0204CAB0 + sdk, "hud_return": layout.hud_return,
        "fat_cache": 0x0207F780 + layout.data_delta, "display_state": 0x02083F4C + layout.data_delta,
        "title_file": layout.title_file, "prologue_file": layout.prologue_file,
    }
    options = [arg for key, value in symbols.items()
               for arg in ("--defsym", f"cart_{key}={value}")]
    work.mkdir(parents=True, exist_ok=True)

    def assemble(name, entry, size):
        obj, elf, binary = (work / (name + ext) for ext in (".o", ".elf", ".bin"))
        subprocess.run([prefix + "as", "-march=armv5te", *options, HERE / (name + ".S"), "-o", obj], check=True)
        subprocess.run([prefix + "ld", *options, "-T", HERE / (name + ".ld"), obj, "-o", elf], check=True)
        subprocess.run([prefix + "objcopy", "-O", "binary", elf, binary], check=True)
        nm = subprocess.check_output([prefix + "nm", "-n", elf], text=True)
        labels = {label: int(address, 16) for line in nm.splitlines() for address, _, label in [line.split()]}
        body = binary.read_bytes()
        assert len(body) <= size
        return (labels[entry] - BASE, body.ljust(size, b"\0")), labels

    scene, labels = assemble("scene_dma", "primary", 0x1F0)
    hud, hud_labels = assemble("hud_dma", "word_entry", 0xE8)
    reuse, reuse_labels = assemble("hud_reuse", "sdk_seek", 0x6C)
    assert hud_labels["half_entry"] == symbols["hblank_dma"] + 0x74
    assert reuse_labels["hud_needs_upload"] == symbols["seek"] + 4

    # The retail ITCM autoload section is linked at the same physical address
    # in all three cartridges. Its position in the compressed ARM9 varies.
    shape_call = 0x01FFA440
    delta = labels["can_send_shape"] - (shape_call + 8)
    assert delta % 2 == 0 and -(1 << 25) <= delta < (1 << 25)
    blx = 0xFA000000 | ((delta & 2) << 23) | ((delta >> 2) & 0xFFFFFF)
    submit = 0xA724 + layout.scene_delta
    delta = labels["submit_camera"] - (BASE + submit + 8)
    assert delta % 4 == 0 and -(1 << 25) <= delta < (1 << 25)
    bl = 0xEB000000 | ((delta >> 2) & 0xFFFFFF)
    to_word = struct.Struct("<I").pack
    return [scene, (0x7B5C0 + layout.data_delta, to_word(blx)), hud, reuse,
            (submit - 8, to_word(0xE3822012)), (submit, to_word(bl))]
