# Castlevania rendering-job experiments — no promotion

Increasing raster scheduling from four jobs to eight did not produce an accepted performance improvement. Both experimental service builds passed their full ARM self-tests, and neither was installed for gameplay or packaged as a beta. Castlevania Beta8 remains the accepted build.

The global eight-job probe preserved full-buffer results in 160 serial, split, queued and delayed-worker captured-frame comparisons. Its partition helper passed 200,424 independent four/eight-job cases. Under a dual-core benchmark with the MiSTer menu still runnable on CPU1, combat wall time fell 1.946%, while the two NSMB controls worsened 17.236% and 21.343%. A subsequent idle check showed the menu consuming essentially an entire core. Those figures describe a menu-contention experiment, not isolated two-core performance or gameplay.

A second build limited eight jobs to the exact Castlevania USA revision 0 profile and nonshadow queued frames. Other games and every shadow frame retained four jobs and the original shadow-boundary gate. It passed the complete service self-test, the same partition cases, and 160 full-buffer comparisons with an explicit assertion that eligible queued frames used eight jobs. The complete ARM core was rebuilt for the changed renderer layout. All 851 build inputs were checked and private source overlays restored.

For the corrected native test, the hash-verified menu process was paused, protected by a watchdog, and resumed with its original affinity after testing. Clocks and protected files were restored. Each result below uses six samples per build in reversed order.

| Saved scene | CPU time change | Wall time change |
| --- | ---: | ---: |
| Cave | +1.592% | +3.059% |
| Combat | -0.757% | +1.779% |
| NSMB castle | +0.728% | +0.318% |
| NSMB left | +0.359% | +0.406% |
| Mario Kart heavy | +2.543% | +2.716% |

Positive means slower. The target wall-time results and Mario Kart control did not justify moving this candidate to live trials. No pixel arithmetic, frame-admission policy, clock, FPGA, or RTC changes were made. These snapshot timings are not animation FPS.
