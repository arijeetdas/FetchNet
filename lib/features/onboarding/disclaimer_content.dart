import 'package:flutter/material.dart';

/// The legal disclaimer, also viewable later from Settings.
class DisclaimerText {
  DisclaimerText._();

  static const sections = [
    (
      'FetchNet is only an interface',
      'FetchNet is a graphical user interface for yt-dlp, an independent open-source command-line program. '
          'FetchNet does not host, store, index, upload or distribute any media. It is not affiliated with, '
          'endorsed by, or connected to yt-dlp or to any website or service whose content can be reached through it.'
    ),
    (
      'No support for unlawful use',
      'FetchNet does not encourage, promote or condone copyright infringement, piracy, circumvention of '
          'technical protection measures, violation of any website\'s terms of service, or any other illegal '
          'or harmful activity.'
    ),
    (
      'You are solely responsible',
      'You alone are responsible for how you use FetchNet and for anything you download with it. Only download '
          'content that you own, that is in the public domain, that is licensed for downloading, or that you have '
          'clear permission from the rights holder to download. Make sure your use complies with copyright law and '
          'every other law and regulation that applies to you, as well as the terms of the services you access.'
    ),
    (
      'No warranty, no liability',
      'FetchNet is provided "as is", without warranty of any kind. The developer accepts no liability for any '
          'misuse of the app, or for any legal claims, damages, data loss, account restrictions or other '
          'consequences arising from its use.'
    ),
    (
      'Third-party content',
      'All videos, music, trademarks and other content remain the property of their respective owners.'
    ),
  ];
}

/// The disclaimer sections as rich text.
class DisclaimerBody extends StatelessWidget {
  const DisclaimerBody({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < DisclaimerText.sections.length; i++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
                child: Text(
                  '${i + 1}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(DisclaimerText.sections[i].$1, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      DisclaimerText.sections[i].$2,
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (i != DisclaimerText.sections.length - 1) const SizedBox(height: 18),
        ],
      ],
    );
  }
}
