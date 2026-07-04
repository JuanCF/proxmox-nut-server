SHELL_FILES := $(shell find vm/ src/backend/ scripts/ -name "*.sh")

.PHONY: check lint fmt fmt-fix install-tools lint-python test-python frontend-install test-frontend lint-frontend tsc-check build-tarball build-frontend

TARBALL := nutwatch.tar.gz
TARBALL_DIR := src/backend

build-frontend:
	cd src/frontend && npm ci && npm run build

build-tarball: build-frontend
	tar -czvf $(TARBALL) \
		-C $(TARBALL_DIR) \
		--exclude '__pycache__' \
		--exclude '.pytest_cache' \
		--exclude 'venv' \
		--exclude 'tests' \
		__init__.py app.py auth.py manage.py config.py utils.py \
		parsers/ services/ routes/ \
		static/ scripts/ \
		nutwatch.service requirements.txt

check: lint fmt lint-python test-python tsc-check lint-frontend test-frontend

lint:
	shellcheck $(SHELL_FILES)

fmt:
	shfmt -d -i 2 $(SHELL_FILES)

fmt-fix:
	shfmt -w -i 2 $(SHELL_FILES)

lint-python:
	@for f in $$(find src/backend -name '*.py'); do python3 -m py_compile $$f || exit 1; done && echo "All Python files syntax OK"

test-python:
	cd src/backend && python3 -m pytest tests/ -v

frontend-install:
	cd src/frontend && npm ci

test-frontend: frontend-install
	cd src/frontend && npm test

lint-frontend: frontend-install
	cd src/frontend && npm run lint

tsc-check: frontend-install
	cd src/frontend && npm run tsc-check

install-tools:
	sudo apt-get install -y shellcheck shfmt python3-pytest nodejs npm
