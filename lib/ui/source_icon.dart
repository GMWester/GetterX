import 'package:getterx_core/models.dart';
import 'package:material_ui/material_ui.dart';

import 'common.dart';

/// The source's icon (from the store) with a fallback, animated between pages.
class SourceIcon extends StatelessWidget {
  final TrackedSource s;
  final double size;
  const SourceIcon(this.s, {super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: size / 2,
      child: Icon(kindIcon(s.kind), size: size * 0.5),
    );
    final url = s.iconUrl;
    return Hero(
      tag: 'icon-${s.id}',
      child: SizedBox(
        width: size,
        height: size,
        child: url == null || url.isEmpty || !url.startsWith('https://')
            ? fallback
            : ClipRRect(
                borderRadius: BorderRadius.circular(size * 0.25),
                child: Image.network(
                  url,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                ),
              ),
      ),
    );
  }
}
