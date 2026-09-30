## NotchNotify development targets
.PHONY: build test clean
build:
	bash scripts/build-notch.sh
test:
	bash scripts/test.sh --skip AXIntegrationTests
clean:
	swift package clean
