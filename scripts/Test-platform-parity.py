"""Offline provider-script and generated pet-art parity checks runnable on Windows and macOS.

These compare the same embedded scripts as RelayMacTests; native suites remain
responsible for behavior in each browser engine.
"""
import difflib
import json
import pathlib
import re
import unittest
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAIRS = [
    ("Messenger unread", "UnreadDetection.cs", "MessengerUnreadScript", "MessengerUnread.swift", "script"),
    ("Gmail unread", "UnreadDetection.cs", "GmailUnreadScript", "UnreadModels.swift", "script"),
    ("WhatsApp theme", "WhatsAppChrome.cs", "WhatsAppChromeScript", "WhatsAppChrome.swift", "script"),
    ("Messenger layout", "MessengerChrome.cs", "MessengerChromeScript", "MessengerChrome.swift", "script"),
    ("Media controls", "MediaControls.cs", "MediaBridgeScript", "MediaBridge.swift", "template"),
]


def extract(path, name, swift=False):
    source = path.read_text(encoding="utf-8")
    pattern = (r"static let " if swift else r"private const string ") + re.escape(name)
    pattern += r'\s*=\s*#?"""\n(.*?)\n\s*"""'
    match = re.search(pattern, source, re.DOTALL)
    if not match:
        raise ValueError(f"Missing script {name} in {path}")
    return [line.strip() for line in match[1].splitlines() if line.strip()]


