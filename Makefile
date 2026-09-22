APP_NAME       := Streamif
SCHEME         := Streamif
PROJECT        := macos/$(APP_NAME).xcodeproj
PBXPROJ        := $(PROJECT)/project.pbxproj
SCRIPTS        := scripts
BUILD_SCRIPT   := $(SCRIPTS)/build-and-notarize.sh
NOTARY_SCRIPT  := $(SCRIPTS)/setup-notarization.sh
SPARKLE_SCRIPT := $(SCRIPTS)/setup-sparkle-keys.sh
APPCAST_SCRIPT := $(SCRIPTS)/generate-appcast.sh
DERIVED_DATA   := $(HOME)/Library/Developer/Xcode/DerivedData

ARCH    ?= universal
VERSION  = $(shell sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);.*/\1/p' $(PBXPROJ) | head -1)
BUILD    = $(shell sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' $(PBXPROJ) | head -1)
ZIP     ?= build/$(ARCH)/$(APP_NAME)-$(VERSION)-$(ARCH).zip
NOTES   ?=

.DEFAULT_GOAL := help

.PHONY: help setup setup-sparkle version build run test clean release patch minor major \
        bump-patch bump-minor bump-major appcast

help: ## Show this help
	@awk 'BEGIN { FS = ":.*##"; printf "\n\033[1m$(APP_NAME) $(VERSION)\033[0m - make <target>\n" } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nVariables: ARCH=%s ZIP=<path> NOTES=<release-notes.md>\n\n' "$(ARCH)"

##@ Setup (one time)

setup: ## Store Apple notarization credentials in the keychain
	@$(NOTARY_SCRIPT)

setup-sparkle: ## Generate the Sparkle EdDSA update-signing keys
	@$(SPARKLE_SCRIPT)

##@ Development

build: ## Build a universal binary without notarizing
	@$(BUILD_SCRIPT) --arch $(ARCH) --skip-notarize

run: ## Build and launch the debug app
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath build/debug build
	@open build/debug/Build/Products/Debug/$(APP_NAME).app

test: ## Run the test suite
	@xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' -derivedDataPath build/test

##@ Release

release: ## Build, sign, notarize and package the current version
	@$(BUILD_SCRIPT) --arch $(ARCH)

patch: ## Bump the patch version, then release
	@$(BUILD_SCRIPT) --bump patch --arch $(ARCH)

minor: ## Bump the minor version, then release
	@$(BUILD_SCRIPT) --bump minor --arch $(ARCH)

major: ## Bump the major version, then release
	@$(BUILD_SCRIPT) --bump major --arch $(ARCH)

appcast: ## Add the built ZIP to appcast.xml (ZIP=... NOTES=...)
	@$(APPCAST_SCRIPT) --zip "$(ZIP)" --version "$(VERSION)" --build "$(BUILD)" \
		$(if $(NOTES),--notes-file "$(NOTES)",)

##@ Versioning

version: ## Show the current version and build number
	@printf 'Version:      %s\nBuild number: %s\n' "$(VERSION)" "$(BUILD)"

bump-patch: ## Bump the patch version only
	@$(BUILD_SCRIPT) --bump patch --bump-only

bump-minor: ## Bump the minor version only
	@$(BUILD_SCRIPT) --bump minor --bump-only

bump-major: ## Bump the major version only
	@$(BUILD_SCRIPT) --bump major --bump-only

##@ Housekeeping

clean: ## Remove build artifacts
	@rm -rf build
	@rm -rf $(DERIVED_DATA)/$(APP_NAME)-*
	@printf 'Removed build/ and derived data.\n'
