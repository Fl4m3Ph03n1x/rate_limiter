defmodule RateLimiter.Algorithm.LeakyBucket do
  @moduledoc """
  Paces starts evenly at one per interval, with no burst and no catch-up.

  Arrivals may fluctuate; output does not. The limiter's queue absorbs the
  variation while this module authorizes one start per interval.

  Originally extracted from:
  https://akoutmos.com/post/rate-limiting-with-genservers/

  The interval rounds up, so three requests per second yields 334 ms rather than
  333 ms and never exceeds the configured rate. Delay earns back nothing: each
  grant is measured from the previous actual start, so a late call cannot
  release a burst of catch-up starts.
  """

  @behaviour RateLimiter.Algorithm

  @milliseconds_per_second 1_000

  alias RateLimiter.{Algorithm, OptionError, Options}

  @typedoc "The minimum gap between starts, and the previous actual start."
  @type t :: %__MODULE__{
          interval: pos_integer(),
          last_start_at: integer() | nil
        }

  @enforce_keys [:interval]
  defstruct [:interval, last_start_at: nil]

  @impl Algorithm
  @spec allowed_options :: [atom()]
  def allowed_options, do: [:requests_per_second]

  @doc """
  Builds the pacing state from the limiter's options.

  Requires `:requests_per_second`, an integer in `1..#{@milliseconds_per_second}`,
  and ignores every other option.
  """
  @impl Algorithm
  @spec init(keyword()) :: {:ok, t()} | {:error, OptionError.t()}
  def init(opts) do
    with {:ok, interval} <- calculate_interval(opts) do
      {:ok, %__MODULE__{interval: interval}}
    end
  end

  @doc """
  Changes the rate, effective for the next start.

  Requires `:requests_per_second`, as `init/1` does. The next start is measured
  from the previous actual start with the new interval, so a raised rate allows
  at most one immediate start and a lowered one waits longer.
  """
  @impl Algorithm
  @spec reconfigure(t(), keyword(), Algorithm.now()) :: {:ok, t()} | {:error, OptionError.t()}
  def reconfigure(%__MODULE__{} = state, opts, _now) do
    with {:ok, interval} <- calculate_interval(opts) do
      {:ok, %__MODULE__{state | interval: interval}}
    end
  end

  @impl Algorithm
  @spec acquire(t(), Algorithm.now()) :: {:ok, t()} | {:wait, Algorithm.wait_time(), t()}
  def acquire(%__MODULE__{last_start_at: nil} = state, now) do
    {:ok, %__MODULE__{state | last_start_at: now}}
  end

  def acquire(%__MODULE__{last_start_at: last_start_at, interval: interval} = state, now) do
    remaining = last_start_at + interval - now

    if remaining > 0 do
      {:wait, remaining, state}
    else
      {:ok, %__MODULE__{state | last_start_at: now}}
    end
  end

  ###########
  # PRIVATE #
  ###########

  @spec calculate_interval(keyword()) :: {:ok, pos_integer()} | {:error, OptionError.t()}
  defp calculate_interval(opts) do
    case Options.integer_in_range(opts, :requests_per_second, 1..@milliseconds_per_second) do
      {:ok, rps} -> {:ok, div(@milliseconds_per_second + rps - 1, rps)}
      {:error, reason} -> {:error, reason}
    end
  end
end
