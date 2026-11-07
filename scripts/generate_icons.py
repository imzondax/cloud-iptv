"""Regenerates every app icon from Logo/Cloud_IPTV_Logo_Vector.svg.

Run from the project root: python scripts/generate_icons.py
Needs Pillow and Microsoft Edge, which rasterises the SVG.
"""
import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw

SVG = pathlib.Path('Logo/Cloud_IPTV_Logo_Vector.svg').resolve()
EDGE = r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
GROUND = (0x0E, 0x11, 0x16, 255)  # OnAir.ground
WHITE = (255, 255, 255, 255)
RENDER = 2048


def render_cloud():
    """The logo without its margins, on transparency."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        page = tmp / 'render.html'
        page.write_text(
            '<!doctype html><body style="margin:0;background:transparent">'
            f'<img src="{SVG.as_uri()}" width="{RENDER}" height="{RENDER}" '
            'style="display:block">')
        shot = tmp / 'logo.png'
        subprocess.run([
            EDGE, '--headless', '--disable-gpu', '--hide-scrollbars',
            '--force-device-scale-factor=1',
            '--default-background-color=00000000',
            f'--window-size={RENDER},{RENDER}',
            f'--user-data-dir={tmp / "profile"}',
            f'--screenshot={shot}', page.as_uri(),
        ], check=True, capture_output=True)
        image = Image.open(shot).convert('RGBA')
        return image.crop(image.getchannel('A').getbbox())


def place(cloud, size, width, background=(0, 0, 0, 0)):
    """[cloud] centred on a [size] canvas, [width] of the canvas wide."""
    w, h = size
    target = round(w * width)
    scaled = cloud.resize((target, round(target * cloud.height / cloud.width)),
                          Image.LANCZOS)
    canvas = Image.new('RGBA', size, background)
    canvas.alpha_composite(
        scaled, ((w - scaled.width) // 2, (h - scaled.height) // 2))
    return canvas


def main():
    cloud = render_cloud()

    place(cloud, (256, 256), 1.0).save('assets/logo.png')

    place(cloud, (256, 256), 0.94).save(
        'windows/runner/resources/app_icon.ico',
        sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)],
        # Not every Windows code path reads PNG frames at small sizes.
        bitmap_format='bmp')
    # Inno Setup wants a flat BMP, shown on the wizard's white header.
    place(cloud, (110, 116), 0.86, WHITE).convert('RGB').save(
        'windows/runner/resources/installer_small.bmp')

    res = pathlib.Path('android/app/src/main/res')
    for density, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2),
                           ('xxhdpi', 3), ('xxxhdpi', 4)]:
        folder = res / f'mipmap-{density}'
        side = round(48 * scale)
        icon = Image.new('RGBA', (side, side))
        ImageDraw.Draw(icon).rounded_rectangle(
            (0, 0, side - 1, side - 1), radius=side // 5, fill=GROUND)
        icon.alpha_composite(place(cloud, (side, side), 0.72))
        icon.save(folder / 'ic_launcher.png')
        # Adaptive icons are 108dp, with only the middle 66dp always visible.
        side = round(108 * scale)
        place(cloud, (side, side), 0.54).save(
            folder / 'ic_launcher_foreground.png')

    # The App Store rejects icons with transparency.
    icons = pathlib.Path('ios/Runner/Assets.xcassets/AppIcon.appiconset')
    for file in icons.glob('*.png'):
        size = Image.open(file).size
        place(cloud, size, 0.7, GROUND).convert('RGB').save(file)


main()
