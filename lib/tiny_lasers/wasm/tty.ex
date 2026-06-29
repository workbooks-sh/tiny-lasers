defmodule TinyLasers.Wasm.Tty do
  @moduledoc """
  WASIX §4 virtual-terminal state — ONE home for the configurable TTY/termios surface so
  crossterm/ratatui-class TUIs engage. Backs the `tty_get`/`tty_set` host imports and the
  `isatty` path that `fd_fdstat_get` derives from (stdio fds 0/1/2 → char device when a tty
  is attached).

  State lives in the process dict under `:tl_tty` (per-guest-process, like `:tl_mem` /
  `:tl_sockstate`). Shape:

      %{
        cols: 80, rows: 24, width_px: 0, height_px: 0,
        stdin_tty: bool, stdout_tty: bool, stderr_tty: bool,
        echo: true, line_buffered: true, line_feeds: true, raw: false
      }

  ## Attach-default decision
  The `*_tty` flags DEFAULT TO FALSE. Rationale: this matches the `node:tty` JS stub
  (`compilers/js/node/85_tty.js` reports `isatty=false`) and is the safe default for color
  libraries in a headless sandbox — they degrade to no-color rather than emitting escape
  sequences into a non-terminal sink. A TUI test/deploy that genuinely wants a terminal calls
  `attach/1` (the §8 oracle crates like ratatui do exactly this) to turn the flags on and set
  the window size. `detach/0` is the inverse.
  """

  @defaults %{
    cols: 80,
    rows: 24,
    width_px: 0,
    height_px: 0,
    stdin_tty: false,
    stdout_tty: false,
    stderr_tty: false,
    echo: true,
    line_buffered: true,
    line_feeds: true,
    raw: false
  }

  @doc "The current virtual-tty state, installing defaults on first read."
  @spec get() :: map()
  def get do
    case Process.get(:tl_tty) do
      nil ->
        Process.put(:tl_tty, @defaults)
        @defaults

      state ->
        state
    end
  end

  @doc "Merge `updates` into the current state."
  @spec put(map()) :: map()
  def put(updates) when is_map(updates) do
    state = Map.merge(get(), updates)
    Process.put(:tl_tty, state)
    state
  end

  @doc """
  Attach a virtual terminal: set stdin/stdout/stderr_tty true. Accepts optional `:cols`/`:rows`
  (and `:width_px`/`:height_px`). This is the one call a TUI test/deploy uses to turn the tty on.
  """
  @spec attach(keyword() | map()) :: map()
  def attach(opts \\ []) do
    size = opts |> Map.new() |> Map.take([:cols, :rows, :width_px, :height_px])
    put(Map.merge(%{stdin_tty: true, stdout_tty: true, stderr_tty: true}, size))
  end

  @doc "Detach: all `*_tty` flags false."
  @spec detach() :: map()
  def detach do
    put(%{stdin_tty: false, stdout_tty: false, stderr_tty: false})
  end

  @doc "Is `fd` a tty? fd 0→stdin_tty, 1→stdout_tty, 2→stderr_tty, else false."
  @spec isatty?(integer()) :: boolean()
  def isatty?(0), do: get().stdin_tty
  def isatty?(1), do: get().stdout_tty
  def isatty?(2), do: get().stderr_tty
  def isatty?(_), do: false

  @doc """
  Toggle raw (cbreak) mode. raw=true ⇒ echo=false, line_buffered=false; raw=false restores
  echo=true, line_buffered=true. (Real line-discipline input editing is deferred — see bd.)
  """
  @spec set_raw(boolean()) :: map()
  def set_raw(true), do: put(%{raw: true, echo: false, line_buffered: false})
  def set_raw(false), do: put(%{raw: false, echo: true, line_buffered: true})
end
