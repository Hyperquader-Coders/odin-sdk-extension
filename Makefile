# odin-sdk-extension — Flatpak SDK extension carrying the Odin compiler.
MANIFEST   := org.freedesktop.Sdk.Extension.odin.yaml
EXT_ID     := org.freedesktop.Sdk.Extension.odin
BASE       := 25.08
LLVM_EXT   := org.freedesktop.Sdk.Extension.llvm22
BUILD_DIR  := build-dir
BRANCH     ?= main
REMOTE     ?= origin
ROOT_COMMIT_MSG ?= Initial odin-sdk-extension

.PHONY: deps build repo flatpak-repo verify check ci clean push force-push lint diags check-no-agent-files

# The llvm extension is a build-time dependency of this extension, not of the
# apps that consume it: the compiler ships the libLLVM it was linked against.
deps:
	flatpak install --user --noninteractive flathub \
		org.freedesktop.Sdk//$(BASE) \
		$(LLVM_EXT)//$(BASE)

build: deps
	flatpak-builder --user --install --force-clean --disable-rofiles-fuse \
		$(BUILD_DIR) $(MANIFEST)

# Cheap, local, and needs nothing installed: does the manifest parse, and do the
# scripts lint. This is what `force-push` gates on, because the functional check
# below needs several GB of SDK that CI already has.
verify:
	@flatpak-builder --show-manifest $(MANIFEST) >/dev/null
	@echo "manifest OK"
	@$(MAKE) -s lint

# Compile and run a real program with the installed extension. `odin version`
# alone would pass with a broken ODIN_ROOT, since it reads no collections.
#
# Requires the SDK and the extension to actually be installed. "Not installed"
# and "broken" are different answers and this must not report the first as the
# second — that is how a working extension gets called faulty.
check:
	@flatpak info org.freedesktop.Sdk//$(BASE) >/dev/null 2>&1 || { \
		echo "check: org.freedesktop.Sdk//$(BASE) is not installed — nothing to check against."; \
		echo "  make deps        installs it (several GB), or"; \
		echo "  push and let CI run this, which is where it normally runs."; \
		exit 2; }
	@flatpak info $(EXT_ID)//$(BASE) >/dev/null 2>&1 || { \
		echo "check: $(EXT_ID)//$(BASE) is not installed — nothing to check against."; \
		echo "  make build                       builds and installs it locally, or"; \
		echo "  flatpak install amberlinux $(EXT_ID)   takes the published one."; \
		exit 2; }
	@tmp=$$(mktemp -d); \
	printf 'package main\nimport "core:fmt"\nmain :: proc() { fmt.println("ok") }\n' > $$tmp/main.odin; \
	flatpak run --command=sh --filesystem=$$tmp org.freedesktop.Sdk//$(BASE) -c \
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
REPO_DIR := repo

flatpak-repo:
	@test -d $(REPO_DIR) || { \
		echo "no repo at $(CURDIR)/$(REPO_DIR) — run 'make repo' first" >&2; \
		exit 2; }
	@echo "$(CURDIR)/$(REPO_DIR)"

repo: deps
	flatpak-builder --user --force-clean --disable-rofiles-fuse \
		--repo=$(REPO_DIR) $(BUILD_DIR) $(MANIFEST)
	@echo "repo at $(CURDIR)/$(REPO_DIR)"

# What CI runs, and what a person can run before pushing: the cheap gate plus the
# functional one when the SDKs are present.
ci: verify check

clean:
	rm -rf $(BUILD_DIR) .flatpak-builder $(REPO_DIR)

push:
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added — a stray
# path simply appears in the root commit as though it always belonged.
check-no-agent-files:
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored — 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: verify check-no-agent-files
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@orig_branch="$$(git branch --show-current)"; \
	tmp_branch="root-squash-$$(date +%s)"; \
	git checkout --orphan "$$tmp_branch"; \
	git add -A; \
	git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	git branch -D "$(BRANCH)" 2>/dev/null || true; \
	git branch -m "$(BRANCH)"; \
	git push --force --set-upstream "$(REMOTE)" "$(BRANCH)"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."
	@echo "Now clear the workflow runs left pointing at the discarded commits:"
	@echo "  see the force-push skill — gh run list / gh run delete"

# The SVG is committed so reading the repo does not require d2; `make lint`
# fails when it drifts from the source.
diags:
	@for f in diags/*.d2; do \
		d2 --theme=105 --dark-theme=300 --pad=40 "$$f" "$${f%.d2}.svg"; \
		chmod 644 "$${f%.d2}.svg"; \
	done

lint:
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
	else echo "shellcheck not installed — skipping (apt install shellcheck)"; fi
