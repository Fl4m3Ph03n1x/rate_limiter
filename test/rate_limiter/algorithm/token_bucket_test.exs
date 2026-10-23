defmodule RateLimiter.Algorithm.TokenBucketTest do
  use ExUnit.Case, async: true

  alias RateLimiter.Algorithm.TokenBucket
  alias RateLimiter.OptionError

  test "a full bucket allows bucket_size starts at the same instant, then waits" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 3, refill_interval_ms: 1_000)

    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, empty} = TokenBucket.acquire(bucket, 0)

    assert TokenBucket.acquire(empty, 0) == {:wait, 1_000, empty}
  end

  test "an empty bucket earns one token per refill interval" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 1, refill_interval_ms: 250)
    {:ok, empty} = TokenBucket.acquire(bucket, 0)

    assert TokenBucket.acquire(empty, 249) == {:wait, 1, empty}
    assert {:ok, _bucket} = TokenBucket.acquire(empty, 250)
  end

  test "a partly elapsed interval still counts toward the next token" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 2, refill_interval_ms: 1_000)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, bucket} = TokenBucket.acquire(bucket, 1_500)

    assert {:wait, 500, _bucket} = TokenBucket.acquire(bucket, 1_500)
  end

  test "an idle bucket stops filling at bucket_size" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 2, refill_interval_ms: 1_000)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)

    {:ok, bucket} = TokenBucket.acquire(bucket, 10_000)
    {:ok, bucket} = TokenBucket.acquire(bucket, 10_000)

    assert {:wait, 1_000, _bucket} = TokenBucket.acquire(bucket, 10_000)
  end

  test "the first start is granted immediately, even at a negative monotonic time" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 1, refill_interval_ms: 1_000)

    assert {:ok, _bucket} = TokenBucket.acquire(bucket, -576_460_752_303)
  end

  test "allowed_options lists the bucket size and the refill interval" do
    assert TokenBucket.allowed_options() == [:bucket_size, :refill_interval_ms]
  end

  test "init ignores options that belong to others" do
    assert TokenBucket.init(bucket_size: 1, refill_interval_ms: 1_000, max_active: 5) ==
             TokenBucket.init(bucket_size: 1, refill_interval_ms: 1_000)
  end

  test "init requires :bucket_size" do
    assert TokenBucket.init(refill_interval_ms: 1_000) ==
             {:error,
              %OptionError{
                key: :bucket_size,
                value: nil,
                reason: :missing,
                message: "missing required option: :bucket_size"
              }}
  end

  test "init requires :refill_interval_ms" do
    assert TokenBucket.init(bucket_size: 1) ==
             {:error,
              %OptionError{
                key: :refill_interval_ms,
                value: nil,
                reason: :missing,
                message: "missing required option: :refill_interval_ms"
              }}
  end

  test "init rejects an empty bucket" do
    assert TokenBucket.init(bucket_size: 0, refill_interval_ms: 1_000) ==
             {:error,
              %OptionError{
                key: :bucket_size,
                value: 0,
                reason: :invalid,
                message:
                  "invalid value for option: :bucket_size, got: 0; expected a positive integer (> 0)"
              }}
  end

  test "init rejects a non-integer bucket size" do
    assert TokenBucket.init(bucket_size: 1.5, refill_interval_ms: 1_000) ==
             {:error,
              %OptionError{
                key: :bucket_size,
                value: 1.5,
                reason: :invalid,
                message:
                  "invalid value for option: :bucket_size, got: 1.5; expected a positive integer (> 0)"
              }}
  end

  test "init rejects a zero refill interval" do
    assert TokenBucket.init(bucket_size: 1, refill_interval_ms: 0) ==
             {:error,
              %OptionError{
                key: :refill_interval_ms,
                value: 0,
                reason: :invalid,
                message:
                  "invalid value for option: :refill_interval_ms, got: 0; expected a positive integer (> 0)"
              }}
  end

  test "init rejects a non-integer refill interval" do
    assert TokenBucket.init(bucket_size: 1, refill_interval_ms: 333.4) ==
             {:error,
              %OptionError{
                key: :refill_interval_ms,
                value: 333.4,
                reason: :invalid,
                message:
                  "invalid value for option: :refill_interval_ms, got: 333.4; expected a positive integer (> 0)"
              }}
  end

  test "a smaller bucket drops the tokens above its new size" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 10, refill_interval_ms: 1_000)

    {:ok, smaller} = TokenBucket.reconfigure(bucket, [bucket_size: 2], 0)
    {:ok, smaller} = TokenBucket.acquire(smaller, 0)
    {:ok, empty} = TokenBucket.acquire(smaller, 0)

    assert TokenBucket.acquire(empty, 0) == {:wait, 1_000, empty}
  end

  test "a larger bucket gains no tokens, even after an idle period" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 3, refill_interval_ms: 1_000)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)

    {:ok, larger} = TokenBucket.reconfigure(bucket, [bucket_size: 5], 10_000)
    {:ok, larger} = TokenBucket.acquire(larger, 10_000)
    {:ok, larger} = TokenBucket.acquire(larger, 10_000)
    {:ok, empty} = TokenBucket.acquire(larger, 10_000)

    assert TokenBucket.acquire(empty, 10_000) == {:wait, 1_000, empty}
  end

  test "a larger bucket refills up to its new size" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 1, refill_interval_ms: 1_000)
    {:ok, empty} = TokenBucket.acquire(bucket, 0)

    {:ok, larger} = TokenBucket.reconfigure(empty, [bucket_size: 2], 0)
    {:ok, larger} = TokenBucket.acquire(larger, 5_000)
    {:ok, empty} = TokenBucket.acquire(larger, 5_000)

    assert TokenBucket.acquire(empty, 5_000) == {:wait, 1_000, empty}
  end

  test "a new refill interval restarts the refill, so waiting earns no burst" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 10, refill_interval_ms: 1_000)

    empty =
      Enum.reduce(1..10, bucket, fn _start, bucket ->
        {:ok, bucket} = TokenBucket.acquire(bucket, 0)
        bucket
      end)

    {:ok, faster} = TokenBucket.reconfigure(empty, [refill_interval_ms: 100], 900)

    assert TokenBucket.acquire(faster, 900) == {:wait, 100, faster}
    assert {:ok, _bucket} = TokenBucket.acquire(faster, 1_000)
  end

  test "a new bucket size alone keeps the refill progress" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 2, refill_interval_ms: 1_000)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, empty} = TokenBucket.acquire(bucket, 0)

    {:ok, larger} = TokenBucket.reconfigure(empty, [bucket_size: 4], 900)

    assert TokenBucket.acquire(larger, 900) == {:wait, 100, larger}
  end

  test "an unchanged refill interval keeps the refill progress" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 1, refill_interval_ms: 1_000)
    {:ok, empty} = TokenBucket.acquire(bucket, 0)

    {:ok, same} = TokenBucket.reconfigure(empty, [refill_interval_ms: 1_000], 900)

    assert TokenBucket.acquire(same, 900) == {:wait, 100, same}
  end

  test "a refill interval changed before the first start paces from that start" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 1, refill_interval_ms: 1_000)

    {:ok, faster} = TokenBucket.reconfigure(bucket, [refill_interval_ms: 250], 0)
    {:ok, empty} = TokenBucket.acquire(faster, 100)

    assert TokenBucket.acquire(empty, 100) == {:wait, 250, empty}
  end

  test "reconfigure rejects an empty bucket" do
    {:ok, bucket} = TokenBucket.init(bucket_size: 1, refill_interval_ms: 1_000)

    assert TokenBucket.reconfigure(bucket, [bucket_size: 0], 0) ==
             {:error,
              %OptionError{
                key: :bucket_size,
                value: 0,
                reason: :invalid,
                message:
                  "invalid value for option: :bucket_size, got: 0; expected a positive integer (> 0)"
              }}
  end
end
