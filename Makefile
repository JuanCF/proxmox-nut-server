SHELL_FILES := $(shell find src/ -name "*.sh")

.PHONY: check lint fmt fmt-fix install-tools

check: lint fmt

lint:
	shellcheck $(SHELL_FILES)

fmt:
	shfmt -d -i 2 $(SHELL_FILES)

fmt-fix:
	shfmt -w -i 2 $(SHELL_FILES)

install-tools:
	sudo apt-get install -y shellcheck shfmt
