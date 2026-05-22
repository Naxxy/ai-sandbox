IMAGE ?= ai-sandbox

# Content hash of src/Dockerfile — auto-derived, no manual version bump needed.
# sha256sum (Linux) / shasum -a 256 (macOS) — try both.
DOCKERFILE_HASH := $(shell (sha256sum src/Dockerfile 2>/dev/null || shasum -a 256 src/Dockerfile 2>/dev/null) | cut -c1-12)

.PHONY: build clean rebuild version

build:
	@if docker image inspect $(IMAGE):$(DOCKERFILE_HASH) >/dev/null 2>&1; then \
		echo "Image $(IMAGE):$(DOCKERFILE_HASH) is current; retagging as latest"; \
		docker tag $(IMAGE):$(DOCKERFILE_HASH) $(IMAGE):latest; \
	else \
		echo "Building $(IMAGE):$(DOCKERFILE_HASH)"; \
		docker build --build-arg VERSION=$(DOCKERFILE_HASH) -f src/Dockerfile -t $(IMAGE):$(DOCKERFILE_HASH) -t $(IMAGE):latest .; \
	fi

clean:
	docker rmi $(IMAGE):$(DOCKERFILE_HASH) $(IMAGE):latest 2>/dev/null || true

rebuild:
	docker build --build-arg VERSION=$(DOCKERFILE_HASH) -f src/Dockerfile -t $(IMAGE):$(DOCKERFILE_HASH) -t $(IMAGE):latest .

version:
	@echo $(DOCKERFILE_HASH)
