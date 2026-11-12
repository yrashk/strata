# KLayout (batch) script: renders a run's layout.
#
#   klayout -b -r asic/render.py -rd in=FILE -rd lyp=FILE -rd out=PREFIX \
#           -rd die=W,H -rd zoom=X0,Y0,X1,Y1 [-rd px=4000]
#           [-rd lyt=FILE -rd map=FILE -rd lefs=A.lef,B.lef]   (for a DEF)
#
# FILE is the final GDS (the macros' and cells' real geometry), or a DEF
# with the LEFs (cell outlines; asic/render.sh uses it for unrouted views).
# Writes PREFIX-full.png (the whole die: the view is exactly the die box,
# so asic/annotate.py can draw on it) and PREFIX-zoom.png (the box in um).
import pya


def arg(name, default=None):
    v = globals().get(name)
    return default if v is None else v


src, lyp, out = arg("in"), arg("lyp"), arg("out")
W, H = (float(v) for v in arg("die").split(","))
zx0, zy0, zx1, zy1 = (float(v) for v in arg("zoom").split(","))
px = int(arg("px", "4000"))

view = pya.LayoutView()
if src.endswith(".gds") or src.endswith(".gds.gz"):
    view.load_layout(src, True)
else:
    tech = pya.Technology()
    tech.load(arg("lyt"))
    opt = tech.load_layout_options
    opt.lefdef_config.map_file = arg("map")
    opt.lefdef_config.macro_resolution_mode = 1
    opt.lefdef_config.read_lef_with_def = False
    opt.lefdef_config.lef_files = arg("lefs").split(",")
    view.load_layout(src, opt, arg("lyt"))
view.load_layer_props(lyp)
view.max_hier()
# only the routing metals, in the site's colours: the cells' PR boundaries
# (0/0), the 5 V marker, wells, implants, Metal1 (the rails and the fill
# cells) cover everything else
SHOW = {"36/0": 0x2f8fd0, "42/0": 0x3fbf7a, "46/0": 0xe0a040, "81/0": 0xc060b0}
it = view.begin_layers()
while not it.at_end():
    lp = it.current()
    ld = f"{lp.source_layer}/{lp.source_datatype}"
    if ld in SHOW:
        lp.fill_color = lp.frame_color = SHOW[ld]
        lp.dither_pattern = 5          # a sparse stipple, so the layers mix
        lp.visible = True
    else:
        lp.visible = False
    view.set_layer_properties(it, lp)
    it.next()
view.set_config("background-color", "#0b0f14")
view.set_config("grid-visible", "false")
view.set_config("text-visible", "false")


def save(box, name, w):
    h = int(round(w * box.height() / box.width()))
    view.save_image_with_options(name, w, h, 0, 1, 0, box, False)


save(pya.DBox(0, 0, W, H), out + "-full.png", px)
save(pya.DBox(zx0, zy0, zx1, zy1), out + "-zoom.png", 2400)
