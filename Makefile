MODULE_FILE       := module/default.nix
BUILDERS_FILE     := module/builders.nix
PACKAGE_FILE      := pkgs/package.nix
NIX_VERSION       ?= $(shell sed -n 's/^FROM nixos\/nix:\(.*\)/\1/p' builder/Dockerfile)
BUILDER_VERSION   ?= $(shell tr -d '\n' < builder/IMAGE_VERSION)
IMAGE_TAG         := $(BUILDER_VERSION)-nix$(NIX_VERSION)
CONTAINER_VERSION ?= $(shell sed -n 's/.*version ? "\(.*\)".*/\1/p' $(PACKAGE_FILE) | head -1)
IMAGE             := ghcr.io/halfwhey/nix-builder
SPECIAL_THANKS    ?=

.PHONY: _require_new_version
_require_new_version:
	@[ -n "$(NEW_VERSION)" ] || (printf 'error: NEW_VERSION is not set. Usage: make release NEW_VERSION=vX.Y.Z\n' >&2; exit 1)

.PHONY: release
release: _require_new_version ## Commit VERSION, push, create GitHub release (NEW_VERSION=vX.Y.Z)
	printf '%s\n' "$(NEW_VERSION)" > VERSION
	perl -i -pe 's|nix-apple-container/v[0-9][0-9.]*"|nix-apple-container/$(NEW_VERSION)"|' README.md
	git add VERSION README.md
	git commit -m "$(NEW_VERSION)"
	git tag "$(NEW_VERSION)"
	git push origin master
	git push origin "$(NEW_VERSION)"
	tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	prev_tag=$$(git describe --tags --abbrev=0 "$(NEW_VERSION)^" 2>/dev/null || true); \
	if [ -n "$$prev_tag" ]; then \
		{ \
			printf '## Commits since %s\n\n' "$$prev_tag"; \
			git log --reverse --pretty='* %h %s' "$$prev_tag..$(NEW_VERSION)"; \
		} > "$$tmp"; \
	else \
		{ \
			printf '## Commits in %s\n\n' "$(NEW_VERSION)"; \
			git log --reverse --pretty='* %h %s' "$(NEW_VERSION)"; \
		} > "$$tmp"; \
	fi; \
	gh release create "$(NEW_VERSION)" --notes-file "$$tmp"

.PHONY: build
build: ## Build the builder image locally (multi-arch)
	docker buildx build --platform linux/amd64,linux/arm64 \
		-t $(IMAGE):latest -t $(IMAGE):$(IMAGE_TAG) \
		builder/

.PHONY: push
push: ## Build and push the builder image to ghcr.io
	docker buildx build --platform linux/amd64,linux/arm64 \
		-t $(IMAGE):latest -t $(IMAGE):$(IMAGE_TAG) \
		--push builder/

.PHONY: ci
ci: ## Trigger the builder CI workflow on GitHub
	gh workflow run build-builder.yml

.PHONY: ci-status
ci-status: ## Show status of the latest CI runs
	gh run list --workflow=build-builder.yml --limit=5

.PHONY: update-container
update-container: ## Check and update apple/container to latest release
	@scripts/update-container.sh

.PHONY: update-kernel
update-kernel: ## Check and update kata-containers kernel to latest release
	@scripts/update-kernel.sh

.PHONY: update-nix-builder
update-nix-builder: ## Check and update nixos/nix base image to latest release
	@scripts/update-nix-builder.sh

.PHONY: bump-linux-builder
bump-linux-builder: ## Bump linuxBuilder default image in module/builders.nix to current IMAGE_TAG
	perl -i -pe 's|ghcr.io/halfwhey/nix-builder:[^"]*|ghcr.io/halfwhey/nix-builder:$(IMAGE_TAG)|' $(BUILDERS_FILE)
	git add $(BUILDERS_FILE)
	git diff --cached --quiet || git commit -m "chore: bump linuxBuilder default to $(IMAGE_TAG)"
	git push origin master

.PHONY: bump-builder-image-version
bump-builder-image-version: _require_new_version ## Bump builder image version series (NEW_VERSION=v2)
	printf '%s\n' "$(NEW_VERSION)" > builder/IMAGE_VERSION
	git add builder/IMAGE_VERSION
	git diff --cached --quiet || git commit -m "chore: bump builder image version to $(NEW_VERSION)"
	git push origin master

.PHONY: clean
clean: ## Remove local builder images
	docker rmi $(IMAGE):latest $(IMAGE):$(IMAGE_TAG) 2>/dev/null || true
