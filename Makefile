DERIVED := build
XCB := xcodebuild -project ClassLens.xcodeproj -scheme ClassLens -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'
APP := $(DERIVED)/Build/Products/Debug/ClassLens.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/ClassLens.app

.PHONY: gen build release test run clean

gen:
	xcodegen generate --quiet

build: gen
	$(XCB) -configuration Debug -quiet build

release: gen
	$(XCB) -configuration Release -quiet build

test: gen
	$(XCB) -quiet test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED) ClassLens.xcodeproj
