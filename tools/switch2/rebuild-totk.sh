#!/bin/sh
# Build the TotK 1.4.3 app from the current checkout (source is the truth; the app is a product of it).
set -e
cd /Volumes/PortableSSD/MacNative/MacNativeGames
python3 build_app.py \
  "/Volumes/PortableSSD/MacNative/resource/塞尔达传说 王国之泪 The Legend of Zelda Tears of the Kingdom/nsp本体/薩爾達傳說 王國之淚 - v1.0.0 [0100F2C0115B6000][v0].nsp" \
  --update "/Volumes/PortableSSD/MacNative/resource/塞尔达传说 王国之泪 The Legend of Zelda Tears of the Kingdom/升级档v1.4.3（需要21以上固件）/The Legend of Zelda Tears of the Kingdom v1.4.3 [0100F2C0115B6800][v720896][UPD].nsp" \
  -k "/Volumes/PortableSSD/MacNative/resource/v21.2.0_ProdKeys/prod.keys" \
  --work /Volumes/PortableSSD/MacNative/MacNativeGames-work/totk143 \
  -o "/Volumes/PortableSSD/MacNative/output/Tears of the Kingdom 1.4.3.app" \
  --platform macos
