defmodule TinyLasers do
  @moduledoc """
  Isolated multi-language execution + build sandbox on the BEAM.

  Architecture (see README): everything untrusted runs as BEAM-native or WASM-on-Washy —
  never on the host CPU (no NIFs). Three lanes by speed:

    1. `TinyLasers.Gate` — JS → native BEAM, confined by a handle-capability gate. No WASM.
    2. recompile → WASM → BEAM (the lever: better WASM→BEAM lowering) — systems languages.
    3. emulate → WASM (blink/v86) → BEAM — the prebuilt-binary fallback.

  This repo is the substrate. It depends on nothing in `nexus`; `nexus` will depend on it.
  """
end
