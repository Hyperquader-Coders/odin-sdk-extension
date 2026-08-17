# MoSCoW

The MoSCoW method is a prioritization technique used in management, business analysis, project management, and software development to reach a common understanding with stakeholders on the importance they place on the delivery of each requirement; it is also known as MoSCoW prioritization or MoSCoW analysis.

The term MoSCoW itself is an acronym derived from the first letter of each of four prioritization categories (Must have, Should have, Could have, and Won't have), with the interstitial Os added to make the word pronounceable. While the Os are usually in lower-case to indicate that they do not stand for anything, the all-capitals MOSCOW is also used.

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

- **Land the Flathub submission.** The PR is open
  ([flathub/flathub#9793](https://github.com/flathub/flathub/pull/9793)), built from the
  pinned public fork; what remains is review — expect questions about the fork, answered by
  the Must-have chain above. Once merged, every Odin application reaches the compiler with
  one manifest line, without the amberlinux remote.

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
