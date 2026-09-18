"""Render DLG Poker's real paint output into the README's screenshots.

    python3 harness/render.py      # writes docs/screenshots/*.png

Plays a scripted game through the real core.lua/screen.lua (harness/
render.lua), records every lcd call as SVG, then rasterises each SVG at
2x with headless Chrome. Needs `pip3 install lupa` and Google Chrome.
"""
import glob, os, shutil, subprocess, tempfile
import lupa

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "PokerTimer")
out = os.path.join(here, "..", "docs", "screenshots")
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
os.makedirs(out, exist_ok=True)

run = tempfile.mkdtemp(prefix="dlgpoker_render_")
os.mkdir(os.path.join(run, "Files"))
for f in ["core.lua", "draw.lua", "screen.lua", "config.lua"]:
    shutil.copy(os.path.join(src, f), run)
shutil.copy(os.path.join(here, "render.lua"), run)
os.chdir(run)
lupa.LuaRuntime(unpack_returned_tuples=True).execute(open("render.lua", encoding="utf-8").read())

for svg in sorted(glob.glob("out_*.svg")):
    name = os.path.basename(svg)[4:-4]
    png = os.path.join(out, name + ".png")
    subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", "--window-size=640,316",
                    "--screenshot=" + png, "file://" + os.path.join(run, svg)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("wrote", os.path.relpath(png, os.path.join(here, "..")))
