defmodule RateLimiter.Algorithm.TokenBucketTest do
  use ExUnit.Case, async: true

  alias RateLimiter.Algorithm.TokenBucket

  test "a full bucket allows bucket_size starts at the same instant, then waits" do
    bucket = TokenBucket.init(bucket_size: 3, refill_interval_ms: 1_000)

    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, empty} = TokenBucket.acquire(bucket, 0)

    assert TokenBucket.acquire(empty, 0) == {:wait, 1_000, empty}
  end

  test "an empty bucket earns one token per refill interval" do
    bucket = TokenBucket.init(bucket_size: 1, refill_interval_ms: 250)
    {:ok, empty} = TokenBucket.acquire(bucket, 0)

    assert TokenBucket.acquire(empty, 249) == {:wait, 1, empty}
    assert {:ok, _bucket} = TokenBucket.acquire(empty, 250)
  end

  test "a partly elapsed interval still counts toward the next token" do
    bucket = TokenBucket.init(bucket_size: 2, refill_interval_ms: 1_000)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)
    {:ok, bucket} = TokenBucket.acquire(bucket, 1_500)

    assert {:wait, 500, _bucket} = TokenBucket.acquire(bucket, 1_500)
  end

  test "an idle bucket stops filling at bucket_size" do
    bucket = TokenBucket.init(bucket_size: 2, refill_interval_ms: 1_000)
    {:ok, bucket} = TokenBucket.acquire(bucket, 0)

    {:ok, bucket} = TokenBucket.acquire(bucket, 10_000)
    {:ok, bucket} = TokenBucket.acquire(bucket, 10_000)

    assert {:wait, 1_000, _bucket} = TokenBucket.acquire(bucket, 10_000)
  end

  test "the first start is granted immediately, even at a negative monotonic time" do
    bucket = TokenBucket.init(bucket_size: 1, refill_interval_ms: 1_000)

    assert {:ok, _bucket} = TokenBucket.acquire(bucket, -576_460_752_303)
  end

  test "init requires :bucket_size" do
    assert_raise KeyError, fn -> TokenBucket.init(refill_interval_ms: 1_000) end
  end

  test "init requires :refill_interval_ms" do
    assert_raise KeyError, fn -> TokenBucket.init(bucket_size: 1) end
  end

  test "init rejects an empty bucket" do
    assert_raise ArgumentError,
                 ":bucket_size must be a positive integer, got: 0",
                 fn -> TokenBucket.init(bucket_size: 0, refill_interval_ms: 1_000) end
  end

  test "init rejects a non-integer bucket size" do
    assert_raise ArgumentError,
                 ":bucket_size must be a positive integer, got: 1.5",
                 fn -> TokenBucket.init(bucket_size: 1.5, refill_interval_ms: 1_000) end
  end

  test "init rejects a zero refill interval" do
    assert_raise ArgumentError,
                 ":refill_interval_ms must be a positive integer, got: 0",
                 fn -> TokenBucket.init(bucket_size: 1, refill_interval_ms: 0) end
  end

  test "init rejects a non-integer refill interval" do
    assert_raise ArgumentError,
                 ":refill_interval_ms must be a positive integer, got: 333.4",
                 fn -> TokenBucket.init(bucket_size: 1, refill_interval_ms: 333.4) end
  end
end
