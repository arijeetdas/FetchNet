import '../models/media_info.dart';

/// Audio formats FFmpeg alone can put a picture into (no extra Python
/// modules needed on any platform).
const _coverFormats = {'mp3', 'm4a'};

/// Crops the thumbnail to a centred square: YouTube Music serves album art
/// as a 16:9 image with the square cover in the middle.
const _squareCrop =
    'ThumbnailsConvertor+FFmpeg_o:-c:v mjpeg -vf crop="\'if(gt(ih,iw),iw,ih)\':\'if(gt(iw,ih),ih,iw)\'"';

/// yt-dlp arguments that embed cover art in a YouTube audio download, per
/// the YouTube Settings: [music] for music.youtube.com links (square album
/// cover), [video] for other YouTube videos (the thumbnail as it is).
List<String> coverArtArgs(
  MediaInfo info,
  DownloadOption option, {
  required bool ffmpeg,
  required bool music,
  required bool video,
}) {
  if (!ffmpeg || option.kind != MediaKind.audio || !info.isYouTube) return const [];
  if (!_coverFormats.contains(option.extension)) return const [];
  final isMusic = info.isYouTubeMusic;
  if (isMusic ? !music : !video) return const [];
  return [
    '--embed-thumbnail',
    '--convert-thumbnails',
    'jpg',
    if (isMusic) ...['--postprocessor-args', _squareCrop],
  ];
}
