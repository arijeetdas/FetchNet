/// A video card in FetchNet's YouTube view.
class YtVideo {
  const YtVideo({
    required this.id,
    required this.title,
    required this.thumbnail,
    this.channel,
    this.channelAvatar,
    this.views,
    this.published,
    this.duration,
    this.isLive = false,
    this.isShort = false,
  });

  final String id;
  final String title;
  final String thumbnail;
  final String? channel;
  final String? channelAvatar;

  /// Already formatted by YouTube, e.g. `1.2M views`.
  final String? views;

  /// e.g. `3 days ago`.
  final String? published;

  /// e.g. `12:34`.
  final String? duration;
  final bool isLive;
  final bool isShort;

  String get watchUrl => isShort ? 'https://www.youtube.com/shorts/$id' : 'https://www.youtube.com/watch?v=$id';

  /// `1.2M views · 3 days ago`
  String get stats => [views, published].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
}

/// One page of a feed plus the token for the next page.
class YtPage {
  const YtPage({required this.items, this.continuation});

  final List<YtVideo> items;
  final String? continuation;
}

/// Everything the watch page shows.
class YtWatchInfo {
  const YtWatchInfo({
    required this.id,
    required this.title,
    this.channel,
    this.channelId,
    this.channelAvatar,
    this.subscribers,
    this.subscribed,
    this.views,
    this.published,
    this.likes,
    this.description,
    this.related = const [],
    this.relatedContinuation,
  });

  final String id;
  final String title;
  final String? channel;

  /// `UC…` id, needed to subscribe and to open the channel.
  final String? channelId;
  final String? channelAvatar;
  final String? subscribers;

  /// Whether the signed-in account follows the channel (`null`: unknown).
  final bool? subscribed;
  final String? views;
  final String? published;

  /// e.g. `12K`.
  final String? likes;
  final String? description;
  final List<YtVideo> related;
  final String? relatedContinuation;

  String get watchUrl => 'https://www.youtube.com/watch?v=$id';

  String get stats => [views, published].whereType<String>().where((e) => e.isNotEmpty).join(' · ');

  YtWatchInfo copyWith({bool? subscribed, String? subscribers}) => YtWatchInfo(
        id: id,
        title: title,
        channel: channel,
        channelId: channelId,
        channelAvatar: channelAvatar,
        subscribers: subscribers ?? this.subscribers,
        subscribed: subscribed ?? this.subscribed,
        views: views,
        published: published,
        likes: likes,
        description: description,
        related: related,
        relatedContinuation: relatedContinuation,
      );
}

/// A channel the account follows, or the header of a channel page.
class YtChannel {
  const YtChannel({
    required this.id,
    required this.name,
    this.avatar,
    this.subscribers,
    this.handle,
    this.banner,
    this.subscribed,
  });

  final String id;
  final String name;
  final String? avatar;
  final String? subscribers;

  /// `@handle`.
  final String? handle;
  final String? banner;
  final bool? subscribed;

  String get url => 'https://www.youtube.com/channel/$id';
}

/// A channel page: header, uploads and where to find its posts.
class YtChannelPage {
  const YtChannelPage({required this.channel, required this.videos, this.postsParams});

  final YtChannel channel;
  final YtPage videos;

  /// Browse params of the Posts tab, when the channel has one.
  final String? postsParams;
}

/// A community post.
class YtPost {
  const YtPost({
    required this.id,
    required this.author,
    this.authorAvatar,
    this.channelId,
    this.text,
    this.published,
    this.likes,
    this.images = const [],
    this.video,
  });

  final String id;
  final String author;
  final String? authorAvatar;
  final String? channelId;
  final String? text;

  /// e.g. `2 days ago`.
  final String? published;
  final String? likes;
  final List<String> images;

  /// A video attached to the post.
  final YtVideo? video;

  /// Rough age, for sorting posts of several channels together.
  Duration get age => parseRelativeAge(published);
}

/// `3 days ago` → 3 days. Unknown text sorts last.
Duration parseRelativeAge(String? text) {
  if (text == null) return const Duration(days: 99999);
  final m = RegExp(r'(\d+)\s*(second|minute|hour|day|week|month|year)').firstMatch(text.toLowerCase());
  if (m == null) return const Duration(days: 99999);
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)) {
    'second' => Duration(seconds: n),
    'minute' => Duration(minutes: n),
    'hour' => Duration(hours: n),
    'day' => Duration(days: n),
    'week' => Duration(days: 7 * n),
    'month' => Duration(days: 30 * n),
    _ => Duration(days: 365 * n),
  };
}

/// The signed-in Google account.
class GoogleProfile {
  const GoogleProfile({required this.name, this.email, this.avatarUrl});

  final String name;
  final String? email;
  final String? avatarUrl;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (email != null) 'email': email,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
      };

  static GoogleProfile? fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    if (name is! String || name.isEmpty) return null;
    return GoogleProfile(name: name, email: j['email'] as String?, avatarUrl: j['avatarUrl'] as String?);
  }
}

class YtException implements Exception {
  const YtException(this.message);

  final String message;

  @override
  String toString() => message;
}
