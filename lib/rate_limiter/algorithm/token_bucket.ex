defmodule RateLimiter.Algorithm.TokenBucket do
  @moduledoc """
  Allows bursts from a bucket of tokens that refills at a steady rate.

  The bucket starts full. Each start spends one token, and one token returns
  every `:refill_interval_ms` milliseconds until the bucket holds
  `:bucket_size` again. While tokens remain, work starts at once; when they run
  out, starts follow the refill interval. Up to `:bucket_size` starts can happen
  at once, and at most `:bucket_size` plus `n` in any span of `n` intervals.

  Adapted from the token bucket in:
  https://akoutmos.com/post/rate-limiting-with-genservers/
  """

  @behaviour RateLimiter.Algorithm

  alias RateLimiter.{Algorithm, OptionError, Options}

  @typedoc "The bucket's capacity, refill interval, tokens left, and last refill."
  @type t :: %__MODULE__{
          bucket_size: pos_integer(),
          refill_interval_ms: pos_integer(),
          tokens: non_neg_integer(),
          refilled_at: integer() | nil
        }

  @enforce_keys [:bucket_size, :refill_interval_ms, :tokens]
  defstruct [:bucket_size, :refill_interval_ms, :tokens, refilled_at: nil]

  @impl Algorithm
  @spec allowed_options :: [atom()]
  def allowed_options, do: [:bucket_size, :refill_interval_ms]

  @doc """
  Builds a full bucket from the limiter's options.

  Requires `:bucket_size` and `:refill_interval_ms`, both positive integers, and
  ignores every other option.
  """
  @impl Algorithm
  @spec init(keyword()) :: {:ok, t()} | {:error, OptionError.t()}
  def init(opts) do
    with {:ok, bucket_size} <- Options.fetch_positive_integer(opts, :bucket_size),
         {:ok, refill_interval_ms} <- Options.fetch_positive_integer(opts, :refill_interval_ms) do
      {:ok,
       %__MODULE__{
         bucket_size: bucket_size,
         refill_interval_ms: refill_interval_ms,
         tokens: bucket_size
       }}
    end
  end

  @doc """
  Changes `:bucket_size`, `:refill_interval_ms`, or both, at `now`.

  Tokens earned up to `now` are counted under the old settings first. A smaller
  bucket drops the tokens above its new size; a larger one gains none and fills
  at the refill rate. A new refill interval restarts the refill at `now`,
  discarding partial progress; an unchanged interval keeps it. An unused bucket
  keeps its tokens up to the new size and starts refilling at its first start.
  """
  @impl Algorithm
  @spec reconfigure(t(), keyword(), Algorithm.now()) :: {:ok, t()} | {:error, OptionError.t()}
  def reconfigure(%__MODULE__{} = state, opts, now) do
    with {:ok, bucket_size} <-
           Options.fetch_optional_positive_integer(opts, :bucket_size, state.bucket_size),
         {:ok, refill_interval_ms} <-
           Options.fetch_optional_positive_integer(
             opts,
             :refill_interval_ms,
             state.refill_interval_ms
           ) do
      settled = settle(state, now)

      {:ok,
       %__MODULE__{
         settled
         | bucket_size: bucket_size,
           refill_interval_ms: refill_interval_ms,
           tokens: min(settled.tokens, bucket_size),
           refilled_at: refilled_at(settled, refill_interval_ms, now)
       }}
    end
  end

  @impl Algorithm
  @spec acquire(t(), Algorithm.now()) :: {:ok, t()} | {:wait, Algorithm.wait_time(), t()}
  def acquire(%__MODULE__{refilled_at: nil} = state, now) do
    acquire(%__MODULE__{state | refilled_at: now}, now)
  end

  def acquire(%__MODULE__{} = state, now) do
    case refill(state, now) do
      %__MODULE__{tokens: 0, refilled_at: refilled_at, refill_interval_ms: interval} = refilled ->
        {:wait, refilled_at + interval - now, refilled}

      %__MODULE__{tokens: tokens} = refilled ->
        {:ok, %__MODULE__{refilled | tokens: tokens - 1}}
    end
  end

  ###########
  # PRIVATE #
  ###########

  # A full bucket earns nothing, so its next token is timed from now.
  @spec refill(t(), Algorithm.now()) :: t()
  defp refill(%__MODULE__{} = state, now) do
    earned = div(now - state.refilled_at, state.refill_interval_ms)

    if state.tokens + earned >= state.bucket_size do
      %__MODULE__{state | tokens: state.bucket_size, refilled_at: now}
    else
      %__MODULE__{
        state
        | tokens: state.tokens + earned,
          refilled_at: state.refilled_at + earned * state.refill_interval_ms
      }
    end
  end

  # Counts what the old settings earned up to now, so a change cannot recount it.
  @spec settle(t(), Algorithm.now()) :: t()
  defp settle(%__MODULE__{refilled_at: nil} = state, _now), do: state
  defp settle(%__MODULE__{} = state, now), do: refill(state, now)

  # A new interval discards partial progress, which would otherwise earn several tokens at once.
  @spec refilled_at(t(), pos_integer(), Algorithm.now()) :: integer() | nil
  defp refilled_at(%__MODULE__{refilled_at: nil}, _refill_interval_ms, _now), do: nil

  defp refilled_at(
         %__MODULE__{refilled_at: refilled_at, refill_interval_ms: refill_interval_ms},
         refill_interval_ms,
         _now
       ),
       do: refilled_at

  defp refilled_at(%__MODULE__{}, _refill_interval_ms, now), do: now
end
