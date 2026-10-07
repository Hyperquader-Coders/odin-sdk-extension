# MoSCoW — odin-sdk-extension

Prioritisation by **Must / Should / Could / Won't have** (the lower-case Os just make it
pronounceable). This is the **scope** document, and it holds only what is **still open**: an
item leaves this file the moment it ships. Nothing here records work done — `git log` is for
that.

An empty band means that band is finished, not that it was never populated.

## Must have

- **Rebase the patch onto current Odin.** The pinned commit branches from upstream's
  `dev-2026-07a`, which is not current — an SDK extension shipping a months-old dev tag is a
  poor advertisement, and every consumer inherits that age. Rebasing `llvm-target-guards` onto
  current Odin is the work. The risk is downstream: a consumer pinning an ols version has to
  move in step, which is exactly what broke when ols `dev-2026-05` met a compiler that had
  dropped `Odin_OS_Type.Haiku`. Do this before upstreaming, so the patch is offered against
  something current.

- **Upstream the patch.** With the rebase above done, offer it to `odin-lang/Odin`. The argument
  is not a favour: it lets Odin build against any LLVM configured for a subset of targets,
  which is what every distribution and SDK packager needs, and the alternative people reach
  for is deleting the init calls with `sed`. Once merged, this extension builds from
  `odin-lang/Odin` at a release tag, the fork is retired, and Flathub submission stops being
  a conversation about why an SDK extension builds a language from someone's fork.

## Should have

- **Resubmit to Flathub.** The earlier PR
  ([flathub/flathub#9793](https://github.com/flathub/flathub/pull/9793)) was closed, built
  from the pinned public fork. Resubmit once the Must-have chain above lands upstream, so the
  submission is no longer a conversation about why an SDK extension builds a language from
  someone's fork. Once merged, every Odin application reaches the compiler with one manifest
  line, without the amberlinux remote.

## Could have

- **aarch64.** The manifest is x86_64 in practice: the llvm22 extension provides no AArch64
  backend, so a compiler built here cannot emit arm64 even with the guard patch, which
  reports the target as missing rather than failing to link. Shipping an arm64 extension
  needs an LLVM extension built with that target.

- **A second consumer.** yggr is the only application using this. One consumer proves it
  builds; two prove the interface is right.

## Won't have (this time)

- **Bundling language servers.** ols belongs to the application that wants it — yggr builds
  its own against this compiler. An SDK extension that also shipped a language server would
  be making decisions for its consumers.
