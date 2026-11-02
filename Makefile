APP := $(HOME)/Applications/TokenMonitor.app

.PHONY: build test bundle install dev fetch log clean

build:
	swift build

test:
	swift run TokenMonitorTests

bundle:
	scripts/bundle.sh

install:
	scripts/bundle.sh --install

dev: install
	open "$(APP)"

fetch:
	"$(APP)/Contents/MacOS/TokenMonitor" --fetch

log:
	log show --last 1d --style compact --predicate 'subsystem == "com.heeseok.tokenmonitor" and process == "TokenMonitor"'

clean:
	rm -rf .build build
