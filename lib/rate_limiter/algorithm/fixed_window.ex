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

  alias RateLimiter.{Algorithm, OptionError, Options}

  @typedoc """
  The limit and duration of each window, when the current one opened, its starts
  so far, and any change waiting for the next window.
  """
  @type t :: %__MODULE__{
          requests_per_window: pos_integer(),
          window_duration_ms: pos_integer(),
          window_started_at: integer() | nil,
          requests_in_current_window: non_neg_integer(),
          next_window:
            %{requests_per_window: pos_integer(), window_duration_ms: pos_integer()} | nil
        }

  @enforce_keys [:requests_per_window, :window_duration_ms]
  defstruct [
    :requests_per_window,
    :window_duration_ms,
    window_started_at: nil,
    requests_in_current_window: 0,
    next_window: nil
  ]

  @impl Algorithm
  @spec allowed_options :: [atom()]
  def allowed_options, do: [:requests_per_window, :window_duration_ms]

  @doc """
  Builds the pacing state from the limiter's options.

  Requires `:requests_per_window` and `:window_duration_ms`, both positive
  integers, and ignores every other option.
  """
  @impl Algorithm
  @spec init(keyword()) :: {:ok, t()} | {:error, OptionError.t()}
  def init(opts) do
    with {:ok, requests_per_window} <- Options.positive_integer(opts, :requests_per_window),
         {:ok, window_duration_ms} <- Options.positive_integer(opts, :window_duration_ms) do
      {:ok,
       %__MODULE__{
         requests_per_window: requests_per_window,
         window_duration_ms: window_duration_ms
       }}
    end
  end

  @doc """
  Changes `:requests_per_window`, `:window_duration_ms`, or both, from the next
  window.

  The current window keeps its limit and duration, so a change never lets more
  starts into it. Options not given keep their current values, and a later
  change replaces a pending one entirely. Before the first window opens, the
  change applies at once.
  """
  @impl Algorithm
  @spec reconfigure(t(), keyword(), Algorithm.now()) :: {:ok, t()} | {:error, OptionError.t()}
  def reconfigure(%__MODULE__{} = state, opts, _now) do
    with {:ok, requests_per_window} <-
           Options.optional_positive_integer(
             opts,
             :requests_per_window,
             state.requests_per_window
           ),
         {:ok, window_duration_ms} <-
           Options.optional_positive_integer(opts, :window_duration_ms, state.window_duration_ms) do
      next_window = %{
        requests_per_window: requests_per_window,
        window_duration_ms: window_duration_ms
      }

      {:ok, schedule_change(state, next_window)}
    end
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
    {:ok,
     %__MODULE__{
       apply_next_window(state)
       | window_started_at: now,
         requests_in_current_window: 1
     }}
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

  ###########
  # PRIVATE #
  ###########

  # Before the first window there is no current window to finish, so a change applies at once.
  @spec schedule_change(t(), map()) :: t()
  defp schedule_change(%__MODULE__{window_started_at: nil} = state, next_window),
    do: apply_next_window(%__MODULE__{state | next_window: next_window})

  defp schedule_change(%__MODULE__{} = state, next_window),
    do: %__MODULE__{state | next_window: next_window}

  @spec apply_next_window(t()) :: t()
  defp apply_next_window(%__MODULE__{next_window: nil} = state), do: state

  defp apply_next_window(
         %__MODULE__{
           next_window: %{
             requests_per_window: requests_per_window,
             window_duration_ms: window_duration_ms
           }
         } = state
       ) do
    %__MODULE__{
      state
      | requests_per_window: requests_per_window,
        window_duration_ms: window_duration_ms,
        next_window: nil
    }
  end
end
