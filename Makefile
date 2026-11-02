APP := $(HOME)/Applications/TokenMonitor.app

.PHONY: build test bundle install dev probe clean

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

probe: install
	"$(APP)/Contents/MacOS/TokenMonitor" --probe $(PROBE_ARGS)

clean:
	rm -rf .build build
