defmodule RateLimiter.Algorithm.FixedWindowTest do
  use ExUnit.Case, async: true

  alias RateLimiter.Algorithm.FixedWindow
  alias RateLimiter.OptionError

  test "a window allows requests_per_window starts at the same instant, then waits for it to end" do
    {:ok, window} = FixedWindow.init(requests_per_window: 3, window_duration_ms: 1_000)

    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, full} = FixedWindow.acquire(window, 0)

    assert FixedWindow.acquire(full, 0) == {:wait, 1_000, full}
  end

  test "the wait is measured from the start of the window, not from the last start" do
    {:ok, window} = FixedWindow.init(requests_per_window: 2, window_duration_ms: 1_000)

    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, full} = FixedWindow.acquire(window, 300)

    assert FixedWindow.acquire(full, 400) == {:wait, 600, full}
  end

  test "repeated waits leave the window unchanged" do
    {:ok, window} = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)
    {:ok, full} = FixedWindow.acquire(window, 0)

    assert FixedWindow.acquire(full, 100) == {:wait, 900, full}
    assert FixedWindow.acquire(full, 200) == {:wait, 800, full}
  end

  test "a new window opens exactly when the previous one ends, with a full limit" do
    {:ok, window} = FixedWindow.init(requests_per_window: 2, window_duration_ms: 1_000)
    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, full} = FixedWindow.acquire(window, 0)

    assert FixedWindow.acquire(full, 999) == {:wait, 1, full}

    {:ok, window} = FixedWindow.acquire(full, 1_000)
    {:ok, full} = FixedWindow.acquire(window, 1_000)

    assert FixedWindow.acquire(full, 1_000) == {:wait, 1_000, full}
  end

  test "after an idle period a window opens at the next start, not on a grid" do
    {:ok, window} = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)
    {:ok, window} = FixedWindow.acquire(window, 0)

    {:ok, full} = FixedWindow.acquire(window, 2_500)

    # A grid anchored at 0 would end this window at 3_000.
    assert FixedWindow.acquire(full, 2_500) == {:wait, 1_000, full}
  end

  test "up to twice requests_per_window starts can happen across a window boundary" do
    {:ok, window} = FixedWindow.init(requests_per_window: 2, window_duration_ms: 1_000)
    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, window} = FixedWindow.acquire(window, 999)
    {:ok, window} = FixedWindow.acquire(window, 1_000)

    assert {:ok, _window} = FixedWindow.acquire(window, 1_000)
  end

  test "windows work at negative monotonic times" do
    {:ok, window} = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)

    {:ok, full} = FixedWindow.acquire(window, -576_460_752_303)

    assert FixedWindow.acquire(full, -576_460_751_803) == {:wait, 500, full}
  end

  test "allowed_options lists the request limit and the window duration" do
    assert FixedWindow.allowed_options() == [:requests_per_window, :window_duration_ms]
  end

  test "init accepts limits with no upper bound" do
    {:ok, window} =
      FixedWindow.init(requests_per_window: 10_000_000, window_duration_ms: 86_400_000)

    assert {:ok, _window} = FixedWindow.acquire(window, 0)
  end

  test "init ignores options that belong to others" do
    assert FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000, max_active: 5) ==
             FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)
  end

  test "init requires :requests_per_window" do
    assert FixedWindow.init(window_duration_ms: 1_000) ==
             {:error,
              %OptionError{
                key: :requests_per_window,
                value: nil,
                reason: :missing,
                message: "missing required option: :requests_per_window"
              }}
  end

  test "init requires :window_duration_ms" do
    assert FixedWindow.init(requests_per_window: 1) ==
             {:error,
              %OptionError{
                key: :window_duration_ms,
                value: nil,
                reason: :missing,
                message: "missing required option: :window_duration_ms"
              }}
  end

  test "init rejects a window that allows no requests" do
    assert FixedWindow.init(requests_per_window: 0, window_duration_ms: 1_000) ==
             {:error,
              %OptionError{
                key: :requests_per_window,
                value: 0,
                reason: :invalid,
                message:
                  "invalid value for option: :requests_per_window, got: 0; expected a positive integer (> 0)"
              }}
  end

  test "init rejects a non-integer request limit" do
    assert FixedWindow.init(requests_per_window: 1.5, window_duration_ms: 1_000) ==
             {:error,
              %OptionError{
                key: :requests_per_window,
                value: 1.5,
                reason: :invalid,
                message:
                  "invalid value for option: :requests_per_window, got: 1.5; expected a positive integer (> 0)"
              }}
  end

  test "init rejects a zero window duration" do
    assert FixedWindow.init(requests_per_window: 1, window_duration_ms: 0) ==
             {:error,
              %OptionError{
                key: :window_duration_ms,
                value: 0,
                reason: :invalid,
                message:
                  "invalid value for option: :window_duration_ms, got: 0; expected a positive integer (> 0)"
              }}
  end

  test "init rejects a non-integer window duration" do
    assert FixedWindow.init(requests_per_window: 1, window_duration_ms: 333.4) ==
             {:error,
              %OptionError{
                key: :window_duration_ms,
                value: 333.4,
                reason: :invalid,
                message:
                  "invalid value for option: :window_duration_ms, got: 333.4; expected a positive integer (> 0)"
              }}
  end

  test "a raised limit lets no more starts into the current window, only into the next" do
    {:ok, window} = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)
    {:ok, full} = FixedWindow.acquire(window, 0)

    {:ok, raised} = FixedWindow.reconfigure(full, [requests_per_window: 2], 100)

    assert FixedWindow.acquire(raised, 100) == {:wait, 900, raised}

    {:ok, window} = FixedWindow.acquire(raised, 1_000)
    {:ok, full} = FixedWindow.acquire(window, 1_000)

    assert FixedWindow.acquire(full, 1_000) == {:wait, 1_000, full}
  end

  test "a shortened duration lets the current window end on its old schedule" do
    {:ok, window} = FixedWindow.init(requests_per_window: 1, window_duration_ms: 60_000)
    {:ok, full} = FixedWindow.acquire(window, 0)

    {:ok, shortened} = FixedWindow.reconfigure(full, [window_duration_ms: 1_000], 1_500)

    assert FixedWindow.acquire(shortened, 1_500) == {:wait, 58_500, shortened}

    {:ok, full} = FixedWindow.acquire(shortened, 60_000)

    assert FixedWindow.acquire(full, 60_000) == {:wait, 1_000, full}
  end

  test "a later change replaces a pending one entirely" do
    {:ok, window} = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)
    {:ok, full} = FixedWindow.acquire(window, 0)

    {:ok, pending} = FixedWindow.reconfigure(full, [requests_per_window: 5], 100)
    {:ok, replaced} = FixedWindow.reconfigure(pending, [window_duration_ms: 2_000], 200)
    {:ok, full} = FixedWindow.acquire(replaced, 1_000)

    assert FixedWindow.acquire(full, 1_000) == {:wait, 2_000, full}
  end

  test "a change before the first window applies to it" do
    {:ok, window} = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)

    {:ok, raised} = FixedWindow.reconfigure(window, [requests_per_window: 2], 0)
    {:ok, window} = FixedWindow.acquire(raised, 0)
    {:ok, full} = FixedWindow.acquire(window, 0)

    assert FixedWindow.acquire(full, 0) == {:wait, 1_000, full}
  end

  test "reconfigure rejects a zero window duration" do
    {:ok, window} = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)

    assert FixedWindow.reconfigure(window, [window_duration_ms: 0], 0) ==
             {:error,
              %OptionError{
                key: :window_duration_ms,
                value: 0,
                reason: :invalid,
                message:
                  "invalid value for option: :window_duration_ms, got: 0; expected a positive integer (> 0)"
              }}
  end
end
