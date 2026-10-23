defmodule RateLimiter.Options do
  @moduledoc """
  Validates the options of function calls, usually passed as keyword lists.

  Functions named `fetch_*` return `{:ok, value}` and functions named `reject_*`
  return `:ok`. Both return `{:error, %RateLimiter.OptionError{}}` for invalid
  options instead of raising, so callers can reject them without crashing.
  """

  alias RateLimiter.OptionError

  @doc """
  Fetches `key` from `opts` and returns `{:ok, value}`, whatever the value.

  Returns a `RateLimiter.OptionError` with reason `:missing` when `key` is
  absent.
  """
  @spec fetch(keyword(), atom()) :: {:ok, any()} | {:error, OptionError.t()}
  def fetch(opts, key) when is_list(opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error, OptionError.exception(key: key, value: nil, reason: :missing)}
    end
  end

  @doc """
  Fetches `key` from `opts` and returns `{:ok, value}` if it is an atom other
  than `nil`, `true`, or `false`, such as a module or a registered name.

  Returns a `RateLimiter.OptionError` with reason `:missing` when `key` is
  absent, and `:invalid` when its value is not such an atom.
  """
  @spec fetch_atom(keyword(), atom()) :: {:ok, atom()} | {:error, OptionError.t()}
  def fetch_atom(opts, key) when is_list(opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value}
      when is_atom(value) and value not in [nil, false, true] ->
        {:ok, value}

      {:ok, value} ->
        {:error,
         OptionError.exception(
           key: key,
           value: value,
           reason: :invalid,
           details: "expected a valid module name"
         )}

      :error ->
        {:error, OptionError.exception(key: key, value: nil, reason: :missing)}
    end
  end

  @doc """
  Fetches `key` from `opts` and returns `{:ok, value}` if it is a positive
  integer.

  Returns a `RateLimiter.OptionError` with reason `:missing` when `key` is
  absent, and `:invalid` when its value is not a positive integer.
  """
  @spec fetch_positive_integer(keyword(), atom()) ::
          {:ok, pos_integer()} | {:error, OptionError.t()}
  def fetch_positive_integer(opts, key) when is_list(opts) and is_atom(key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, value} ->
        {:error,
         OptionError.exception(
           key: key,
           value: value,
           reason: :invalid,
           details: "expected a positive integer (> 0)"
         )}

      :error ->
        {:error,
         OptionError.exception(
           key: key,
           value: nil,
           reason: :missing
         )}
    end
  end

  @doc """
  Works like `fetch_positive_integer/2`, but returns `{:ok, default}` when `key`
  is missing.
  """
  @spec fetch_optional_positive_integer(keyword(), atom(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, OptionError.t()}
  def fetch_optional_positive_integer(opts, key, default)
      when is_list(opts) and is_atom(key) and is_integer(default) and default > 0 do
    if Keyword.has_key?(opts, key) do
      fetch_positive_integer(opts, key)
    else
      {:ok, default}
    end
  end

  @doc """
  Fetches `key` from `opts` and returns `{:ok, value}` if it is an integer in
  `range`.

  Returns a `RateLimiter.OptionError` with reason `:missing` when `key` is
  absent, and `:invalid` when its value is not an integer in `range`.
  """
  @spec fetch_integer_in_range(keyword(), atom(), Range.t()) ::
          {:ok, integer()} | {:error, OptionError.t()}
  def fetch_integer_in_range(opts, key, %Range{} = range) when is_list(opts) and is_atom(key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if is_integer(value) and value in range do
          {:ok, value}
        else
          {:error,
           OptionError.exception(
             key: key,
             value: value,
             reason: :invalid,
             details:
               "expected an integer in range #{range.first}..#{range.last} with step #{range.step}"
           )}
        end

      :error ->
        {:error,
         OptionError.exception(
           key: key,
           value: nil,
           reason: :missing
         )}
    end
  end

  @doc """
  Returns `:ok` when every key in `opts` is one of `allowed_keys`.

  Otherwise returns a `RateLimiter.OptionError` with reason `:unknown`, naming
  each unknown key once.
  """
  @spec reject_unknown(keyword(), [atom()]) :: :ok | {:error, OptionError.t()}
  def reject_unknown(opts, allowed_keys) when is_list(opts) and is_list(allowed_keys) do
    all_keys =
      opts
      |> Keyword.keys()
      |> Enum.uniq()

    unknown_keys = all_keys -- allowed_keys

    if unknown_keys == [] do
      :ok
    else
      unknown_entries = Enum.filter(opts, fn {key, _value} -> key in unknown_keys end)

      {:error,
       OptionError.exception(
         key: unknown_keys,
         value: unknown_entries,
         reason: :unknown,
         details: "allowed keys are: #{Enum.join(allowed_keys, ", ")}"
       )}
    end
  end

  @doc """
  Returns `:ok` when no key appears more than once in `opts`.

  Otherwise returns a `RateLimiter.OptionError` with reason `:duplicate`,
  naming each repeated key once.
  """
  @spec reject_duplicate(keyword()) :: :ok | {:error, OptionError.t()}
  def reject_duplicate(opts) when is_list(opts) do
    all_keys = Keyword.keys(opts)

    duplicate_keys = Enum.uniq(all_keys -- Enum.uniq(all_keys))

    if duplicate_keys == [] do
      :ok
    else
      duplicate_entries = Enum.filter(opts, fn {key, _value} -> key in duplicate_keys end)

      {:error,
       OptionError.exception(
         key: duplicate_keys,
         value: duplicate_entries,
         reason: :duplicate
       )}
    end
  end

  @doc """
  Returns `:ok` when `opts` holds only `allowed_keys`, each at most once.

  Otherwise returns the error from `reject_unknown/2`, or, when every key is
  allowed, from `reject_duplicate/1`.
  """
  @spec reject_unknown_or_duplicate(keyword(), [atom()]) :: :ok | {:error, OptionError.t()}
  def reject_unknown_or_duplicate(opts, allowed_keys)
      when is_list(opts) and is_list(allowed_keys) do
    with :ok <- reject_unknown(opts, allowed_keys) do
      reject_duplicate(opts)
    end
  end

  @doc """
  Returns `:ok` when `key` is absent from `opts` or holds a positive integer.

  Otherwise returns the `:invalid` error from `fetch_positive_integer/2`. Use it
  for an optional key whose value is not needed; to read the value, use
  `fetch_optional_positive_integer/3`.
  """
  @spec reject_non_positive_integer_if_given(keyword(), atom()) ::
          :ok | {:error, OptionError.t()}
  def reject_non_positive_integer_if_given(opts, key) when is_list(opts) and is_atom(key) do
    case fetch_positive_integer(opts, key) do
      {:ok, _} ->
        :ok

      {:error, %OptionError{reason: :missing}} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns `:ok` when `key` holds a positive integer.

  Otherwise returns the error from `fetch_positive_integer/2`: reason `:missing`
  when `key` is absent, and `:invalid` when its value is not a positive integer.
  Use it for a required key whose value is not needed; to read the value, use
  `fetch_positive_integer/2`.
  """
  @spec reject_non_positive_integer(keyword(), atom()) ::
          :ok | {:error, OptionError.t()}
  def reject_non_positive_integer(opts, key) when is_list(opts) and is_atom(key) do
    case fetch_positive_integer(opts, key) do
      {:ok, _} ->
        :ok

      {:error, _} = error ->
        error
    end
  end
end
