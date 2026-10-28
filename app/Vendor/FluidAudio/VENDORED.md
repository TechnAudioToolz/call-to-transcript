# FluidAudio (vendored)

FluidAudio 0.17.7 from https://github.com/FluidInference/FluidAudio (Apache 2.0, see LICENSE),
with its library sources only (no command-line tool or tests) and two changes:

- `Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerModels.swift`: on macOS 14 the FBank model
  may use the GPU. macOS 14 has an Apple bug in Core ML's CPU path (BNNS) that crashed every
  speaker-separation test run on Apple Silicon (`EXC_BAD_ACCESS` in `BNNSGraphContextExecute_v2`,
  FluidAudio issue #878). Apple fixed it in macOS 15, where the original CPU setting is kept.

- `Sources/FluidAudio/Enhancement/LocalVQE/LocalVqeManager.swift`: the downloading initializer takes an
  optional `directory`, so the noise-removal model is kept with the app's other models.

To update: copy `Sources/FluidAudio`, `Sources/FastClusterWrapper`, `Sources/MachTaskSelfWrapper` and
`LICENSE` from the new release, trim its `Package.swift` the same way, and apply the change again.
