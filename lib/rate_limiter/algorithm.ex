defmodule RateLimiter.Algorithm do
  @moduledoc """
  Decides when a limiter may start its next task.

  An algorithm owns pacing and nothing else. The limiter process keeps the
  waiting queue, admission, task supervision, and concurrency, and consults an
  algorithm only to ask whether a start is allowed yet. A second algorithm
  therefore never has to reimplement any of that.

  Implementations must be pure: no processes, no timers, and no clock reads.
  Every decision follows from the state and the `now` handed in, which is what
  makes pacing deterministic under test.
  """

  @typedoc """
  Implementation-private pacing state.

  The limiter stores it and threads it back unchanged. Only the implementation
  that produced it may inspect it.
  """
  @type state() :: any()

  @typedoc "A monotonic timestamp in milliseconds, which may be negative and may repeat."
  @type now() :: integer()

  @typedoc "Milliseconds to wait before asking again; always strictly positive."
  @type wait_time() :: pos_integer()

  @doc """
  Builds the initial state from instance options.

  Raises `KeyError` when a required option is absent and `ArgumentError` when a
  supplied value is invalid, so a misconfigured limiter fails at startup rather
  than on its first request.
  """
  @callback init(keyword()) :: state()

  @doc """
  Reports whether one task may start at `now`.

  The algorithm alone decides when work may start. `{:ok, state}` authorizes
  exactly one immediate start. `{:wait, wait_time, state}` defers. A
  zero-millisecond wait is not a wait and must be reported as `{:ok, state}`.
  """
  @callback acquire(state(), now()) :: {:ok, state()} | {:wait, wait_time(), state()}
end
