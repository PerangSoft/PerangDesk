#!/usr/bin/env bash

echo $MACOS_CODESIGN_IDENTITY
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid
cd flutter; flutter pub get; cd -
~/.cargo/bin/flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
./build.py --flutter
rm perangdesk-$VERSION.dmg
# security find-identity -v
codesign --force --options runtime -s $MACOS_CODESIGN_IDENTITY --deep --strict ./flutter/build/macos/Build/Products/Release/PerangDesk.app -vvv
create-dmg --icon "PerangDesk.app" 200 190 --hide-extension "PerangDesk.app" --window-size 800 400 --app-drop-link 600 185 perangdesk-$VERSION.dmg ./flutter/build/macos/Build/Products/Release/PerangDesk.app
codesign --force --options runtime -s $MACOS_CODESIGN_IDENTITY --deep --strict perangdesk-$VERSION.dmg -vvv
# notarize the perangdesk-${{ env.VERSION }}.dmg
rcodesign notary-submit --api-key-path ~/.p12/api-key.json  --staple perangdesk-$VERSION.dmg
