#!/bin/bash

# Rebuilds libgit2 with HTTPS/TLS support using Apple's SecureTransport.
# This enables HTTPS connections without requiring OpenSSL or external dependencies.

set -e

echo "🔧 Building libgit2 with TLS support (SecureTransport) for iOS..."
echo ""

# Store base directory
BUILD_BASE="$(pwd)/build-temp"

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf build-temp libgit2.xcframework

# Create build directory
mkdir -p build-temp
cd build-temp

# Download iOS CMake toolchain
if [ ! -f "ios.toolchain.cmake" ]; then
    echo ""
    echo "📥 Downloading iOS CMake toolchain..."
    curl -s -L https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake -o ios.toolchain.cmake
fi

# Download libgit2 source
LIBGIT2_VERSION="1.9.2"
if [ ! -d "libgit2-${LIBGIT2_VERSION}" ]; then
    echo "📥 Downloading libgit2 ${LIBGIT2_VERSION}..."
    curl -L "https://github.com/libgit2/libgit2/archive/refs/tags/v${LIBGIT2_VERSION}.tar.gz" | tar -xz
fi

# Get iOS SDK paths
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
IOSSIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

# libgit2's assertion and error macros bake __FILE__ into the archive, which
# would otherwise publish the build machine's home directory inside the
# committed xcframework. Rewrite the prefix so the artifact is reproducible and
# reveals nothing about who built it.
SOURCE_PREFIX_MAP="-ffile-prefix-map=$BUILD_BASE/libgit2-${LIBGIT2_VERSION}=libgit2"

# Build for iOS device (arm64)
echo ""
echo "🔨 Building libgit2 for iOS device (arm64)..."
echo "   Using SDK: $IOS_SDK"
mkdir -p libgit2-ios-arm64
cd libgit2-ios-arm64

cmake \
    -DCMAKE_TOOLCHAIN_FILE="$BUILD_BASE/ios.toolchain.cmake" \
    -DPLATFORM=OS64 \
    -DDEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$SOURCE_PREFIX_MAP" \
    -DCMAKE_INSTALL_PREFIX=./install \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DUSE_SSH=OFF \
    -DUSE_HTTPS=SecureTransport \
    -DUSE_BUNDLED_ZLIB=OFF \
    -DUSE_ICONV=ON \
    -DREGEX_BACKEND=builtin \
    -DTHREADSAFE=ON \
    -DCOREFOUNDATION_INCLUDE_DIR:PATH="$IOS_SDK/System/Library/Frameworks/CoreFoundation.framework/Headers" \
    -DCOREFOUNDATION_LIBRARIES:FILEPATH="$IOS_SDK/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" \
    -DCOREFOUNDATION_FOUND:BOOL=TRUE \
    -DCOREFOUNDATION_LDFLAGS:STRING="-framework CoreFoundation" \
    -DSECURITY_INCLUDE_DIR:PATH="$IOS_SDK/System/Library/Frameworks/Security.framework/Headers" \
    -DSECURITY_LIBRARIES:FILEPATH="$IOS_SDK/System/Library/Frameworks/Security.framework/Security" \
    -DSECURITY_FOUND:BOOL=TRUE \
    -DSECURITY_HAS_SSLCREATECONTEXT:BOOL=TRUE \
    -DSECURITY_LDFLAGS:STRING="-framework Security" \
    "$BUILD_BASE/libgit2-${LIBGIT2_VERSION}"

make -j$(sysctl -n hw.ncpu)
make install

cd ..

# Build for iOS Simulator (arm64)
echo ""
echo "🔨 Building libgit2 for iOS Simulator (arm64)..."
echo "   Using SDK: $IOSSIM_SDK"
mkdir -p libgit2-iossimulator-arm64
cd libgit2-iossimulator-arm64

cmake \
    -DCMAKE_TOOLCHAIN_FILE="$BUILD_BASE/ios.toolchain.cmake" \
    -DPLATFORM=SIMULATORARM64 \
    -DDEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$SOURCE_PREFIX_MAP" \
    -DCMAKE_INSTALL_PREFIX=./install \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DUSE_SSH=OFF \
    -DUSE_HTTPS=SecureTransport \
    -DUSE_BUNDLED_ZLIB=OFF \
    -DUSE_ICONV=ON \
    -DREGEX_BACKEND=builtin \
    -DTHREADSAFE=ON \
    -DCOREFOUNDATION_INCLUDE_DIR:PATH="$IOSSIM_SDK/System/Library/Frameworks/CoreFoundation.framework/Headers" \
    -DCOREFOUNDATION_LIBRARIES:FILEPATH="$IOSSIM_SDK/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" \
    -DCOREFOUNDATION_FOUND:BOOL=TRUE \
    -DCOREFOUNDATION_LDFLAGS:STRING="-framework CoreFoundation" \
    -DSECURITY_INCLUDE_DIR:PATH="$IOSSIM_SDK/System/Library/Frameworks/Security.framework/Headers" \
    -DSECURITY_LIBRARIES:FILEPATH="$IOSSIM_SDK/System/Library/Frameworks/Security.framework/Security" \
    -DSECURITY_FOUND:BOOL=TRUE \
    -DSECURITY_HAS_SSLCREATECONTEXT:BOOL=TRUE \
    -DSECURITY_LDFLAGS:STRING="-framework Security" \
    "$BUILD_BASE/libgit2-${LIBGIT2_VERSION}"

make -j$(sysctl -n hw.ncpu)
make install

cd ..

# Create XCFramework
echo ""
echo "📦 Creating XCFramework..."
cd ..
xcodebuild -create-xcframework \
    -library build-temp/libgit2-ios-arm64/install/lib/libgit2.a \
    -headers build-temp/libgit2-ios-arm64/install/include \
    -library build-temp/libgit2-iossimulator-arm64/install/lib/libgit2.a \
    -headers build-temp/libgit2-iossimulator-arm64/install/include \
    -output libgit2.xcframework

echo ""
echo "✅ Build complete!"
echo "📁 XCFramework created: libgit2.xcframework"
echo ""
echo "🔐 This build includes:"
echo "   - HTTPS/TLS support via SecureTransport (Apple's native TLS)"
echo "   - No SSH support (use mtls+https:// URLs with MTLSTransport for network operations)"
echo "   - No external crypto dependencies"
echo ""
echo "🎉 To verify TLS support, run the app and check for 'HTTPS support is available'!"
