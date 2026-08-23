# DiagNotes Nemotron runtime

Pinned build recipe and binary releases for the optional local Nemotron ASR runtime used by DiagNotes.

This repository does **not** contain a speech model, audio, transcripts, captions, user data, or DiagNotes application code. The runtime and model have separate licenses. A consumer must obtain and accept the model terms independently.

## Frozen identity

- Runtime: `nemo-speech-v0.1.0-diagnotes-lid.4`
- Upstream: NeMo-Speech.cpp commit `4f9676226f667d14608487df744f375db87127f8`
- Functional patch: `realtime-language-v1.patch`, 1,793 bytes, SHA-256 `80370907878F346B16AD27933B1CF9109C0C204198702D5307CD4C6434D63E84`
- Windows x86_64 CPU and CUDA builds; CUDA architectures `75;80;86;89` (never `native`)
- Runtime capability: `realtime-language-v1`
- CUDA Toolkit: official 12.8.0 network installer, SHA-256 `89E7C44B526B6E30EC5089F221E918090D11F1D5B33C48FBFE08C6AC13F8A95C`; only compiler/runtime/cuBLAS/Thrust subpackages, never the display driver

The CUDA package requires a compatible NVIDIA driver supplied by the host. It does not redistribute the driver or the model. Only an RTX 3060 (`sm86`) is physically validated for this release; `sm75`, `sm80`, and `sm89` are compiled but untested hardware surfaces.

Both packages use the upstream `x64-windows-static-md` profile: vcpkg libraries are static and the Release MSVC CRT is dynamic. Required Microsoft CRT DLLs are copied app-local from the Redist directory of the effective toolchain, so consumers do not need Visual Studio. Each ZIP includes the applicable Visual Studio license terms, the official REDIST list, PE closure, versions, origins, and SHA-256 hashes. The informational Visual C++ Runtime license alone is not treated as redistribution permission.

## Local release-candidate provenance

The `lid.4` release candidates use `local-build-local-verification` provenance. They were built and tested locally from fresh roots, then frozen at these exact digests:

- CPU: 2,640,737 bytes; SHA-256 `26357B22CF0A4B7B59D980AD06068C998339DF21F76B5A57FA381CD238D2889B`
- CUDA: 170,665,359 bytes; SHA-256 `89CA829838353F81F920C75B829C82C7B68F02DA275D704DD71B099B5EE6240D`

GitHub only hosts the draft assets. It did not build these bytes, and this repository does not claim SLSA or GitHub Actions build provenance for them. The historical build workflow is not the provenance of these candidates.

The local promotion helpers verify the frozen sizes and hashes, scan each ZIP and a fresh extraction with Microsoft Defender, close inventory/SBOM/licenses/NOTICE/patch/PE dependencies, reject models and private paths, assemble the seven release assets outside the checkout, and verify an authenticated draft redownload. They never build or modify either ZIP:

```powershell
pwsh .\scripts\Test-LocalRuntimePromotion.ps1 -CpuZipPath <cpu.zip> -CudaZipPath <cuda.zip> -CpuAcceptanceEvidencePath <cpu-acceptance.json> -CudaAcceptanceEvidencePath <cuda-acceptance.json> -AssetRoot <prepared-asset-root>
pwsh .\scripts\Prepare-LocalRuntimeDraft.ps1 -CpuZipPath <cpu.zip> -CudaZipPath <cuda.zip> -CpuAcceptanceEvidencePath <cpu-acceptance.json> -CudaAcceptanceEvidencePath <cuda-acceptance.json> -WorkRoot <fresh-work-root> -AssetRoot <fresh-asset-root>
pwsh .\scripts\Publish-LocalRuntimeDraft.ps1 -AssetRoot <asset-root> -DownloadRoot <fresh-download-root> -EvidencePath <new-evidence.json>
```

The draft targets the exact pushed `main` commit containing these promotion helpers and this README. It remains non-consumer-ready until separately fiscalized and explicitly published. The compatible model is not included and must be obtained under its separate license.

## License

Repository recipe and the upstream runtime are Apache-2.0. Bundled third-party notices and license texts are included inside each ZIP. See [NOTICE](NOTICE). The Nemotron model is not included and is governed separately by NVIDIA Open Model Development and Distribution License 1.1.
