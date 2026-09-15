# Third-party notices

## GhosttyKit

Web Studio links the official GhosttyKit core v1.3.1 at commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`, built with Zig 0.15.2. The core is
used through the pinned C embedding API and is distributed under the MIT
License. Source: https://github.com/ghostty-org/ghostty

The build recipe records the source revision, Zig archive checksum and resource
copy step. GhosttyKit is the terminal core only; Web Studio's session, pane and
Agent-resource ownership remains application code. cmux was used as an
architectural reference; no cmux source is included.

The upstream `LICENSE` file is copied into `Vendor/ghostty/LICENSE` and the
runtime resource folder is bundled as `Contents/Resources/ghostty`. The final
release inventory still needs a license review for Ghostty's native dependency
archives (including glslang, SPIRV-Cross, libintl and ImGui) before publishing.

## SwiftTerm

Web Studio links the native SwiftTerm library through Swift Package Manager, pinned to version 1.14.0 (commit `849e8a4f3d6f79ddee07152400137f1370c32621`).

Source: https://github.com/migueldeicaza/SwiftTerm

Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
