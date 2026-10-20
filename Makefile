# odin-sdk-extension: the Flatpak SDK extension carrying the Odin compiler.
MANIFEST   := org.freedesktop.Sdk.Extension.odin.yaml
EXT_ID     := org.freedesktop.Sdk.Extension.odin
BASE       := 26.08
LLVM_EXT   := org.freedesktop.Sdk.Extension.llvm22
# Everything flatpak-builder makes stays under build/: its build tree, its state
# (downloads, ccache, checkouts) and the ostree repo. CI writes its bundle to dist/.
BUILD_DIR  := build/dir
STATE_DIR  := build/flatpak-builder
BRANCH     ?= main
REMOTE     ?= origin
ROOT_COMMIT_MSG ?= Initial odin-sdk-extension
# HOUSE_ROOT is the folder holding house-rules, which mise sets on a development machine;
# `make lint` runs its check-example-hosts where it is there. house-rules is private, so a clone
# outside the house and the public runner go without it, saying so.
HOUSE_SCRIPTS = $(HOUSE_ROOT)/house-rules/scripts

.PHONY: help setup init-packages init-modules init-workstation sdk build check-licences flatpak-repo flatpak-repo-path check-manifest check ci clean push force-push lint diags check-no-agent-files

# targets: no test (no code of its own; `check` compiles and runs a program with the installed extension)

# The system packages, one list for a desk and for CI: flatpak and flatpak-builder, elfutils and
# shellcheck. elfutils supplies eu-strip: flatpak-builder splits debug symbols into a .Debug
# extension after each module builds, and without eu-strip that post-build step fails after the
# module itself compiled, which reads like a build error. `make init-packages` installs the list;
# a package missing on the runner is added here, and the workflow names none.
DEPS := flatpak flatpak-builder elfutils shellcheck
APT_FLAGS ?=

init-packages: ## install the system packages (sudo apt)
	sudo apt-get install $(APT_FLAGS) --no-install-recommends $(DEPS)

# No language packages: the manifest pins every source flatpak-builder fetches. `ci` depends on it
# all the same, as in every repository.
init-modules: ## install the language packages from the lock: none here

# The llvm extension is a build-time dependency of this extension, not of the
# apps that consume it: the compiler ships the libLLVM it was linked against.
sdk: ## install the SDK and the llvm extension for this user (several GB)
	flatpak install --user --noninteractive flathub \
		org.freedesktop.Sdk//$(BASE) \
		$(LLVM_EXT)//$(BASE)

build: sdk ## build the extension and install it for this user
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
# scripts lint. This is what `force-push` gates on, because the functional check
# below needs several GB of SDK that CI already has. --show-manifest takes no
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
# Everything is the per-user installation, where `make sdk`, `make build` and
# CI put it. Without --user, an SDK also installed system-wide makes flatpak
# ask which one to use, and with no terminal to answer it gives up.
check: ## compile and run a real program with the installed extension
	@flatpak info --user org.freedesktop.Sdk//$(BASE) >/dev/null 2>&1 || { \
		echo "check: org.freedesktop.Sdk//$(BASE) is not installed for this user, so there is nothing to check against."; \
		echo "  make sdk         installs it (several GB), or"; \
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

flatpak-repo: sdk ## build the extension into an ostree repo under build/
	@mkdir -p build
	flatpak-builder --user --force-clean --disable-rofiles-fuse \
		--state-dir=$(STATE_DIR) --repo=$(REPO_DIR) $(BUILD_DIR) $(MANIFEST)
	@$(MAKE) -s check-licences
	@echo "repo at $(CURDIR)/$(REPO_DIR)"

# What CI runs, and what a person can run before pushing: the cheap gate plus the
# functional one when the SDKs are present.
ci: init-modules check-manifest check check-no-agent-files ## everything a push must pass

clean: ## remove build/ and dist/
	rm -rf build dist

push: ## push main to origin
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path simply appears in the root commit as though it always belonged.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored, so 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: check-manifest check-no-agent-files ## rewrite history as one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@set -e; \
	orig_branch="$$(git branch --show-current)"; \
	test -n "$$orig_branch" || { echo "force-push: detached HEAD, check out a branch first"; exit 1; }; \
	tmp_branch="root-squash-$$(date +%s)"; \
	step="starting"; ok=0; \
	trap 'if [ "$$ok" != 1 ]; then echo "force-push FAILED while: $$step. Local history is intact on $$orig_branch; $(REMOTE)/$(BRANCH) was not replaced." >&2; git checkout -f "$$orig_branch" >/dev/null 2>&1 || true; git branch -D "$$tmp_branch" >/dev/null 2>&1 || true; exit 1; fi' EXIT; \
	step="creating the orphan branch"; git checkout --orphan "$$tmp_branch"; \
	step="staging the tree"; git add -A; \
	step="signing the root commit"; git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	step="pushing to $(REMOTE)/$(BRANCH) (refused or unreachable)"; git push --force "$(REMOTE)" "$$tmp_branch:$(BRANCH)"; \
	step="verifying $(REMOTE)/$(BRANCH) equals the new commit"; \
	remote_sha="$$(git ls-remote "$(REMOTE)" "refs/heads/$(BRANCH)" | cut -f1)"; \
	test -n "$$remote_sha" && test "$$remote_sha" = "$$(git rev-parse HEAD)"; \
	ok=1; \
	git branch -M "$$tmp_branch" "$(BRANCH)"; \
	git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."
	@echo "Now clear the workflow runs left pointing at the discarded commits:"
	@echo "  see the force-push skill: gh run list / gh run delete"

# The SVG is committed so reading the repo does not require d2; `make lint`
# fails when it drifts from the source.
diags: ## render diags/*.d2 to SVG
	@for f in diags/*.d2; do \
		d2 --theme=105 --dark-theme=300 --pad=40 "$$f" "$${f%.d2}.svg"; \
		chmod 644 "$${f%.d2}.svg"; \
	done

lint: ## diagram freshness and shellcheck, house-rules' check-example-hosts
	@if [ -n "$(HOUSE_ROOT)" ] && [ -x "$(HOUSE_SCRIPTS)/check-example-hosts" ]; then "$(HOUSE_SCRIPTS)/check-example-hosts" "$(CURDIR)"; \
	else echo "house-rules not found (HOUSE_ROOT=$(HOUSE_ROOT)): check-example-hosts skipped; house-rules is private"; fi
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

help: ## this list
	@awk 'BEGIN {FS = ":.*## "} \
	    /^##@ / {printf "\n%s\n", substr($$0, 5)} \
	    /^[a-z][a-z0-9-]*:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init-workstation: sdk ## set up a desk: the SDK and the llvm extension (several GB)

# The one command after a fresh clone, the same in every repository.
setup: init-packages init-modules init-workstation ## everything a fresh clone needs: packages (sudo apt), then the SDK
