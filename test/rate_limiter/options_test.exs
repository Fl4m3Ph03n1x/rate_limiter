defmodule RateLimiter.OptionsTest do
  use ExUnit.Case, async: true

  alias RateLimiter.{OptionError, Options}

  describe "fetch/2" do
    test "returns any value" do
      assert Options.fetch([rate: "anything"], :rate) == {:ok, "anything"}
    end

    test "returns a nil value as present" do
      assert Options.fetch([rate: nil], :rate) == {:ok, nil}
    end

    test "rejects a missing option" do
      assert Options.fetch([burst: 3], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :rate"
                }}
    end
  end

  describe "fetch_atom/2" do
    test "returns an atom value" do
      assert Options.fetch_atom([name: :limiter], :name) == {:ok, :limiter}
    end

    test "returns a module name" do
      assert Options.fetch_atom([algorithm: String], :algorithm) == {:ok, String}
    end

    test "rejects a missing option" do
      assert Options.fetch_atom([burst: 3], :name) ==
               {:error,
                %OptionError{
                  key: :name,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :name"
                }}
    end

    test "rejects a non-atom" do
      assert Options.fetch_atom([name: "limiter"], :name) ==
               {:error,
                %OptionError{
                  key: :name,
                  value: "limiter",
                  reason: :invalid,
                  message:
                    "invalid value for option: :name, got: \"limiter\"; expected a valid module name"
                }}
    end

    test "rejects nil" do
      assert Options.fetch_atom([name: nil], :name) ==
               {:error,
                %OptionError{
                  key: :name,
                  value: nil,
                  reason: :invalid,
                  message:
                    "invalid value for option: :name, got: nil; expected a valid module name"
                }}
    end

    test "rejects a boolean" do
      assert Options.fetch_atom([name: true], :name) ==
               {:error,
                %OptionError{
                  key: :name,
                  value: true,
                  reason: :invalid,
                  message:
                    "invalid value for option: :name, got: true; expected a valid module name"
                }}
    end
  end

  describe "fetch_positive_integer/2" do
    test "returns a positive integer value" do
      assert Options.fetch_positive_integer([rate: 3], :rate) == {:ok, 3}
    end

    test "rejects a missing option" do
      assert Options.fetch_positive_integer([burst: 3], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :rate"
                }}
    end

    test "rejects zero" do
      assert Options.fetch_positive_integer([rate: 0], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 0,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 0; expected a positive integer (> 0)"
                }}
    end

    test "rejects a negative integer" do
      assert Options.fetch_positive_integer([rate: -1], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: -1,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: -1; expected a positive integer (> 0)"
                }}
    end

    test "rejects a non-integer" do
      assert Options.fetch_positive_integer([rate: 1.5], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 1.5,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 1.5; expected a positive integer (> 0)"
                }}
    end
  end

  describe "fetch_optional_positive_integer/3" do
    test "returns the default when the option is missing" do
      assert Options.fetch_optional_positive_integer([burst: 3], :rate, 5) == {:ok, 5}
    end

    test "prefers a given value over the default" do
      assert Options.fetch_optional_positive_integer([rate: 3], :rate, 5) == {:ok, 3}
    end

    test "rejects an invalid value despite the default" do
      assert Options.fetch_optional_positive_integer([rate: 0], :rate, 5) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 0,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 0; expected a positive integer (> 0)"
                }}
    end

    test "refuses a default that is not a positive integer" do
      assert_raise FunctionClauseError, fn ->
        Options.fetch_optional_positive_integer([], :rate, 0)
      end
    end
  end

  describe "fetch_integer_in_range/3" do
    test "returns a value inside the range" do
      assert Options.fetch_integer_in_range([rate: 5], :rate, 1..10) == {:ok, 5}
    end

    test "returns the range's first value" do
      assert Options.fetch_integer_in_range([rate: 1], :rate, 1..10) == {:ok, 1}
    end

    test "returns the range's last value" do
      assert Options.fetch_integer_in_range([rate: 10], :rate, 1..10) == {:ok, 10}
    end

    test "rejects a value below the range" do
      assert Options.fetch_integer_in_range([rate: 0], :rate, 1..10) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 0,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 0; expected an integer in range 1..10 with step 1"
                }}
    end

    test "rejects a value above the range" do
      assert Options.fetch_integer_in_range([rate: 11], :rate, 1..10) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 11,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 11; expected an integer in range 1..10 with step 1"
                }}
    end

    test "returns a member of a stepped range" do
      assert Options.fetch_integer_in_range([rate: 4], :rate, 1..10//3) == {:ok, 4}
    end

    test "rejects a value between the steps of a range" do
      assert Options.fetch_integer_in_range([rate: 5], :rate, 1..10//3) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 5,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 5; expected an integer in range 1..10 with step 3"
                }}
    end

    test "rejects a non-integer inside the range" do
      assert Options.fetch_integer_in_range([rate: 5.0], :rate, 1..10) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 5.0,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 5.0; expected an integer in range 1..10 with step 1"
                }}
    end

    test "rejects a missing option" do
      assert Options.fetch_integer_in_range([burst: 5], :rate, 1..10) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :rate"
                }}
    end

    test "refuses a bound that is not a range" do
      assert_raise FunctionClauseError, fn ->
        Options.fetch_integer_in_range([rate: 5], :rate, [1, 10])
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
                  message: "unknown options: [foo: 2]; allowed keys are: rate"
                }}
    end

    test "names a repeated unknown option once and keeps every entry" do
      assert Options.reject_unknown([foo: 1, rate: 2, foo: 3], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:foo],
                  value: [foo: 1, foo: 3],
                  reason: :unknown,
                  message: "unknown options: [foo: 1, foo: 3]; allowed keys are: rate"
                }}
    end

    test "names several unknown options in the order given" do
      assert Options.reject_unknown([foo: 1, rate: 2, bar: 3], [:rate, :burst]) ==
               {:error,
                %OptionError{
                  key: [:foo, :bar],
                  value: [foo: 1, bar: 3],
                  reason: :unknown,
                  message: "unknown options: [foo: 1, bar: 3]; allowed keys are: rate, burst"
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

  describe "reject_unknown_or_duplicate/2" do
    test "accepts allowed options given once each" do
      assert Options.reject_unknown_or_duplicate([rate: 1, burst: 2], [:rate, :burst]) == :ok
    end

    test "rejects an unknown option" do
      assert Options.reject_unknown_or_duplicate([rate: 1, foo: 2], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:foo],
                  value: [foo: 2],
                  reason: :unknown,
                  message: "unknown options: [foo: 2]; allowed keys are: rate"
                }}
    end

    test "rejects a repeated allowed option" do
      assert Options.reject_unknown_or_duplicate([rate: 1, rate: 2], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:rate],
                  value: [rate: 1, rate: 2],
                  reason: :duplicate,
                  message: "duplicate options: [rate: 1, rate: 2]"
                }}
    end

    test "reports a repeated unknown option as unknown" do
      assert Options.reject_unknown_or_duplicate([foo: 1, foo: 2], [:rate]) ==
               {:error,
                %OptionError{
                  key: [:foo],
                  value: [foo: 1, foo: 2],
                  reason: :unknown,
                  message: "unknown options: [foo: 1, foo: 2]; allowed keys are: rate"
                }}
    end
  end

  describe "reject_non_positive_integer/2" do
    test "accepts a positive integer" do
      assert Options.reject_non_positive_integer([rate: 3], :rate) == :ok
    end

    test "rejects a missing option" do
      assert Options.reject_non_positive_integer([burst: 3], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :rate"
                }}
    end

    test "rejects zero" do
      assert Options.reject_non_positive_integer([rate: 0], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 0,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 0; expected a positive integer (> 0)"
                }}
    end
  end

  describe "reject_non_positive_integer_if_given/2" do
    test "accepts a missing option" do
      assert Options.reject_non_positive_integer_if_given([burst: 3], :rate) == :ok
    end

    test "accepts a positive integer" do
      assert Options.reject_non_positive_integer_if_given([rate: 3], :rate) == :ok
    end

    test "rejects zero" do
      assert Options.reject_non_positive_integer_if_given([rate: 0], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 0,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 0; expected a positive integer (> 0)"
                }}
    end

    test "rejects a non-integer" do
      assert Options.reject_non_positive_integer_if_given([rate: 1.5], :rate) ==
               {:error,
                %OptionError{
                  key: :rate,
                  value: 1.5,
                  reason: :invalid,
                  message:
                    "invalid value for option: :rate, got: 1.5; expected a positive integer (> 0)"
                }}
    end
  end
end
