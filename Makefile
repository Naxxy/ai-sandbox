IMAGE ?= ai-sandbox

# Content hash of src/Dockerfile — auto-derived, no manual version bump needed.
# sha256sum (Linux) / shasum -a 256 (macOS) — try both.
DOCKERFILE_HASH := $(shell (sha256sum src/Dockerfile 2>/dev/null || shasum -a 256 src/Dockerfile 2>/dev/null) | cut -c1-12)

.PHONY: build clean rebuild version

build:
	docker build --progress=plain --build-arg VERSION=$(DOCKERFILE_HASH) -f src/Dockerfile -t $(IMAGE):$(DOCKERFILE_HASH) -t $(IMAGE):latest .

clean:
	docker rmi $(IMAGE):$(DOCKERFILE_HASH) $(IMAGE):latest 2>/dev/null || true

rebuild:
	docker build --progress=plain --build-arg VERSION=$(DOCKERFILE_HASH) -f src/Dockerfile -t $(IMAGE):$(DOCKERFILE_HASH) -t $(IMAGE):latest .

version:
	@echo $(DOCKERFILE_HASH)
