defmodule RateLimiter.LeakyBucket do
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

  alias RateLimiter.Algorithm

  @typedoc "The minimum gap between starts, and the previous actual start."
  @type t :: %__MODULE__{
          interval: pos_integer(),
          last_start_at: integer() | nil
        }

  @enforce_keys [:interval]
  defstruct [:interval, last_start_at: nil]

  @doc """
  Builds the pacing state from the limiter's options.

  Requires `:requests_per_second`, an integer in `1..#{@milliseconds_per_second}`,
  and ignores every other option.
  """
  @impl Algorithm
  @spec init(keyword()) :: t()
  def init(opts) do
    requests_per_second = Keyword.fetch!(opts, :requests_per_second)

    if not is_integer(requests_per_second) or requests_per_second <= 0 or
         requests_per_second > @milliseconds_per_second do
      raise ArgumentError,
            ":requests_per_second must be an integer greater than 0 and less than or equal to #{@milliseconds_per_second}, got: #{inspect(requests_per_second)}"
    end

    interval = div(@milliseconds_per_second + requests_per_second - 1, requests_per_second)

    %__MODULE__{
      interval: interval
    }
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
end
