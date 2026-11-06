import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';
import '../services/sites_service.dart';

/// A site's icon: a simple glyph for the built-in sites, the saved favicon for
/// user-added ones, and a lettered tile when neither is available.
class SiteIcon extends StatelessWidget {
  const SiteIcon({super.key, required this.site, this.size = 44});

  final Site site;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brand = site.brand;
    if (brand != null) return BrandGlyph(brand: brand, size: size);
    final letter = _LetterTile(name: site.name, size: size);
    final path = site.iconPath;
    if (path == null || !File(path).existsSync()) return letter;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.26),
      child: Container(
        width: size,
        height: size,
        color: Colors.white,
        padding: EdgeInsets.all(size * 0.08),
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => letter,
        ),
      ),
    );
  }
}

class BrandGlyph extends StatelessWidget {
  const BrandGlyph({super.key, required this.brand, this.size = 44});

  final SiteBrand brand;
  final double size;

  static const _youtube = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">'
      '<rect x="1" y="8" width="46" height="32" rx="10" fill="#FF0033"/>'
      '<path d="M19.5 16.4v15.2L32.6 24z" fill="#fff"/></svg>';

  static const _instagram = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><defs>'
      '<radialGradient id="ig" cx="0.28" cy="1.02" r="1.25">'
      '<stop offset="0" stop-color="#FFD776"/><stop offset="0.24" stop-color="#F3A554"/>'
      '<stop offset="0.5" stop-color="#F0434C"/><stop offset="0.76" stop-color="#C13584"/>'
      '<stop offset="1" stop-color="#5B51D8"/></radialGradient></defs>'
      '<rect x="2" y="2" width="44" height="44" rx="13" fill="url(#ig)"/>'
      '<rect x="11.5" y="11.5" width="25" height="25" rx="7.5" fill="none" stroke="#fff" stroke-width="3.2"/>'
      '<circle cx="24" cy="24" r="6" fill="none" stroke="#fff" stroke-width="3.2"/>'
      '<circle cx="31.4" cy="16.6" r="1.9" fill="#fff"/></svg>';

  static const _facebook = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">'
      '<circle cx="24" cy="24" r="22" fill="#0866FF"/>'
      '<path d="M27 45.6V28.2h4.8l.8-5.6H27v-3.4c0-1.6.6-2.6 2.8-2.6h3V11.6c-.8-.1-2.4-.3-4.2-.3'
      '-4.4 0-8 2.6-8 7.3v4h-5v5.6h5v17.4z" fill="#fff"/></svg>';

  static const _x = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">'
      '<rect x="2" y="2" width="44" height="44" rx="12" fill="#000" stroke="#3A3A3A" stroke-width="1"/>'
      '<g transform="translate(10.8 10.8) scale(1.1)"><path fill="#fff" d="M18.901 1.153h3.68l-8.04 9.19L24 '
      '22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 '
      '3.24H4.298Z"/></g></svg>';

  @override
  Widget build(BuildContext context) {
    final svg = switch (brand) {
      SiteBrand.youtube => _youtube,
      SiteBrand.instagram => _instagram,
      SiteBrand.facebook => _facebook,
      SiteBrand.x => _x,
    };
    return SvgPicture.string(svg, width: size, height: size, fit: BoxFit.contain);
  }
}

class _LetterTile extends StatelessWidget {
  const _LetterTile({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(size * 0.26)),
      child: Text(
        letter,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.46),
      ),
    );
  }
}
