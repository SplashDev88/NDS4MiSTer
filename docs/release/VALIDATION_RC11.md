# RC11 validation scope

RC11 packages the tested Portrait FMV Beta4 runtime on the accepted Portrait Beta3/menu baseline. Renderer and FPGA bytes are unchanged. The host is rebuilt only to change the menu/footer from rc10 to rc11; ELF section comparison proves identical executable code and only that read-only string plus the linker build ID differ. Supervisor changes relative to the tested beta are release-label text only. The normal installation path and launcher replace the private-beta path.

## Existing hardware and software evidence

- Full Portrait opening playback and skip on USA, Europe, Japan and Japan Rev 1 at 1 GHz. Approximately 30.046 source-equivalent fps in the accepted runs versus 22.252 fps in the USA baseline. This is movie cadence, not game-wide FPS.
- Full original-versus-accelerated decoded RGB equivalence for all four movies. Captured audio confirms soundtrack continuity and timing, not a separate lip-sync test.
- The gameplay optimization qualification covers bounded USA revision 0 scenes, exact rendering/RAM/audio/save comparisons, and regression routes in Dawn of Sorrow, NSMB and Mario Kart. No full-game or every-region gameplay claim.
- The accepted menu baseline includes rotated digital menus, independent upright analog menus and the compact unrotated horizontal Direct Video 1 menu. The full display matrix also records open LCD-grid issues.
- Original ROMs/saves and rollback beta files passed preservation checks during the beta qualification.

The detailed Portrait movie and menu reports are in source/validation. Hardware results belong to those pinned beta artifacts; RC11's final ZIP has separate offline packaging validation. Packaging alone is not a new full hardware qualification.

## RC11 packaging checks

The packaging recipe verifies the original Beta4 ZIP hash, exact runtime inputs, all frozen FPGA build-input hashes, guest-hook hashes, complete archive checksums, corresponding source and licenses, safe regular archive paths, and absence of ROMs/saves/personal settings. It simulates an upgrade with saved settings and save-file sentinels. The packaged automatic-movie validator is run after extraction. 63 host/preflight/recovery tests, 59 FMV loader tests and the ARM menu, cartridge-reader and framed-loading C++ suites passed. Receipts are included under source/validation; full logs are retained alongside the release ZIP.

## Retained limitations

Static FPGA timing is not closed (setup -15.933 ns, hold +0.051 ns, recovery -15.031 ns). The accepted bitstream is retained; no timing-clean claim is made. Other RetroTINK LCD Grid 2 layouts can dim or show banding. One initial Japan Rev 1 opening stalled briefly, without reproduction in warm and fresh-save/cache reruns. Gameplay can still slow down and is not consistently 60 fps.
