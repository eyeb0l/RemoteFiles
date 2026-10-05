# App icon

The selected linked-folder concept is shipped as `App/AppIcon.icon`, a native Icon Composer document. Its transparent foreground is generated from `design/icon-options/linked-folder.png`; the final image-generation prompt is saved in `design/app-icon-previews/prompt.md`.

The default background is indigo and the Dark background is neutral and darker. The system renders Light, Dark, Tinted Light, Tinted Dark, Clear Light and Clear Dark from the same document. Auto uses the appropriate Light or Dark appearance. The Mono specialization (`tinted`) covers both Tinted and Clear appearances. Glass effects are enabled for Mono; extra base shading and shadows are disabled because the foreground already includes dimensional shading.

The app target includes the document in its resources and sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. The test host does not use the icon. Keep this integration in `scripts/generate-project.py` when regenerating the project.

Apple references: [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) and [app icon configuration](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).

## Appearance previews

`design/app-icon-previews/index.html` shows all six native renditions exported using Xcode 27's Icon Composer renderer. These are reference previews; runtime Tinted colours and Clear backgrounds adapt to the user's appearance and wallpaper.

To export a rendition on a Mac with Xcode installed:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  App/AppIcon.icon --export-image --output-file /private/tmp/RemoteFiles-ClearLight.png \
  --platform iOS --rendition ClearLight --width 512 --height 512 --scale 1 \
  --design-generation 27
```

Other rendition names are `Default`, `Dark`, `TintedLight`, `TintedDark` and `ClearDark`.

## Verification — 5 October 2026

- Xcode 27.0 / iOS 27.0 Simulator build and unsigned generic iPhone build succeeded.
- All six Icon Composer renditions were exported and inspected at 512 px and 32 px. The final default rendition was also inspected at 1024 px.
- The device build's compiled asset catalog contains iPhone and iPad icon images plus Light, Dark and Mono icon stacks.
- The installed icon was visually checked on the Simulator Home Screen. [Screenshot](screenshots/icon-home/installed-icon-iphone.jpg).
- The compact app home was checked in [Light](screenshots/icon-home/home-compact-light.jpg), [Dark](screenshots/icon-home/home-compact-dark.jpg) and [largest accessibility text](screenshots/icon-home/home-accessibility-largest-dark.jpg). Simulator settings were restored after inspection.
- Existing setup and browse/read/refresh UI tests both passed: `testNormalLaunchOffersUsableConnectionSetup` and `testBrowseReadRefreshAndReturn` (2 passed, 0 failed, 0 skipped).

Physical-device installation and Home Screen appearance switching were not performed for this change. Tinted and Clear verification used the native renderer; wallpaper-dependent runtime effects can differ from the saved previews.
