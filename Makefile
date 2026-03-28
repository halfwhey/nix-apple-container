NIX_VERSION       ?= $(shell sed -n 's/^FROM nixos\/nix:\(.*\)/\1/p' builder/Dockerfile)
CONTAINER_VERSION ?= $(shell sed -n 's/.*version = "\(.*\)".*/\1/p' package.nix | head -1)
MODULE_VERSION    := $(shell sed -n 's/.*description = ".*(\(v[0-9.]*\))".*/\1/p' flake.nix)
IMAGE             := ghcr.io/halfwhey/nix-builder

# Portable in-place sed (macOS requires empty-string extension argument)
ifeq ($(shell uname -s),Darwin)
SED_I = sed -i ''
else
SED_I = sed -i
endif

.PHONY: build push ci ci-status release update-container update-kernel update-nix-builder bump-default clean

build: ## Build the builder image locally (multi-arch)
	docker buildx build --platform linux/amd64,linux/arm64 \
		-t $(IMAGE):latest -t $(IMAGE):$(NIX_VERSION) \
		builder/

push: ## Build and push the builder image to ghcr.io
	docker buildx build --platform linux/amd64,linux/arm64 \
		-t $(IMAGE):latest -t $(IMAGE):$(NIX_VERSION) \
		--push builder/

ci: ## Trigger the builder CI workflow on GitHub
	gh workflow run build-builder.yml

ci-status: ## Show status of the latest CI runs
	gh run list --workflow=build-builder.yml --limit=5

release: ## Update README pin, push master, create GitHub release
	@[ -n "$(MODULE_VERSION)" ] || (echo "error: could not extract version from flake.nix"; exit 1)
	$(SED_I) 's|nix-apple-container/v[0-9][0-9.]*"|nix-apple-container/$(MODULE_VERSION)"|' README.md
	git add README.md
	git commit -m "docs: update pinned version to $(MODULE_VERSION)"
	git push origin master
	gh release create $(MODULE_VERSION) --generate-notes

update-container: ## Check and update apple/container to latest release
	@scripts/update-container.sh

update-kernel: ## Check and update kata-containers kernel to latest release
	@scripts/update-kernel.sh

update-nix-builder: ## Check and update nixos/nix base image to latest release
	@scripts/update-nix-builder.sh

bump-default: ## Bump linuxBuilder default image in default.nix to current NIX_VERSION
	$(SED_I) 's|ghcr.io/halfwhey/nix-builder:[^"]*|ghcr.io/halfwhey/nix-builder:$(NIX_VERSION)|' default.nix
	git add default.nix
	git diff --cached --quiet || git commit -m "chore: bump linuxBuilder default to $(NIX_VERSION)"
	git push origin master

clean: ## Remove local builder images
	docker rmi $(IMAGE):latest $(IMAGE):$(NIX_VERSION) 2>/dev/null || true
