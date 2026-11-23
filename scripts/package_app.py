"""Package the signed application without filesystem extended attributes."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import sys

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "dist" / "点读包转换.app"
with ZipFile(root / "dist" / "点读包转换-macOS.zip", "w", ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob("*")):
        archive.write(path, path.relative_to(app.parent))
