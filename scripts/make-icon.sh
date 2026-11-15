#!/bin/sh
# Renders Config/Icon/AppIcon.svg into the app's asset catalog (Dash/Assets.xcassets/AppIcon).
# Needs rsvg-convert (brew install librsvg). Run it again after changing the SVG.
set -eu
cd "$(dirname "$0")/.."
svg=Config/Icon/AppIcon.svg
set_dir=Dash/Assets.xcassets/AppIcon.appiconset
mkdir -p "$set_dir"
cat > Dash/Assets.xcassets/Contents.json <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON

images=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    name="icon_${size}x${size}"
    [ "$scale" = 2 ] && name="${name}@2x"
    rsvg-convert -w "$pixels" -h "$pixels" "$svg" -o "$set_dir/$name.png"
    images="$images{ \"idiom\" : \"mac\", \"size\" : \"${size}x${size}\", \"scale\" : \"${scale}x\", \"filename\" : \"$name.png\" },"
  done
done
printf '{ "images" : [ %s ], "info" : { "author" : "xcode", "version" : 1 } }\n' "${images%,}" > "$set_dir/Contents.json"
echo "Wrote $set_dir"