class PlatformParityChecks(unittest.TestCase):
    def test_pet_artwork_is_generated_from_shared_source(self):
        subprocess.run([sys.executable, str(ROOT / "scripts/Generate-pet-art.py"), "--check"], check=True)

    def test_walking_keeps_four_visible_paws(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        original_layers = art["layers"]
        for kind in ["puke", "roof"]:
            art["layers"] = {name: original_layers.get("roof" + name[0].upper() + name[1:], layer) if kind == "roof" else layer
                             for name, layer in original_layers.items()}
            legs = ["backHind", "backFront", "hind", "front"]
            # Composite in native paint order, including clothes and the torso that
            # previously covered the far paws in a crossing frame.
            for frame, feet in enumerate(art["gait"]):
                for hoodie in [False, True]:
                    canvas = {}
                    for name in ["backHind", "backFront", "body"] + (["hoodie"] if hoodie else []) + ["hind", "front", "head"]:
                        layer = art["layers"][name]
                        dx, dy = feet[legs.index(name)] if name in legs else (0, 0)
                        for y, row in enumerate(layer["rows"]):
                            for x, color in enumerate(row):
                                if color != ".": canvas[(layer["x"]+x+dx, layer["y"]+y+dy)] = (name, color)
                    for leg in legs:
                        with self.subTest(frame=frame, hoodie=hoodie, leg=leg):
                            self.assertTrue(any(y >= 26 and owner == leg and color == "C" for (x,y),(owner,color) in canvas.items()), "Paw is hidden by another layer")


    def test_walking_paws_push_back_and_recover_forward(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        cycle = art["gait"][1:]
        # In the right-facing sprite, planted paws push toward the tail;
        # lifted paws recover toward the head. Mirroring reverses both.
        for leg in range(4):
            for facing in [-1, 1]:
                for phase, frame in enumerate(cycle):
                    x, y = frame[leg]
                    nx, ny = cycle[(phase+1) % len(cycle)][leg]
                    screen_step = (nx-x) * facing
                    with self.subTest(leg=leg, facing=facing, phase=phase):
                        if y == 0 and ny == 0:
                            self.assertLess(screen_step * facing, 0, "Planted paw must push against travel")
                        else:
                            self.assertGreater(screen_step * facing, 0, "Lifted paw must recover toward travel")

    def test_seated_wave_keeps_arm_and_paw_connected(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        original_layers = art["layers"]
        for kind in ["puke", "roof"]:
            art["layers"] = {name: original_layers.get("roof" + name[0].upper() + name[1:], layer) if kind == "roof" else layer
                             for name, layer in original_layers.items()}
            def pixels(name, dx=0, dy=0):
                layer = art["layers"][name]
                return {(layer["x"] + x + dx, layer["y"] + y + dy)
                        for y, row in enumerate(layer["rows"]) for x, color in enumerate(row) if color != "."}
            def touches(first, second):
                return any((x + dx, y + dy) in second for x, y in first
                           for dx, dy in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)])
            for offset in [-1, 0, 1]:
                arm = pixels("raisedFront", dx=-4 + offset)
                paw = pixels("paw", dx=-2 + offset, dy=-2)
                with self.subTest(offset=offset):
                    self.assertTrue(touches(arm, pixels("sitBody")), "Waving arm detached from the seated body")
                    self.assertTrue(touches(paw, arm), "Waving paw detached from the arm")
                    self.assertTrue(all(0 <= x < art["width"] and 0 <= y < art["height"] for x, y in arm | paw))


    def test_resting_heads_remain_connected_during_settling_and_glances(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        original_layers = art["layers"]
        for kind in ["puke", "roof"]:
            art["layers"] = {name: original_layers.get("roof" + name[0].upper() + name[1:], layer) if kind == "roof" else layer
                             for name, layer in original_layers.items()}
            def pixels(name, dx=0, dy=0):
                layer = art["layers"][name]
                return {(layer["x"] + x + dx, layer["y"] + y + dy)
                        for y, row in enumerate(layer["rows"]) for x, color in enumerate(row) if color != "."}
            for style, (body, head_x, head_y) in enumerate([
                    ("sleepBody", -5, 8), ("sleepBody", -2, 9), ("loafBody", -3, 5), ("sitBody", -4, 3)]):
                for step in range(13):
                    progress = step / 12
                    torso = pixels("sitBody" if progress < 0.5 else body)
                    for glance in [-1, 0, 1]:
                        # Native renderers round half away from zero.
                        dx = -int(4 - (head_x + 4) * progress + 0.5) + glance
                        dy = int(head_y * progress + 0.5) - (1 if glance else 0)
                        head = pixels("head", dx, dy)
                        with self.subTest(style=style, step=step, glance=glance):
                            self.assertTrue(any((x + ox, y + oy) in torso for x, y in head
                                                for ox, oy in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)]), "Settling detached the head")
                            self.assertTrue(all(0 <= x < art["width"] and 0 <= y < art["height"] for x, y in head | torso))


    def test_box_rim_hides_paws_but_keeps_the_face_visible(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        original_layers = art["layers"]
        for kind in ["puke", "roof"]:
            art["layers"] = {name: original_layers.get("roof" + name[0].upper() + name[1:], layer) if kind == "roof" else layer
                             for name, layer in original_layers.items()}
            for progress in [0, 0.5, 1]:
                canvas = {}
                crouch = int(6 * progress + 0.5)
                head_y = crouch - int(4 * progress + 0.5)
                for name, dx, dy in [("boxBack", 0, 0), ("sitBody", 0, crouch), ("sitFront", 0, crouch),
                                     ("head", -4, head_y), ("eyes", -4, head_y), ("nose", -4, head_y), ("boxFront", 0, 0)]:
                    layer = art["layers"][name]
                    for y, row in enumerate(layer["rows"]):
                        for x, color in enumerate(row):
                            px, py = layer["x"] + x + dx, layer["y"] + y + dy
                            if color != "." and 0 <= py < 32: canvas[(px, py)] = name
                with self.subTest(progress=progress):
                    self.assertNotIn("sitFront", canvas.values(), "Paws should be inside the box")
                    self.assertIn("eyes", canvas.values(), "Puke should peek over the front rim")
                    self.assertIn("nose", canvas.values(), "The box must not cover Puke's whole face")


    def test_rock_eyes_remain_visible_above_the_box(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        canvas = {}
        for name in ["boxBack", "rockBody", "rockEyes", "boxFront"]:
            layer = art["layers"][name]
            for y, row in enumerate(layer["rows"]):
                for x, color in enumerate(row):
                    if color != ".": canvas[(layer["x"] + x, layer["y"] + y)] = (name, color)
        self.assertTrue(any(owner == "rockEyes" and color == "C" for owner, color in canvas.values()), "The box swallowed Rock's eyes")

    def test_digging_paws_and_head_stay_connected(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        def pixels(name, dx=0, dy=0):
            layer = art["layers"][name]
            return {(layer["x"] + x + dx, layer["y"] + y + dy)
                    for y, row in enumerate(layer["rows"]) for x, color in enumerate(row) if color != "."}
        body = pixels("roofBody")
        for stroke in [-1, 0, 1]:
            for part in [pixels("roofHead", dy=3), pixels("roofFront", dx=-stroke, dy=min(0, stroke)),
                         pixels("roofBackFront", dx=stroke, dy=-max(0, stroke))]:
                self.assertTrue(any((x + dx, y + dy) in body for x, y in part
                                    for dx, dy in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)]), "Digging detached a paw or the head")
                self.assertTrue(all(0 <= x < art["width"] and 0 <= y < art["height"] for x, y in part))

    def test_wardrobe_fits_active_and_sleeping_silhouettes(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        def pixels(name, dx=0, dy=0):
            layer = art["layers"][name]
            return {(layer["x"] + x + dx, layer["y"] + y + dy)
                    for y, row in enumerate(layer["rows"]) for x, color in enumerate(row) if color != "."}
        poses = [("standing", "body", 0, 0), ("sitting", "sitBody", -4, 0),
                 ("stretching", "stretchBody", 0, 5), ("curl", "sleepBody", -5, 8),
                 ("chin", "sleepBody", -2, 9), ("loaf", "loafBody", -3, 5), ("perch", "sitBody", -4, 3)]
        self.assertEqual(set(art["wardrobe"]), {pose for pose, *_ in poses})
        for kind in ["puke", "roof"]:
            def name(base): return "roof" + base[0].upper() + base[1:] if kind == "roof" else base
            for pose, body, hx, hy in poses:
                torso = pixels(name(body))
                silhouette = torso | pixels(name("head"), hx, hy)
                bandana, hoodie = (pixels(name(layer)) for layer in art["wardrobe"][pose])
                with self.subTest(kind=kind, pose=pose):
                    self.assertGreater(len(bandana), 10)
                    self.assertFalse(bandana - silhouette, "Neckwear floats outside the pet")
                    self.assertGreater(len(hoodie), 70)
                    self.assertFalse(hoodie - torso, "Garment spills past the torso")
        self.assertFalse(pixels("rockBandana") - pixels("rockBody"), "Rock's bandana extends beyond its sides")
        self.assertFalse(pixels("rockShades") - pixels("rockBody"), "Rock's glasses float past its face")
        for prefix in ["", "roof"]:
            name = lambda part: prefix + part[0].upper() + part[1:] if prefix else part
            self.assertFalse(pixels(name("shades")) - pixels(name("head")), "Glasses overhang the face")

    def test_grooming_paw_stays_attached_in_both_frames(self):
        art = json.loads((ROOT / "Assets/Pet/Puke.json").read_text(encoding="utf-8"))
        def pixels(name, dx=0, dy=0):
            layer = art["layers"][name]
            return {(layer["x"] + x + dx, layer["y"] + y + dy)
                    for y, row in enumerate(layer["rows"]) for x, color in enumerate(row) if color != "."}
        body = pixels("sitBody")
        for dy in [0, -4]:
            paw = pixels("groomPaw", 1, dy)
            self.assertTrue(paw & body, "Grooming paw detached from the seated shoulder")
            self.assertTrue(all(0 <= x < art["width"] and 0 <= y < art["height"] for x, y in paw))

    def test_provider_scripts_match(self):
        for label, windows, constant, mac, field in PAIRS:
            with self.subTest(provider=label):
                left = extract(ROOT / "windows/Sources/Relay" / windows, constant)
                right = extract(ROOT / "macos/Sources/RelayMac" / mac, field, swift=True)
                self.assertEqual(left, right, "\n".join(difflib.unified_diff(
                    left, right, fromfile=windows, tofile=mac, lineterm="")))


if __name__ == "__main__":
    unittest.main()
