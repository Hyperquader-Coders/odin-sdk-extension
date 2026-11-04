# odin-sdk-extension: the Flatpak SDK extension carrying the Odin compiler.
MANIFEST   := org.freedesktop.Sdk.Extension.odin.yaml
EXT_ID     := org.freedesktop.Sdk.Extension.odin
BASE       := 26.08
# Everything flatpak-builder makes stays under build/: its build tree, its state
# (downloads, ccache, checkouts) and the ostree repo. CI writes its bundle to dist/.
BUILD_DIR  := build/dir
STATE_DIR  := build/flatpak-builder
.PHONY: deps-flatpak build check-licences flatpak-repo flatpak-repo-path check-manifest check clean push lint diags

# targets: no test (no code of its own; `check` compiles and runs a program with the installed extension)
# targets: no deps-flatpak-apart (the product is the Flatpak: `ci` checks the built extension in the SDK, so setup installs the SDK too)

# What only the two builds need on the host: git, which flatpak-builder runs to fetch the Odin
# source (a `type: git` source) and only Recommends, so an install without recommends lacks it.
# No elfutils or binutils: flatpak-builder runs eu-strip, eu-elfcompress or strip after a module
# only for `strip: true` or for debuginfo, and the manifest sets neither (no-debuginfo, and
# build-extension turns debuginfo off anyway); the build commands strip inside the SDK.
# `make deps-flatpak` installs it.
FLATPAK_DEPS := git

# The runtime and SDK at the manifest's runtime-version, and its SDK extensions at that branch,
# read from the manifest so the two cannot disagree; all come from Flathub. The llvm extension is
# a build-time dependency of this extension, not of the apps that consume it: the compiler ships
# the libLLVM it was linked against.
FLATPAK_RUNTIME_REFS = $(sort $(shell awk '/^(runtime|sdk):/ {n[$$1] = $$2} /^runtime-version:/ {v = $$2; gsub(/[\047"]/, "", v)} END {print n["runtime:"] "//" v, n["sdk:"] "//" v}' $(MANIFEST)))
FLATPAK_EXTENSIONS = $(shell awk '/^sdk-extensions:/ {on = 1; next} on && /^[a-z]/ {on = 0} on && /^[ \t]*- / {print $$2}' $(MANIFEST))
FLATHUB := https://dl.flathub.org/repo/flathub.flatpakrepo

# FLATPAK_DEPS, asking apt only for what dpkg does not report as installed, then each runtime and
# extension this user has not installed yet, adding Flathub first.
#
# The house's exception (TEMPLATES, Make targets): elsewhere neither setup nor init-workstation
# runs deps-flatpak, because only a Flatpak build needs it. Here the Flatpak is the product, and
# `make ci` runs `check`, which compiles a program in the installed SDK, so a desk that runs ci
# needs the SDK and init-workstation installs it. `ci` itself never installs anything; the
# workflow runs `make deps-flatpak` before it.
deps-flatpak: ## install what the builds and `check` need: git (sudo apt), then the SDK and the llvm extension for this user (several GB)
	@missing=$$(for p in $(FLATPAK_DEPS); do \
		dpkg-query -W -f='$${db:Status-Status}' "$$p" 2>/dev/null | grep -qx installed || echo "$$p"; \
	done); \
	if [ -z "$$missing" ]; then echo "$@: have $(FLATPAK_DEPS)"; \
	else sudo apt-get install $(APT_FLAGS) --no-install-recommends $$missing; fi
	@set -e; for ref in $(FLATPAK_RUNTIME_REFS) $(addsuffix //$(BASE),$(FLATPAK_EXTENSIONS)); do \
		if flatpak info --user "$$ref" >/dev/null 2>&1; then echo "$@: have $$ref"; continue; fi; \
		flatpak remote-add --user --if-not-exists flathub $(FLATHUB); \
		flatpak install --user --noninteractive flathub "$$ref"; \
	done

build: deps-flatpak ## build the extension and install it for this user
	@mkdir -p build
	flatpak-builder --user --install --force-clean --disable-rofiles-fuse \
		--state-dir=$(STATE_DIR) $(BUILD_DIR) $(MANIFEST)
	@$(MAKE) -s check-licences

# The licence texts the extension ships, under share/licenses/<component>/ of its
# prefix. Both builds run this on the tree they made, so neither leaves an
# extension that ships a compiler or libLLVM without its licence.
LICENCES := odin/LICENSE utf8proc/LICENSE.md llvm/LICENSE.TXT

check-licences: ## fail when the built tree lacks a licence text
	@missing=0; \
	for f in $(LICENCES); do \
		test -s "$(BUILD_DIR)/files/share/licenses/$$f" || { echo "missing licence: share/licenses/$$f"; missing=1; }; \
	done; \
	test $$missing = 0 && echo "licences OK: $(LICENCES)"

# Cheap, local, and needs nothing installed: does the manifest parse, and do the
# scripts lint: the gate a desk without the SDK can run, as the functional check below needs
# several GB of SDK that CI already has. --show-manifest takes no
# --state-dir and still leaves a .flatpak-builder where it runs, so it runs in
# build/.
check-manifest: ## manifest parses, lint passes; needs nothing installed
	@mkdir -p build && cd build && flatpak-builder --show-manifest ../$(MANIFEST) >/dev/null
	@echo "manifest OK"
	@$(MAKE) -s lint

# Compile and run a real program with the installed extension. `odin version`
# alone would pass with a broken ODIN_ROOT, since it reads no collections.
#
# Requires the SDK and the extension to actually be installed. "Not installed"
# and "broken" are different answers and this must not report the first as the
# second: that is how a working extension gets called faulty. Likewise an SDK
# that will not start is flatpak's failure, not the extension's.
#
# Everything is the per-user installation, where `make deps-flatpak`, `make build` and
# CI put it. Without --user, an SDK also installed system-wide makes flatpak
# ask which one to use, and with no terminal to answer it gives up.
check: ## compile and run a real program with the installed extension
	@flatpak info --user org.freedesktop.Sdk//$(BASE) >/dev/null 2>&1 || { \
		echo "check: org.freedesktop.Sdk//$(BASE) is not installed for this user, so there is nothing to check against."; \
		echo "  make deps-flatpak installs it (several GB), or"; \
		echo "  push and let CI run this, which is where it normally runs."; \
		exit 2; }
	@flatpak info --user $(EXT_ID)//$(BASE) >/dev/null 2>&1 || { \
		echo "check: $(EXT_ID)//$(BASE) is not installed for this user, so there is nothing to check against."; \
		echo "  make build                       builds and installs it locally, or"; \
		echo "  flatpak install --user amberlinux $(EXT_ID)   takes the published one."; \
		exit 2; }
	@flatpak run --user --command=true org.freedesktop.Sdk//$(BASE) || { \
		echo "FAILED: flatpak could not start org.freedesktop.Sdk//$(BASE) (its error is above); the extension was not tried"; \
		exit 1; }
	@tmp=$$(mktemp -d); \
	printf 'package main\nimport "core:fmt"\nmain :: proc() { fmt.println("ok") }\n' > $$tmp/main.odin; \
	flatpak run --user --command=sh --filesystem=$$tmp org.freedesktop.Sdk//$(BASE) -c \
		'. /usr/lib/sdk/odin/enable.sh && odin run '"$$tmp"' -out:'"$$tmp"'/t' \
		|| { echo "FAILED: the extension is installed but cannot compile a core-importing program"; rm -rf $$tmp; exit 1; }; \
	rm -rf $$tmp; \
	echo "check OK"

