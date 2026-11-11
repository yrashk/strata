# KLayout (batch) script: renders the final GDS of a run.
#
#   klayout -b -r asic/render.py -rd gds=FILE -rd lyp=FILE -rd out=PREFIX \
#           -rd die=W,H -rd zoom=X0,Y0,X1,Y1 [-rd px=4000]
#
# Writes PREFIX-full.png (the whole die, the view exactly the die box so
# asic/annotate.py can draw on it) and PREFIX-zoom.png (the box in um).
import pya

gds, lyp, out = gds, lyp, out        # noqa: F821  (given with -rd)
W, H = (float(v) for v in die.split(","))          # noqa: F821
zx0, zy0, zx1, zy1 = (float(v) for v in zoom.split(","))  # noqa: F821
try:
    px = int(px)                       # noqa: F821
except NameError:
    px = 4000

view = pya.LayoutView()
view.load_layout(gds, True)
view.load_layer_props(lyp)
view.max_hier()
view.set_config("background-color", "#0b0f14")
view.set_config("grid-visible", "false")
view.set_config("text-visible", "false")
view.set_config("bitmap-oversampling", "1")


def save(box, name, w):
    h = int(round(w * box.height() / box.width()))
    view.save_image_with_options(name, w, h, 0, 1, 0, box, False)


save(pya.DBox(0, 0, W, H), out + "-full.png", px)
save(pya.DBox(zx0, zy0, zx1, zy1), out + "-zoom.png", 2400)
