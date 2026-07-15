.PHONY: generate build install run open clean

DERIVED := ./DerivedData
APP := $(DERIVED)/Build/Products/Debug/AWWidgets.app
INSTALL_APP := /Applications/AWWidgets.app

generate:
	xcodegen generate

build: generate
	xcodebuild -scheme AWWidgets -configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DERIVED) build

install: build
	rm -rf $(INSTALL_APP)
	cp -R $(APP) /Applications/

run: install
	open $(INSTALL_APP)

open:
	open AWWidgets.xcodeproj

clean:
	rm -rf $(DERIVED)
