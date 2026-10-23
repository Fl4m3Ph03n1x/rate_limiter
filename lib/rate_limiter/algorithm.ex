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

  ## Options

  `allowed_options/0` names every option the algorithm reads. The limiter
  rejects unknown and repeated options before calling `init/1` or
  `reconfigure/3`, so these check only values. They return
  `{:error, %RateLimiter.OptionError{}}` instead of raising. `RateLimiter.Options`
  covers common checks; build any other error with
  `RateLimiter.OptionError.exception/1`, passing `:details` to say what was
  expected.
  """

  alias RateLimiter.OptionError

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
  Lists every option that `init/1` and `reconfigure/3` read.

  The limiter rejects any other option, at startup and on reconfiguration,
  before calling them.
  """
  @callback allowed_options() :: [atom()]

  @doc """
  Builds the initial state from the limiter's options.

  Receives the whole option list, the limiter's own options included, and reads
  only its own. Returns `{:error, %RateLimiter.OptionError{}}` when one of them
  is missing or invalid, so a misconfigured limiter never starts.
  """
  @callback init(keyword()) :: {:ok, state()} | {:error, OptionError.t()}

  @doc """
  Changes the settings of a running algorithm at `now`.

  Receives only the options being changed, a non-empty subset of
  `allowed_options/0` when called by the limiter. Settle the state under the
  old settings at `now` before applying the new ones, so a change never grants
  a burst. Returns `{:error, %RateLimiter.OptionError{}}` for an invalid value;
  the limiter then keeps the old state, so a change applies entirely or not at
  all.
  """
  @callback reconfigure(state(), keyword(), now()) :: {:ok, state()} | {:error, OptionError.t()}

  @doc """
  Reports whether one task may start at `now`.

  The algorithm alone decides when work may start. `{:ok, state}` authorizes
  exactly one immediate start. `{:wait, wait_time, state}` defers. A
  zero-millisecond wait is not a wait and must be reported as `{:ok, state}`.
  """
  @callback acquire(state(), now()) :: {:ok, state()} | {:wait, wait_time(), state()}
end
