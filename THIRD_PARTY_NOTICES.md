# Third-Party Notices

YTKACE source is licensed under MIT. The following components and services have separate terms.

## FFmpeg

YTKACE statically links FFmpeg 8.1.2 for local media processing. It is built from the official release tarball by `Scripts/build-ffmpeg.sh`, without `--enable-gpl` and without `--enable-nonfree`, so the result is LGPL only. Licence texts ship in the repository at `Vendor/FFmpeg/COPYING.LGPLv2.1` and `COPYING.LGPLv3`. See https://ffmpeg.org/legal.html.

## SponsorBlock and DeArrow

SponsorBlock and DeArrow community data is provided by the SponsorBlock service under CC BY-NC-SA 4.0. See https://sponsor.ajay.app/. The shield image shipped in `YTKACE.bundle` is SponsorBlock's artwork, taken from the same site and used to mark the integration.

## SABR reference

The download path implements YouTube's SABR streaming protocol. It was written for YTKACE, developed against an iPad on iOS 16. Protocol understanding came in part from reading [LuanRT/googlevideo](https://github.com/LuanRT/googlevideo), an MIT-licensed library implementing UMP and SABR. No code from that project is included.

## YTPlaybackFix

The InnerTube client spoofing in `Tweak/Features/Playback/PlaybackClientSpoof.mm` is adapted from [YTPlaybackFix](https://github.com/Mark02-2012/YTPlaybackFix) by Mark02, used under the MIT licence. The implementation was reworked for YTKACE: it is ported off Logos to the runtime hooking used elsewhere here, gated behind the Playback Fix preference, restricted to the `/player`, `/initplayback` and `/videoplayback` endpoints, and rewrites the request body from `setHTTPBody:` rather than the initialiser. The full licence text is reproduced in the header of that file.

MIT License, Copyright (c) 2026 Mark02.

## Apple frameworks

YTKACE uses UIKit, AVFoundation and SF Symbols supplied by iOS. SF Symbols artwork is requested at runtime and is not included as a redistributed asset pack.
