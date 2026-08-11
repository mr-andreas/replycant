test: gotest webapp

gotest:
	go test ./... -tags integration
.PHONY: gotest

webapp:
	which npm || (echo "npm is not installed, skipping webapp tests" && exit 0)
	cd webapp && npm run typecheck
	cd webapp && npm run test
	cd webapp && npm run e2e
	cd webapp && npm run e2e:integration
.PHONY: webapp

clean:
	docker rm -f $$(docker ps -q --filter label=replycant-integration=true) 2>/dev/null || true
.PHONY: clean

IOS_SCHEME := iosapp
IOS_PROJECT := iosapp/iosapp.xcodeproj
IOS_TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro Max
IOS_BUILD_DIR := iosapp/build/release
IOS_SIGNING_LOCAL := iosapp/Signing.local.xcconfig
IOS_EXPORT_OPTIONS := $(IOS_BUILD_DIR)/ExportOptions.plist
DEVELOPMENT_TEAM ?= $(shell sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' $(IOS_SIGNING_LOCAL) 2>/dev/null)
BUILD_NUMBER := $(shell date +%Y%m%d%H%M)

# fastlane pipes xcodebuild through xcpretty, which raises
# "invalid byte sequence in US-ASCII" and dies the moment the build log contains
# non-ASCII text. Because snapshot runs that pipeline under `set -o pipefail`,
# the crash surfaces as a bogus "Tests failed" and burns a full retry budget on
# passing tests. Force a UTF-8 locale so shells that leave LANG unset still get
# a usable run.
FASTLANE_LOCALE := LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
# Homebrew Ruby (3.x) is required; macOS system Ruby is too old for modern fastlane.
HOMEBREW_RUBY_BIN := $(shell test -x /opt/homebrew/opt/ruby/bin/ruby && echo /opt/homebrew/opt/ruby/bin)
# Prefer the iosapp Gemfile so frameit includes iPhone 17 / recent device frames.
FASTLANE := cd iosapp && $(FASTLANE_LOCALE) env PATH="$(HOMEBREW_RUBY_BIN):$$PATH" bundle exec fastlane

ios-unit-test:
	xcodebuild test -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) \
	  -destination '$(IOS_TEST_DESTINATION)' \
	  -derivedDataPath iosapp/build/test-derived-data

ios-ui-test:
	xcodebuild test -project $(IOS_PROJECT) -scheme iosappScreenshots \
	  -destination '$(IOS_TEST_DESTINATION)' \
	  -derivedDataPath iosapp/build/uitest-derived-data \
	  -skip-testing:iosappUITests/ScreenshotUITests

ios-test: ios-unit-test ios-ui-test
.PHONY: ios-test ios-unit-test ios-ui-test

ios-integration-test:
	@set -euo pipefail; \
	  trap 'bash integration/container.sh stop' EXIT; \
	  bash integration/container.sh start >/dev/null; \
	  TEST_RUNNER_REPLYCANT_INTEGRATION_CTL=http://localhost:18447 \
	  xcodebuild test -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) \
	    -destination '$(IOS_TEST_DESTINATION)' \
	    -derivedDataPath iosapp/build/integration-derived-data \
	    -only-testing:iosappTests/GitdIntegrationTests
.PHONY: ios-integration-test

# Create these once in App Store Connect:
# Users and Access -> Integrations -> App Store Connect API -> Generate API Key.
# Export ASC_KEY_ID (Key ID), ASC_ISSUER_ID (Issuer ID), and ASC_KEY_PATH
# (local path to downloaded AuthKey_<KEY_ID>.p8) before running this target.
# In CI, the same key is usually provided as ASC_KEY_BASE64 and decoded to a
# temporary AuthKey_<KEY_ID>.p8 file before invoking Apple tooling.
ios-export-options:
	@test -n "$(DEVELOPMENT_TEAM)" || { echo "DEVELOPMENT_TEAM unset; add it to $(IOS_SIGNING_LOCAL)"; exit 1; }
	@mkdir -p $(IOS_BUILD_DIR)
	@rm -f $(IOS_EXPORT_OPTIONS)
	@/usr/libexec/PlistBuddy -c "Add :destination string upload" $(IOS_EXPORT_OPTIONS)
	@/usr/libexec/PlistBuddy -c "Add :method string app-store-connect" $(IOS_EXPORT_OPTIONS)
	@/usr/libexec/PlistBuddy -c "Add :signingStyle string automatic" $(IOS_EXPORT_OPTIONS)
	@/usr/libexec/PlistBuddy -c "Add :teamID string $(DEVELOPMENT_TEAM)" $(IOS_EXPORT_OPTIONS)
.PHONY: ios-export-options

