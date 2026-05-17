SHELL_FILES := $(shell find vm/ src/ -name "*.sh")

.PHONY: check lint fmt fmt-fix install-tools lint-python test-python

check: lint fmt lint-python test-python

lint:
	shellcheck $(SHELL_FILES)

fmt:
	shfmt -d -i 2 $(SHELL_FILES)

fmt-fix:
	shfmt -w -i 2 $(SHELL_FILES)

lint-python:
	@for f in $$(find src/nut-admin -name '*.py'); do python3 -m py_compile $$f || exit 1; done && echo "All Python files syntax OK"

test-python:
	cd src/nut-admin && python3 -m pytest tests/ -v

install-tools:
	sudo apt-get install -y shellcheck shfmt python3-pytest
