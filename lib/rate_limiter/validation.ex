defmodule RateLimiter.Validation do
  @moduledoc """
  Validates a limiter's options, at startup and on reconfiguration.

  `RateLimiter` calls it; clients and algorithm authors do not need to. It
  rejects unknown and repeated options for the limiter and its algorithm alike,
  using `c:RateLimiter.Algorithm.allowed_options/0`, and checks the limiter's
  own values. Algorithms check their own values in
  `c:RateLimiter.Algorithm.init/1` and `c:RateLimiter.Algorithm.reconfigure/3`.

  Every function only checks: it returns `:ok` or
  `{:error, %RateLimiter.OptionError{}}` and never changes the options. A list
  with several faults reports the first of: unknown options, repeated options,
  the limiter's values.
  """

  alias RateLimiter.{OptionError, Options}

  @start_keys [:name, :algorithm, :max_waiting, :max_active, :clock, :send_after]
  @reconfigure_keys [:max_active, :max_waiting]

  @doc """
  Checks the options given to `RateLimiter.start_link/1`.

  Requires `:algorithm`, an atom other than `nil`, `true`, or `false`, and
  accepts only `:name`, `:algorithm`, `:max_waiting`, `:max_active`, `:clock`,
  `:send_after`, and the algorithm's `allowed_options/0`, each once. Then
  requires `:name`, an atom of the same kind, and `:max_waiting` and
  `:max_active`, positive integers. The algorithm's values are left to its
  `init/1`.

  Any other atom given as `:algorithm` that does not implement
  `RateLimiter.Algorithm` is a programming error and raises when its
  `allowed_options/0` is called.
  """
  @spec reject_invalid_start_options(keyword()) :: :ok | {:error, OptionError.t()}
  def reject_invalid_start_options(opts) when is_list(opts) do
    with {:ok, algorithm} <- Options.fetch_atom(opts, :algorithm),
         :ok <-
           Options.reject_unknown_or_duplicate(opts, @start_keys ++ algorithm.allowed_options()),
         {:ok, _} <- Options.fetch_atom(opts, :name),
         :ok <- Options.reject_non_positive_integer(opts, :max_waiting) do
      Options.reject_non_positive_integer(opts, :max_active)
    end
  end

  @doc """
  Checks a reconfiguration request before it reaches the limiter.

  Returns an error with reason `:empty` for `[]`, and `:ok` for any other list.
  `RateLimiter.reconfigure/2` calls it in the caller, so an empty request is
  rejected even when the limiter is not running.
  """
  @spec reject_empty_reconfiguration(keyword()) :: :ok | {:error, OptionError.t()}
  def reject_empty_reconfiguration([]),
    do: {:error, OptionError.exception(key: nil, value: [], reason: :empty)}

  def reject_empty_reconfiguration(opts) when is_list(opts), do: :ok

  @doc """
  Checks the options of a reconfiguration of a limiter running `algorithm`.

  Rejects `[]` as `reject_empty_reconfiguration/1` does, and accepts only
  `:max_active`, `:max_waiting`, and the algorithm's `allowed_options/0`, each
  once. Then checks `:max_waiting` and `:max_active`, when given, are positive
  integers. The algorithm's values are left to its `reconfigure/3`.
  """
  @spec reject_invalid_reconfiguration(module(), keyword()) :: :ok | {:error, OptionError.t()}
  def reject_invalid_reconfiguration(algorithm, opts)
      when is_atom(algorithm) and is_list(opts) do
    with :ok <- reject_empty_reconfiguration(opts),
         :ok <-
           Options.reject_unknown_or_duplicate(
             opts,
             @reconfigure_keys ++ algorithm.allowed_options()
           ),
         :ok <- Options.reject_non_positive_integer_if_given(opts, :max_waiting) do
      Options.reject_non_positive_integer_if_given(opts, :max_active)
    end
  end
end
