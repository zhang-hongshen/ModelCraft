#!/bin/zsh
# Renders each connector app's AppIcon.icon into ModelCraft/Assets.xcassets/Connectors,
# so the Connectors page shows the real icon even when the app is not on this Mac.
# Expects the connector projects to be checked out next to ModelCraft.
set -euo pipefail

ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
root="${0:A:h:h}"
catalog="$root/ModelCraft/Assets.xcassets/Connectors"
size=64

mkdir -p "$catalog"
cat > "$catalog/Contents.json" <<JSON
{
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "provides-namespace" : true }
}
JSON

for app in Arthub Cellar Keel TuneStudio; do
  icon="$root/../$app/$app/AppIcon.icon"
  imageset="$catalog/$app.imageset"
  rm -rf "$imageset"
  mkdir -p "$imageset"
  for rendition in Default Dark; do
    for scale in 1 2; do
      "$ictool" "$icon" --export-image --output-file "$imageset/$rendition@${scale}x.png" \
        --platform macOS --rendition "$rendition" --width $size --height $size --scale $scale
    done
  done
  cat > "$imageset/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "Default@1x.png", "idiom" : "universal", "scale" : "1x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "Dark@1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "Default@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "Dark@2x.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
  echo "Rendered $app"
done
