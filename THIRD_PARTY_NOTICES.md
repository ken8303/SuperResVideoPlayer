# Third-party software notices

SuperResVideoPlayer binary distributions include unmodified Homebrew-built
copies of mpv/libmpv, FFmpeg, and their dynamically linked dependencies.
Those components remain the property of their respective authors and are
distributed under their own licenses.

SuperResVideoPlayer itself is licensed under the GNU General Public License,
version 3 or (at your option) any later version. Its license text is included
in the application bundle and in the public source repository linked below.

The Homebrew FFmpeg build used by `make-dist.sh` is GPL-enabled. The exact
versions and build configuration can be inspected from a packaged app with:

```sh
SuperResVideoPlayer.app/Contents/Helpers/ffmpeg -version
SuperResVideoPlayer.app/Contents/Helpers/ffmpeg -buildconf
```

Project and source locations:

- mpv: https://mpv.io and https://github.com/mpv-player/mpv
- FFmpeg: https://ffmpeg.org and https://ffmpeg.org/download.html
- Homebrew build recipes: https://github.com/Homebrew/homebrew-core
- SuperResVideoPlayer source: https://github.com/ken8303/SuperResVideoPlayer

The exact formula versions, declared licenses, source URLs, and source checksums
are listed in `Contents/Resources/Licenses/Homebrew-Formulae.tsv`. License and
notice files installed by those formulae are included beside the manifest when
available. Anyone publishing a binary release
must also make the complete corresponding source for the exact distributed
build available as required by the applicable licenses. Upstream download
links alone may not represent Homebrew patches or this application's source
state, so release source archives should be published alongside the binary.

This notice is informational and is not a substitute for legal advice or for
the terms in the included license files.
