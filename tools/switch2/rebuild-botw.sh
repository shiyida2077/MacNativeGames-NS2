#!/bin/sh
# Build the BotW 1.9.0 app from the current checkout (source is the truth; the app is a product of it).
set -e
cd /Volumes/PortableSSD/MacNative/MacNativeGames
python3 build_app.py \
  "/Volumes/PortableSSD/MacNative/resource/塞尔达传说 旷野之息 The Legend of Zelda Breath of the Wild/nsp本体/The Legend of Zelda Breath of the Wild [01007ef00011e000][v0].nsp" \
  --update "/Volumes/PortableSSD/MacNative/resource/塞尔达传说 旷野之息 The Legend of Zelda Breath of the Wild/升级档v1.9.0/The Legend of Zelda Breath of the Wild 1.9.0 [01007EF00011E800][v1114112].nsp" \
  -k "/Volumes/PortableSSD/MacNative/resource/v21.2.0_ProdKeys/prod.keys" \
  --work /Volumes/PortableSSD/MacNative/MacNativeGames-work/botw190 \
  -o "/Volumes/PortableSSD/MacNative/output/Breath of the Wild 1.9.0.app" \
  --platform macos
