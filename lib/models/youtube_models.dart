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
    this.channelAvatar,
    this.subscribers,
    this.views,
    this.published,
    this.description,
    this.related = const [],
    this.relatedContinuation,
  });

  final String id;
  final String title;
  final String? channel;
  final String? channelAvatar;
  final String? subscribers;
  final String? views;
  final String? published;
  final String? description;
  final List<YtVideo> related;
  final String? relatedContinuation;

  String get watchUrl => 'https://www.youtube.com/watch?v=$id';

  String get stats => [views, published].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
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
