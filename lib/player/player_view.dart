import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'iptv_player.dart';

enum PictureSize {
  contain('Fit', BoxFit.contain),
  zoom('Zoom', BoxFit.cover),
  stretch('Stretch', BoxFit.fill),
  wide('16:9', BoxFit.contain, 16 / 9),
  classic('4:3', BoxFit.contain, 4 / 3);

  const PictureSize(this.label, this.fit, [this.aspectRatio]);

  final String label;
  final BoxFit fit;
  final double? aspectRatio;
}

/// Video surface with a non-blocking status badge: controls stay usable while
/// buffering or reconnecting.
class IptvPlayerView extends StatelessWidget {
  const IptvPlayerView({
    super.key,
    required this.player,
    this.picture = PictureSize.contain,
  });

  final IptvPlayer player;
  final PictureSize picture;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Video(
          controller: player.video,
          controls: NoVideoControls,
          fit: picture.fit,
          aspectRatio: picture.aspectRatio,
        ),
        Align(
          alignment: Alignment.topRight,
          child: IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: ListenableBuilder(
                listenable: Listenable.merge(
                    [player.buffering, player.notice, player.failed]),
                builder: (context, _) {
                  final buffering = player.buffering.value;
                  final text =
                      player.notice.value ?? (buffering ? 'Buffering…' : null);
                  if (text == null || player.failed.value) {
                    return const SizedBox.shrink();
                  }
                  return _Badge(text: text);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xE60E1116),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(text,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}