ios-release:
	@: "$${ASC_KEY_ID:?Set ASC_KEY_ID}" "$${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}" "$${ASC_KEY_PATH:?Set ASC_KEY_PATH}" "$${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM or add it to $(IOS_SIGNING_LOCAL)}"
	rm -rf $(IOS_BUILD_DIR)
	# Export-compliance exemption: shipped crypto stays on Apple stacks
	# (CryptoKit/CommonCrypto + SecureTransport-backed libgit2).
	# Revisit if a non-Apple crypto backend is introduced.
	xcodebuild -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) \
	  -configuration Release -destination 'generic/platform=iOS' \
	  -archivePath $(IOS_BUILD_DIR)/iosapp.xcarchive \
	  CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
	  INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO \
	  -authenticationKeyPath "$$ASC_KEY_PATH" \
	  -authenticationKeyID "$$ASC_KEY_ID" \
	  -authenticationKeyIssuerID "$$ASC_ISSUER_ID" \
	  -allowProvisioningUpdates archive
	@PRODUCTS_PATH="$(IOS_BUILD_DIR)/iosapp.xcarchive/Products"; \
	  if find "$$PRODUCTS_PATH" \
	      \( -name 'ScreenshotMedia' -o -name 'demo-*.jpg' -o -name 'demo-*.jpeg' \) \
	      -print -quit | grep -q .; then \
	    echo "Screenshot demo media must not be present in App Store build"; \
	    exit 1; \
	  fi
	$(MAKE) ios-export-options DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)"
	xcodebuild -exportArchive \
	  -archivePath $(IOS_BUILD_DIR)/iosapp.xcarchive \
	  -exportOptionsPlist $(IOS_EXPORT_OPTIONS) \
	  -exportPath $(IOS_BUILD_DIR)/export \
	  -authenticationKeyPath "$$ASC_KEY_PATH" \
	  -authenticationKeyID "$$ASC_KEY_ID" \
	  -authenticationKeyIssuerID "$$ASC_ISSUER_ID" \
	  -allowProvisioningUpdates
.PHONY: ios-release

ios-bundle:
	@if [ -z "$(HOMEBREW_RUBY_BIN)" ]; then \
	  echo "Need Homebrew Ruby at /opt/homebrew/opt/ruby (brew install ruby)"; \
	  exit 1; \
	fi
	cd iosapp && env PATH="$(HOMEBREW_RUBY_BIN):$$PATH" bundle check || \
	  env PATH="$(HOMEBREW_RUBY_BIN):$$PATH" bundle install
.PHONY: ios-bundle

ios-screenshots: ios-bundle
	$(FASTLANE) screenshots
.PHONY: ios-screenshots

ios-screenshots-upload: ios-bundle
	@: "$${ASC_KEY_ID:?Set ASC_KEY_ID}" "$${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}" "$${ASC_KEY_PATH:?Set ASC_KEY_PATH}"
	$(FASTLANE) upload_screenshots
.PHONY: ios-screenshots-upload

ios-metadata-upload: ios-bundle
	@: "$${ASC_KEY_ID:?Set ASC_KEY_ID}" "$${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}" "$${ASC_KEY_PATH:?Set ASC_KEY_PATH}"
	$(FASTLANE) upload_metadata
.PHONY: ios-metadata-upload

README_SCREENSHOT_DIR := docs/static/img/readme
README_IOS_SCREENSHOT := $(README_SCREENSHOT_DIR)/ios-timeline.png
README_DESKTOP_SCREENSHOT := $(README_SCREENSHOT_DIR)/desktop-timeline.png
README_COMPOSITE_SCREENSHOT := $(README_SCREENSHOT_DIR)/apps.png

# Captures the Electron timeline window into the committed README desktop asset.
webapp-readme-screenshot:
	cd webapp && npm run screenshot:readme
	@test -f "$(README_DESKTOP_SCREENSHOT)" || (echo "missing $(README_DESKTOP_SCREENSHOT)" && exit 1)
.PHONY: webapp-readme-screenshot

# Copies the README-specific black-device iPhone frame into the committed asset.
copy-readme-ios-screenshot:
	@mkdir -p "$(README_SCREENSHOT_DIR)"
	@src="iosapp/fastlane/screenshots/framed/readme/ios-timeline.png"; \
	  if [ ! -f "$$src" ]; then \
	    echo "missing $$src (run make ios-screenshots first)"; \
	    exit 1; \
	  fi; \
	  cp "$$src" "$(README_IOS_SCREENSHOT)"; \
	  echo "copied $$src -> $(README_IOS_SCREENSHOT)"
.PHONY: copy-readme-ios-screenshot

# Overlays the iPhone frame on the Electron window for the README hero image.
compose-readme-screenshot:
	cd webapp && npm run screenshot:readme:compose
	@test -f "$(README_COMPOSITE_SCREENSHOT)" || (echo "missing $(README_COMPOSITE_SCREENSHOT)" && exit 1)
.PHONY: compose-readme-screenshot

# Regenerates README product screenshots and the combined hero image.
readme-screenshots: ios-screenshots copy-readme-ios-screenshot webapp-readme-screenshot compose-readme-screenshot
.PHONY: readme-screenshots
