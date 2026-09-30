"""site/og-card.png, the link preview, drawn from the same data as the site.

    make og-card

LinkedIn, Slack, and iMessage build their cards from the page's Open Graph
tags, so for most people who see the map link the card is all they see. It
carries three numbers the page leads with, read from site/data/ rather than
typed, so it cannot drift from the page it advertises.

Rendered by headless Chromium from an HTML template, not drawn with an imaging
library: the card then uses the site's own type and palette, and the project
gains no dependency (Pillow is not in the venv; Chromium is on the machine).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from string import Template

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "site" / "data"
OUT = ROOT / "site" / "og-card.png"
W, H = 1200, 627

# The card's ground is selleytech.com's survey identity: warm ink, the contour
# field, one terrain-amber accent on the numbers.
CONTOUR = (
    "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='560' "
    "height='420' viewBox='0 0 560 420'%3E%3Cg fill='none' stroke='%23ece5d8' "
    "stroke-opacity='0.05' stroke-width='1.1'%3E%3Cpath d='M-20 300 C60 250 90 160 170 150 "
    "C250 140 270 210 340 200 C420 190 450 90 540 80'/%3E%3Cpath d='M-20 330 C70 280 100 190 "
    "175 180 C255 170 280 240 350 230 C430 220 460 120 560 110'/%3E%3Cpath d='M-20 360 C80 310 "
    "110 220 180 210 C260 200 290 270 360 260 C440 250 470 150 560 140'/%3E%3Cpath d='M-20 390 "
    "C90 340 120 250 185 240 C265 230 300 300 370 290 C450 280 480 180 560 170'/%3E%3Cpath "
    "d='M-20 120 C40 90 110 60 180 70 C250 80 300 130 380 120 C460 110 500 50 560 40'/%3E%3Cpath "
    "d='M-20 90 C50 60 120 30 190 40 C260 50 310 100 390 90 C470 80 510 20 560 10'/%3E%3Cpath "
    "d='M40 420 C80 340 120 260 200 250 C280 240 320 300 400 290 C480 280 520 200 560 200'/%3E"
    "%3Cpath d='M140 420 C170 350 210 280 280 270 C350 260 390 310 460 300 C520 292 540 260 "
    "560 250'/%3E%3C/g%3E%3C/g%3E%3C/svg%3E\")"
)

CARD = Template("""<!DOCTYPE html><html><head><meta charset="utf-8"><style>
  * { margin:0; box-sizing:border-box; }
  html, body { width:${W}px; height:${H}px; overflow:hidden; background:#171310; }
  body { color:#ece5d8; font-family:'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; padding:64px 72px;
         display:flex; flex-direction:column; justify-content:space-between;
         background-image:${contour}; background-size:560px 420px; }
  .eyebrow { color:#b3a892; font-size:24px; letter-spacing:.04em; text-transform:uppercase; }
  .eyebrow::before { content:''; display:inline-block; width:13px; height:13px; border-radius:50%;
                     border:3px solid #e2a85c; margin-right:14px; vertical-align:-2px; }
  h1 { font-size:60px; line-height:1.05; margin-top:14px; }
  .sub { color:#b3a892; font-size:26px; margin-top:16px; max-width:1000px; }
  .stats { display:flex; gap:28px; }
  .stat { flex:1; background:#201a14; border:1px solid rgba(226,168,92,.22);
          border-radius:6px; padding:22px 26px; }
  .stat b { display:block; font-size:44px; font-weight:600; color:#e2a85c; font-variant-numeric:tabular-nums; }
  .stat span { color:#b3a892; font-size:21px; }
</style></head><body>
  <div>
    <div class="eyebrow">wa parcel reconciliation &middot; four counties</div>
    <h1>WA Parcel Reconciliation</h1>
    <div class="sub">Four counties conformed to one schema, then reconciled against the state's own layer</div>
  </div>
  <div class="stats">
    <div class="stat"><b>${records}</b><span>published records</span></div>
    <div class="stat"><b>${agreement}</b><span>of parcels agree with the state layer</span></div>
    <div class="stat"><b>${encroachments}</b><span>boundary encroachments</span></div>
  </div>
</body></html>""")


def fields() -> dict[str, str]:
    """The three headline numbers, read from the scorecard the site itself loads."""
    rows = json.loads((DATA / "agg_scorecard_wide.json").read_text())
    records = sum(int(r["total_records"]) for r in rows)
    agreements = [float(r["pct_agreement"]) for r in rows if r["pct_agreement"] is not None]
    encroachments = sum(int(r["encroachment_pairs"] or 0) for r in rows)
    return {
        "W": str(W), "H": str(H), "contour": CONTOUR,
        # Millions, one decimal: the preview renders about 500 px wide, where a
        # seven-digit number is unreadable.
        "records": f"{records / 1e6:.1f}M",
        "agreement": f"{min(agreements):.0f}-{max(agreements):.0f}%",
        "encroachments": f"{encroachments:,}",
    }


def main() -> int:
    """Render the card and write it to site/og-card.png."""
    chromium = shutil.which("chromium") or shutil.which("chromium-browser") or shutil.which("google-chrome")
    if not chromium:
        print("no Chromium on PATH; the card is rendered by a headless browser", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "card.html"
        page.write_text(CARD.substitute(fields()))
        subprocess.run([chromium, "--headless", "--disable-gpu", "--hide-scrollbars",
                        "--force-device-scale-factor=1", f"--window-size={W},{H}",
                        f"--screenshot={OUT}", page.as_uri()],
                       check=True, capture_output=True, timeout=60)
    print(f"  {OUT.relative_to(ROOT)}  {OUT.stat().st_size:,} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
