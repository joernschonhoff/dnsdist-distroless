CI_REGISTRY_IMAGE ?= registry.gitlab.com/joern_schonhoff/dnsdist-distroless

# Read dnsdist version from VERSION file
DNSDIST_VERSION := $(shell cat VERSION)
# Validate version format (semantic versioning: X.Y.Z)
VALIDATE_VERSION := $(shell echo "$(DNSDIST_VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' && echo "valid" || echo "invalid")

ifeq ($(VALIDATE_VERSION),invalid)
$(error Invalid VERSION format: "$(DNSDIST_VERSION)". Expected semantic versioning (X.Y.Z))
endif

.PHONY: build-prod build-debug build test test-example verify clean clean-images version help

help: ## Show this help message
	@echo "dnsdist Distroless - Build Targets"
	@echo "===================================="
	@echo "Current dnsdist version: $(DNSDIST_VERSION)"
	@echo ""
	@grep -E '^[a-zA-Z]\S+:.*' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

version: ## Display current dnsdist version
	@echo $(DNSDIST_VERSION)

build-prod: ## Build production distroless image
	docker buildx build \
		--platform linux/arm64 \
		--build-arg DNSDIST_VERSION=$(DNSDIST_VERSION) \
		--label org.opencontainers.image.created=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--tag "${CI_REGISTRY_IMAGE}:$(DNSDIST_VERSION)" \
		--file Dockerfile .
	@echo "Built: dnsdist-distroless:$(DNSDIST_VERSION)"

build-debug: ## Build debug image with bash shell
	docker buildx build \
		--platform linux/arm64 \
		--build-arg DNSDIST_VERSION=$(DNSDIST_VERSION) \
		--label org.opencontainers.image.created=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--tag "${CI_REGISTRY_IMAGE}:$(DNSDIST_VERSION)-debug" \
		--file Debug.Dockerfile .
	@echo "Built: dnsdist-distroless:$(DNSDIST_VERSION)-debug"

build: build-prod build-debug ## Build both production and debug images

test-example: ## Test the example configuration
	cd example && docker compose up -d && docker compose down

verify: ## Verify built production image
	@echo "Verifying dnsdist-distroless:$(DNSDIST_VERSION)..."
	docker run --rm ${CI_REGISTRY_IMAGE}:$(DNSDIST_VERSION) --version
	@echo "✓ Image verified successfully"

clean: ## Stop and remove example containers and volumes
	cd example && docker compose down -v || true

clean-images: ## Remove built images
	docker rmi ${CI_REGISTRY_IMAGE}:$(DNSDIST_VERSION) || true
	docker rmi ${CI_REGISTRY_IMAGE}:$(DNSDIST_VERSION)-debug || true
