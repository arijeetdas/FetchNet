import 'package:flutter/material.dart';

import '../models/media_info.dart';

/// Icon shown for a download of [kind].
IconData kindIcon(MediaKind kind) => switch (kind) {
      MediaKind.video => Icons.movie_rounded,
      MediaKind.audio => Icons.music_note_rounded,
      MediaKind.thumbnail => Icons.image_rounded,
    };
