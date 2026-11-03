DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: build test app install uninstall clean

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh

install: app
	./Scripts/install.sh

uninstall:
	./Scripts/uninstall.sh

clean:
	rm -rf .build dist