# The sibling contract amberlinux-flatpak's `make add-suite` calls, mirroring the
# apt archive's `make deb-path`: answer with the ostree repo this build produced,
# so the archive never hardcodes another repo's output layout.
#
# `make build` installs; this builds into a repo instead, which is what an
# archive can pull from.
REPO_DIR := build/repo

flatpak-repo-path: ## print the path of the ostree repo 'make flatpak-repo' built
	@test -d $(REPO_DIR) || { \
		echo "no repo at $(CURDIR)/$(REPO_DIR): run 'make flatpak-repo' first" >&2; \
		exit 2; }
	@echo "$(CURDIR)/$(REPO_DIR)"

flatpak-repo: deps-flatpak ## build the extension into an ostree repo under build/
	@mkdir -p build
	flatpak-builder --user --force-clean --disable-rofiles-fuse \
		--state-dir=$(STATE_DIR) --repo=$(REPO_DIR) $(BUILD_DIR) $(MANIFEST)
	@$(MAKE) -s check-licences
	@echo "repo at $(CURDIR)/$(REPO_DIR)"

clean: ## remove build/ and dist/
	rm -rf build dist

push: ## push main to origin
	git push "$(REMOTE)" "$(BRANCH)"

# The SVG is committed so reading the repo does not require d2; `make lint`
# fails when it drifts from the source.
diags: ## render diags/*.d2 to SVG
	@for f in diags/*.d2; do \
		d2 --theme=105 --dark-theme=300 --pad=40 "$$f" "$${f%.d2}.svg"; \
		chmod 644 "$${f%.d2}.svg"; \
	done

# house-rules' check-example-hosts runs where house-rules is there, in the folder HOUSE_ROOT
# names (mise sets it on a development machine); house-rules is private, so a clone outside the
# house and the public runner go without it, saying so.
lint: ## diagram freshness and shellcheck, house-rules' check-example-hosts
	$(call house_check,check-example-hosts $(CURDIR))
	@if command -v d2 >/dev/null; then \
		for src in diags/*.d2; do \
			svg=$${src%.d2}.svg; tmp=$$(mktemp -d); \
			d2 --theme=105 --dark-theme=300 --pad=40 "$$src" "$$tmp/out.svg" >/dev/null 2>&1; \
			cmp -s "$$tmp/out.svg" "$$svg" || { echo "lint: $$svg is stale (run 'make diags')"; rm -rf "$$tmp"; exit 1; }; \
			rm -rf "$$tmp"; \
		done; \
	fi
	@if command -v shellcheck >/dev/null; then \
		git ls-files | while read -r f; do \
			case "$$f" in *.sh|*.bash) echo "$$f";; \
			*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
		done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"; \
	else echo "shellcheck not installed, skipping (apt install shellcheck)"; fi

# A desk sets up git, the SDK and the llvm extension (several GB) with init-workstation.
init-workstation: deps-flatpak

# The house's shared targets (setup, ci, force-push), from house/, a copy of house-rules'
# scripts/binding/house.mk: this repository is public, and its runner has no house-rules. The
# packages, and the steps CI runs, are project.toml's.
include house/house.mk
