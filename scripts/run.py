"""Source-tree entry point; works with Unicode Windows paths without editable installs."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from companyx.cli import main
main()
