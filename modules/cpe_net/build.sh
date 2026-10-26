#!/usr/bin/env bash
###############################################################################
# 编译 TetherCtl.java -> tetherctl.dex
#
# 依赖：
#   - java（JDK 8+，只用来跑 ecj / d8）
#   - ANDROID_JAR：Android SDK 的 android.jar（本例用 platform 36）
#   - D8_JAR：build-tools 里的 d8.jar
#
# 注意：build-tools r34 的 d8 需要 Java 11+；r30 的 d8 在 Java 8 上也能跑。
###############################################################################
set -euo pipefail

cd "$(dirname "$0")"

: "${ANDROID_JAR:?请设置 ANDROID_JAR，例如 \$ANDROID_HOME/platforms/android-36/android.jar}"
: "${D8_JAR:?请设置 D8_JAR，例如 \$ANDROID_HOME/build-tools/30.0.3/lib/d8.jar}"

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# 1) javac 编译（Java 8 目标）
javac -source 8 -target 8 -nowarn \
  -bootclasspath "$ANDROID_JAR" \
  -d "$BUILD/classes" \
  src/cpecpe/TetherCtl.java

# 2) d8 转 dex
java -cp "$D8_JAR" com.android.tools.r8.D8 \
  --release --min-api 30 \
  --lib "$ANDROID_JAR" \
  --output "$BUILD/dex" \
  "$BUILD"/classes/cpecpe/*.class

cp "$BUILD/dex/classes.dex" tetherctl.dex
echo "built: $(pwd)/tetherctl.dex ($(wc -c < tetherctl.dex) bytes)"
