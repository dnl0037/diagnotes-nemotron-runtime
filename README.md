# DiagNotes Nemotron runtime

Pinned build recipe and binary releases for the optional local Nemotron ASR runtime used by DiagNotes.

This repository does **not** contain a speech model, audio, transcripts, captions, user data, or DiagNotes application code. The runtime and model have separate licenses. A consumer must obtain and accept the model terms independently.

## Frozen identity

- Runtime: `nemo-speech-v0.1.0-diagnotes-lid.3`
- Upstream: NeMo-Speech.cpp commit `4f9676226f667d14608487df744f375db87127f8`
- Functional patch: `realtime-language-v1.patch`, 1,793 bytes, SHA-256 `80370907878F346B16AD27933B1CF9109C0C204198702D5307CD4C6434D63E84`
- Windows x86_64 CPU and CUDA builds; CUDA architectures `75;80;86;89` (never `native`)
- Runtime capability: `realtime-language-v1`
- CUDA Toolkit: official 12.8.0 network installer, SHA-256 `89E7C44B526B6E30EC5089F221E918090D11F1D5B33C48FBFE08C6AC13F8A95C`; only compiler/runtime/cuBLAS/Thrust subpackages, never the display driver

The CUDA package requires a compatible NVIDIA driver supplied by the host. It does not redistribute the driver or the model. Only an RTX 3060 (`sm86`) is physically validated for this release; `sm75`, `sm80`, and `sm89` are compiled but untested hardware surfaces.

Both packages use the upstream `x64-windows-static-md` profile: vcpkg libraries are static and the Release MSVC CRT is dynamic. Required Microsoft CRT DLLs are copied app-local from the Redist directory of the effective toolchain, so consumers do not need Visual Studio. Each ZIP includes the applicable Visual Studio license terms, the official REDIST list, PE closure, versions, origins, and SHA-256 hashes. The informational Visual C++ Runtime license alone is not treated as redistribution permission.

## Build

The manually dispatched workflow builds final ZIP bytes on GitHub-hosted Windows runners, records the effective toolchain, uploads the bytes, and produces GitHub artifact attestations. Actions are pinned by full commit SHA and have no release-write permission. Release creation and publication are deliberately outside the workflow.

```powershell
pwsh .\scripts\Build-Runtime.ps1 -Backend cpu -Configuration Release
pwsh .\scripts\Build-Runtime.ps1 -Backend cuda -CudaArch '75;80;86;89' -Configuration Release
```

No output is reproducible byte-for-byte because the hosted Windows image and MSVC toolset are recorded rather than content-addressed. Provenance attestation links final ZIP digests to the workflow; it does not establish compiler safety, legal compliance, or absence of vulnerabilities.

## License

Repository recipe and the upstream runtime are Apache-2.0. Bundled third-party notices and license texts are included inside each ZIP. See [NOTICE](NOTICE). The Nemotron model is not included and is governed separately by NVIDIA Open Model Development and Distribution License 1.1.
