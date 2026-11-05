#!/usr/bin/env python3
"""CLI for the shared bounded GX/model inspector used by the virtual loader."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'standalone_host/fmv'))
from gx_model import *

if __name__ == '__main__':
    main()
