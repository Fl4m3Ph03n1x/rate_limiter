defmodule RateLimiter.OptionsTest do
  use ExUnit.Case, async: true

  alias RateLimiter.{OptionError, Options}

  describe "positive_integer/2" do
    test "returns a positive integer value" do
      assert Options.positive_integer([rate: 3], :rate) == {:ok, 3}
    end

    test "rejects a missing option" do
      assert Options.positive_integer([burst: 3], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :rate"
                }}
    end

    test "rejects zero" do
      assert Options.positive_integer([rate: 0], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 0,
                  reason: :invalid,
                  message: "invalid value for option: :rate, got: 0"
                }}
    end

    test "rejects a negative integer" do
      assert Options.positive_integer([rate: -1], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: -1,
                  reason: :invalid,
                  message: "invalid value for option: :rate, got: -1"
                }}
    end

    test "rejects a non-integer" do
      assert Options.positive_integer([rate: 1.5], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 1.5,
                  reason: :invalid,
                  message: "invalid value for option: :rate, got: 1.5"
                }}
    end
  end

  describe "optional_positive_integer/3" do
    test "returns the default when the option is missing" do
      assert Options.optional_positive_integer([burst: 3], :rate, 5) == {:ok, 5}
    end

    test "prefers a given value over the default" do
      assert Options.optional_positive_integer([rate: 3], :rate, 5) == {:ok, 3}
    end

    test "rejects an invalid value despite the default" do
      assert Options.optional_positive_integer([rate: 0], :rate, 5) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 0,
                  reason: :invalid,
                  message: "invalid value for option: :rate, got: 0"
                }}
    end

    test "refuses a default that is not a positive integer" do
      assert_raise FunctionClauseError, fn ->
        Options.optional_positive_integer([], :rate, 0)
      end
    end
  end

  describe "reject_unknown/2" do
    test "accepts options that are all allowed" do
      assert Options.reject_unknown([rate: 1, burst: 2], [:rate, :burst]) == :ok
    end

    test "accepts no options" do
      assert Options.reject_unknown([], [:rate]) == :ok
    end

    test "names an unknown option and keeps its entry" do
      assert Options.reject_unknown([rate: 1, foo: 2], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:foo],
                  value: [foo: 2],
                  reason: :unknown,
                  message: "unknown options: [foo: 2]"
                }}
    end

    test "names a repeated unknown option once and keeps every entry" do
      assert Options.reject_unknown([foo: 1, rate: 2, foo: 3], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:foo],
                  value: [foo: 1, foo: 3],
                  reason: :unknown,
                  message: "unknown options: [foo: 1, foo: 3]"
                }}
    end

    test "names several unknown options in the order given" do
      assert Options.reject_unknown([foo: 1, rate: 2, bar: 3], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:foo, :bar],
                  value: [foo: 1, bar: 3],
                  reason: :unknown,
                  message: "unknown options: [foo: 1, bar: 3]"
                }}
    end
  end

  describe "reject_duplicate/1" do
    test "accepts options given once each" do
      assert Options.reject_duplicate(rate: 1, burst: 2) == :ok
    end

    test "names a repeated option and keeps every entry" do
      assert Options.reject_duplicate(rate: 1, burst: 2, rate: 3) ==
               {:error,
                %OptionError{
                  key: [:rate],
                  value: [rate: 1, rate: 3],
                  reason: :duplicate,
                  message: "duplicate options: [rate: 1, rate: 3]"
                }}
    end

    test "names an option given three times only once" do
      assert Options.reject_duplicate(rate: 1, rate: 2, rate: 3) ==
               {:error,
                %OptionError{
                  key: [:rate],
                  value: [rate: 1, rate: 2, rate: 3],
                  reason: :duplicate,
                  message: "duplicate options: [rate: 1, rate: 2, rate: 3]"
                }}
    end
  end

  describe "validate/2" do
    test "accepts allowed options given once each" do
      assert Options.validate([rate: 1, burst: 2], [:rate, :burst]) == :ok
    end

    test "rejects an unknown option" do
      assert Options.validate([rate: 1, foo: 2], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:foo],
                  value: [foo: 2],
                  reason: :unknown,
                  message: "unknown options: [foo: 2]"
                }}
    end

    test "rejects a repeated allowed option" do
      assert Options.validate([rate: 1, rate: 2], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:rate],
                  value: [rate: 1, rate: 2],
                  reason: :duplicate,
                  message: "duplicate options: [rate: 1, rate: 2]"
                }}
    end

    test "reports a repeated unknown option as unknown" do
      assert Options.validate([foo: 1, foo: 2], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:foo],
                  value: [foo: 1, foo: 2],
                  reason: :unknown,
                  message: "unknown options: [foo: 1, foo: 2]"
                }}
    end
  end
end
