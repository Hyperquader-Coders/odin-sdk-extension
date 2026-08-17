# odin-sdk-extension

A Flatpak SDK extension that puts the **Odin compiler** inside the build sandbox.

Flatpak builds are hermetic: a module is built against the runtime and its SDK,
and nothing on the host or the CI runner is reachable. An application written in
Odin therefore has no compiler unless it builds one itself, in its own manifest,
against whichever LLVM the SDK provides. This extension does that once so every
Odin application does not have to.

Extension id `org.freedesktop.Sdk.Extension.odin`, installed at
`/usr/lib/sdk/odin`.

## Installing it

It is published from the Amber Linux flatpak archive, not from Flathub — that
submission is gated on the compiler patch below landing upstream.

```sh
flatpak remote-add --if-not-exists amberlinux \
    https://flatpak.amberlinux.org/amberlinux.flatpakrepo
flatpak install amberlinux org.freedesktop.Sdk.Extension.odin
```

The remote is GPG-signed. A build machine needs this before `flatpak-builder`
can resolve the `sdk-extensions` entry below; `--install-deps-from=flathub`
cannot find it, because it is not there.

## Using it

```yaml
sdk-extensions:
  - org.freedesktop.Sdk.Extension.odin
  - org.freedesktop.Sdk.Extension.llvm22

modules:
  - name: my-app
    buildsystem: simple
    build-commands:
      - . /usr/lib/sdk/odin/enable.sh && odin build src -out:my-app
      - install -Dm755 my-app /app/bin/my-app
```

`enable.sh` puts the compiler on `PATH` and sets `ODIN_ROOT`, which is how the
compiler finds the `core`, `base` and `vendor` collections. Without `ODIN_ROOT`
only a program that imports nothing will build.

**Both extensions are required.** Odin links through `clang` — `src/linker.cpp`
calls it by name, so it can ask the compiler driver's specs where `libgcc_s`,
`ld-linux` and `unwind` live, which varies by distribution. The `-linker:` option
chooses what runs behind that frontend, not the frontend itself. The freedesktop
SDK ships `gcc` but no `clang`, so without `llvm22` mounted `odin build` compiles
and then fails at the link step with `clang: command not found`. `enable.sh` adds
it to `PATH` when present and says so plainly when it is not.

## What it installs

[`diags/extension-anatomy.svg`](diags/extension-anatomy.svg) draws how an app
build reaches the compiler: the manifest mounts both extensions, `enable.sh`
wires the paths, and the link step runs through llvm22's clang.

| path | contents |
|---|---|
| `/usr/lib/sdk/odin/odin` | the compiler |
| `/usr/lib/sdk/odin/{core,base,vendor}` | the collections `ODIN_ROOT` points at |
| `/usr/lib/sdk/odin/libLLVM*.so*` | the libLLVM the compiler is linked against |
| `/usr/lib/sdk/odin/enable.sh` | sets `ODIN_ROOT` and `PATH` |
| `/usr/lib/sdk/odin/share/metainfo` | the AppStream component |

The libraries sit beside the binary rather than in a `lib/` directory because
Odin's build links with `-Wl,-rpath=$ORIGIN`.

A consumer that needs the toolchain at **runtime** — an editor whose language
server shells out to `odin check`, say — must copy it into its own `/app`, since
an SDK extension is mounted for the build and gone afterwards.

## Building it

```sh
make deps       # install the SDK and the llvm extension (several GB)
make build      # flatpak-builder --user --install --force-clean
make verify     # manifest parses, shell scripts lint — needs nothing installed
make check      # compile and run a real program with the installed extension
make lint
make clean
```

`verify` is the gate `force-push` uses, because it is cheap and local. `check` is
the one that matters and needs the SDK and the extension actually installed; it
says which is missing rather than reporting a working extension as broken. CI
runs it on every push, which is where it normally runs.

Building needs `org.freedesktop.Sdk//25.08` and
`org.freedesktop.Sdk.Extension.llvm22//25.08`; `make build` installs them if they
are absent. A consumer needs neither — the extension ships the libLLVM it was
linked against.

## The compiler patch

The compiler is built from [our Odin fork](https://github.com/Hyperquader-Coders/Odin),
branch `llvm-target-guards`, pinned by commit. It carries one patch.

Odin names each target's `LLVMInitialize*` symbols directly, and
`src/llvm-c/Config/Targets.def` is vendored — it lists every LLVM target
regardless of the LLVM actually being linked. The freedesktop `llvm22` extension
provides X86, AMDGPU, ARM, NVPTX and WebAssembly, but neither AArch64 nor RISCV,
so upstream Odin fails to link here over branches an x86_64 build can never take.

The patch teaches `build_odin.sh` to read `llvm-config --targets-built` and
guards each arm on `ODIN_LLVM_HAS_<TARGET>`. Asking for a target the LLVM does
not provide reports which one and exits 1, instead of failing the build.

The fork is temporary: it returns to `odin-lang/Odin` at a release tag once the
patch is upstream. Until then this extension is not submittable to Flathub, which
is the point of retiring it — see [MoSCoW.md](MoSCoW.md).

## Licence

BSD-3-Clause, the same licence as the compiler it packages. See [LICENSE](LICENSE).
The Odin compiler keeps its own upstream BSD-3-Clause licence.
