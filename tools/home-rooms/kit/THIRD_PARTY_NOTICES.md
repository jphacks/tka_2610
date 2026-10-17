# Third-party notices

## Three.js r140 / MIT

`vendor/three-r140.bundle.js`, and its inline copy inside `OPEN_ME.html`, contain Three.js r140 and corresponding example loader/control code. The copyright header in the bundle is retained. The offline reference preview uses this bundled version; the reusable kit implementation receives the host application's Three.js as an injected dependency.

The bundle was obtained from the existing trimesh viewer template distribution in the authoring environment. No trimesh Python package is redistributed. No external 3D models or texture photographs are included.

Copyright 2010-2022 Three.js Authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to
do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Authoring/test dependencies, not bundled

The optional Python build scripts use NumPy, Pillow and Shapely. Browser QA uses Playwright and Chromium. These dependencies are installed separately and retain their own licenses. Blender is optional and is not shipped or required for viewing.

## First-party kit contents

The generated meshes, texture pixels, layouts, kit/editor/exporter source and documentation were created for this project and supplied for the recipient to use and modify in their application. There is no additional attribution requirement from this deliverable for those first-party files. Keep the above Three.js notice when redistributing the bundled viewer. This is not a warranty or a statement of legal clearance for user-supplied future artwork.

No fonts, Animal Crossing game assets, proprietary Unity assets, analytics trackers, remote model-generation clients, or API keys are bundled.
