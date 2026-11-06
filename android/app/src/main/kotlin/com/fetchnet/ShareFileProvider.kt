package com.fetchnet

import androidx.core.content.FileProvider

/**
 * FetchNet's own FileProvider subclass (paths in res/xml/share_paths.xml), so
 * it never clashes with a provider declared by a plugin.
 */
class ShareFileProvider : FileProvider()
