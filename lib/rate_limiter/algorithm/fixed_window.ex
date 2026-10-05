defmodule RateLimiter.Algorithm.FixedWindow do
  @moduledoc """
  Allows up to `:requests_per_window` starts in each window of
  `:window_duration_ms` milliseconds.

  Within a window, work starts at once until the limit is reached. Later work
  waits for the window to end, and the next window allows a full limit again.
  Up to twice `:requests_per_window` starts can happen within one window's
  duration: a full window ending, then a full window starting.

  Windows are not aligned to wall-clock time or to any upstream service's
  windows, because `now` is monotonic and local to the node.

  ## Where windows start

  Fixed windows can be placed in two ways:

    * On demand: a window opens at the first start after the previous one has
      ended. An idle period never leaves a partly used window; the next start
      always gets a whole one.
    * On a fixed grid, anchored at the first start: windows follow each other
      back to back whether or not work arrives. A start just before a grid
      boundary gets only what remains of that window.

  This module opens windows on demand. It is simpler, and every window it opens
  is whole.

  Described in:
  https://www.geeksforgeeks.org/system-design/rate-limiting-algorithms-system-design/
  """

  @behaviour RateLimiter.Algorithm

  alias RateLimiter.Algorithm
  alias RateLimiter.Options

  @typedoc "The limit and duration of each window, when the current one opened, and its starts so far."
  @type t :: %__MODULE__{
          requests_per_window: pos_integer(),
          window_duration_ms: pos_integer(),
          window_started_at: integer() | nil,
          requests_in_current_window: non_neg_integer()
        }

  @enforce_keys [:requests_per_window, :window_duration_ms]
  defstruct [
    :requests_per_window,
    :window_duration_ms,
    window_started_at: nil,
    requests_in_current_window: 0
  ]

  @doc """
  Builds the pacing state from the limiter's options.

  Requires `:requests_per_window` and `:window_duration_ms`, both positive
  integers, and ignores every other option.
  """
  @impl Algorithm
  @spec init(keyword()) :: t()
  def init(opts) do
    requests_per_window = Options.positive_integer!(opts, :requests_per_window)
    window_duration_ms = Options.positive_integer!(opts, :window_duration_ms)

    %__MODULE__{
      requests_per_window: requests_per_window,
      window_duration_ms: window_duration_ms
    }
  end

  @impl Algorithm
  @spec acquire(t(), Algorithm.now()) :: {:ok, t()} | {:wait, Algorithm.wait_time(), t()}
  def acquire(%__MODULE__{window_started_at: nil} = state, now) do
    {:ok, %__MODULE__{state | window_started_at: now, requests_in_current_window: 1}}
  end

  def acquire(
        %__MODULE__{window_started_at: window_started_at, window_duration_ms: window_duration_ms} =
          state,
        now
      )
      when now - window_started_at >= window_duration_ms do
    {:ok, %__MODULE__{state | window_started_at: now, requests_in_current_window: 1}}
  end

  def acquire(
        %__MODULE__{
          window_started_at: window_started_at,
          window_duration_ms: window_duration_ms,
          requests_in_current_window: requests_in_current_window,
          requests_per_window: requests_per_window
        } = state,
        now
      ) do
    if requests_in_current_window < requests_per_window do
      {:ok, %__MODULE__{state | requests_in_current_window: requests_in_current_window + 1}}
    else
      {:wait, window_duration_ms - (now - window_started_at), state}
    end
  end
end
