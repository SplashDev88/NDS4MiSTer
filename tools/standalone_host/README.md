# NDS4MiSTer standalone frontend

See the [project README](../../README.md), [quick start](../../docs/STANDALONE_QUICK_START.txt), and [release notes](../../docs/RELEASE_NOTES_V060_BETA.md).

Build this frontend using `build.sh`. Its menu options are generated from the included FPGA CONF_STR; the release label comes from `VERSION`. The accepted FPGA and renderer are separate components. `supervisor.py`, `Kickstart.sh` and `NDS4MiSTer.sh` supply the matching launch and recovery behavior. See [THIRD_PARTY.md](THIRD_PARTY.md) for font and MiSTer menu attribution.

Offline checks: `python3 -m unittest discover -s tools/standalone_host -p "test_*.py"` from the repository root, plus the four C++ test programs in this directory. These tests use a fake SPI bus; they do not operate hardware.
