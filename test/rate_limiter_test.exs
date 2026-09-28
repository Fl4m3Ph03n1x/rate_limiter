defmodule RateLimiterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule Unlimited do
    @moduledoc """
    Authorizes every start immediately and keeps no pacing state.

    Takes pacing out of the picture, so a test observes only the limiter's own
    admission, ordering, concurrency, and failure handling.
    """
    @behaviour RateLimiter.Algorithm

    @impl RateLimiter.Algorithm
    def init(_opts), do: :unlimited

    @impl RateLimiter.Algorithm
    def acquire(state, _now), do: {:ok, state}
  end

  defmodule ClosedUntil do
    @moduledoc """
    Refuses every start before `:opens_at`, then authorizes every start.

    Before opening, each refusal reports the exact wait `opens_at - now`, so a
    test controls when pacing lets work start and can assert that the limiter
    schedules its timer for the delay the algorithm reported.
    """
    @behaviour RateLimiter.Algorithm

    @impl RateLimiter.Algorithm
    def init(opts), do: Keyword.fetch!(opts, :opens_at)

    @impl RateLimiter.Algorithm
    def acquire(opens_at, now) when now >= opens_at, do: {:ok, opens_at}
    def acquire(opens_at, now), do: {:wait, opens_at - now, opens_at}
  end

  defmodule FirstStartOnly do
    @moduledoc """
    Authorizes the first start, then refuses every later one with a 100 ms wait.

    Lets a test hold one task running while the limiter waits on a timer, and
    observe whether any later event asks the algorithm again.
    """
    @behaviour RateLimiter.Algorithm

    @impl RateLimiter.Algorithm
    def init(_opts), do: :open

    @impl RateLimiter.Algorithm
    def acquire(:open, _now), do: {:ok, :closed}
    def acquire(:closed, _now), do: {:wait, 100, :closed}
  end

  defmodule RejectsOptions do
    @moduledoc """
    Rejects every option list, as an algorithm does when its settings are invalid.

    Lets a test observe how the limiter reports a failure raised by `init/1`.
    """
    @behaviour RateLimiter.Algorithm

    @impl RateLimiter.Algorithm
    def init(_opts), do: raise(ArgumentError, "invalid algorithm options")

    @impl RateLimiter.Algorithm
    def acquire(state, _now), do: {:ok, state}
  end

  test "enqueue returns once work is accepted, before the work finishes", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    test_pid = self()

    work = fn ->
      send(test_pid, {:started, self()})

      receive do
        :finish -> send(test_pid, :finished)
      end
    end

    assert RateLimiter.enqueue(limiter, work) == :ok

    assert_receive {:started, task}
    refute_received :finished
    send(task, :finish)
    assert_receive :finished
  end

  test "waiting work is released in submission order", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 3, max_active: 1}
      )

    test_pid = self()

    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :gate))
    :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, {:ran, :a}) end)
    :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, {:ran, :b}) end)
    :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, {:ran, :c}) end)

    assert_receive {:started, :gate, gate}
    send(gate, :release)

    assert_receive {:ran, first}
    assert_receive {:ran, second}
    assert_receive {:ran, third}
    assert [first, second, third] == [:a, :b, :c]
  end

  test "work waits on a single timer until the algorithm allows it to start", %{test: test} do
    test_pid = self()
    clock = start_supervised!({Agent, fn -> 0 end})

    limiter =
      start_supervised!(
        {RateLimiter,
         name: test,
         algorithm: ClosedUntil,
         opens_at: 100,
         max_waiting: 2,
         max_active: 2,
         clock: fn -> Agent.get(clock, & &1) end,
         send_after: fn pid, message, delay ->
           send(test_pid, {:timer_requested, pid, message, delay})
           make_ref()
         end}
      )

    :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, {:ran, :a}) end)
    :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, {:ran, :b}) end)

    assert_received {:timer_requested, ^limiter, timer_message, 100}
    refute_received {:timer_requested, _pid, _message, _delay}
    assert RateLimiter.status(limiter) == {:ok, %{waiting: 2, active: 0}}

    Agent.update(clock, fn _now -> 100 end)
    send(limiter, timer_message)

    assert_receive {:ran, :a}
    assert_receive {:ran, :b}
  end

  test "a task finishing while a timer is pending starts nothing and requests no second timer",
       %{test: test} do
    test_pid = self()

    limiter =
      start_supervised!(
        {RateLimiter,
         name: test,
         algorithm: FirstStartOnly,
         max_waiting: 1,
         max_active: 2,
         send_after: fn pid, message, delay ->
           send(test_pid, {:timer_requested, pid, message, delay})
           make_ref()
         end}
      )

    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :first))
    :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, {:ran, :second}) end)

    assert_received {:timer_requested, ^limiter, _message, 100}
    assert_receive {:started, :first, first}

    first_monitor = Process.monitor(first)
    send(first, :release)
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}

    assert RateLimiter.status(limiter) == {:ok, %{waiting: 1, active: 0}}
    refute_received {:timer_requested, _pid, _message, _delay}
  end

  test "work is rejected without running while the waiting queue is full", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    test_pid = self()

    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :active))
    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :waiting))

    assert RateLimiter.enqueue(limiter, blocking_task(test_pid, :rejected)) ==
             {:error, :queue_full}

    assert_receive {:started, :active, active}
    send(active, :release)
    assert_receive {:started, :waiting, _waiting}
    assert RateLimiter.status(limiter) == {:ok, %{waiting: 0, active: 1}}
    refute_received {:started, :rejected, _rejected}
  end

  test "at most max_active tasks run, and waiting work starts when one finishes", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 2}
      )

    test_pid = self()

    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :a))
    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :b))
    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :c))

    assert_receive {:started, :a, a}
    assert_receive {:started, :b, _b}
    assert RateLimiter.status(limiter) == {:ok, %{waiting: 1, active: 2}}
    refute_received {:started, :c, _c}

    send(a, :release)
    assert_receive {:started, :c, _c}
  end

  test "a crashing task is logged and frees its slot for waiting work", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    test_pid = self()

    log =
      capture_log(fn ->
        :ok = RateLimiter.enqueue(limiter, fn -> raise "boom" end)
        :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, :ran_after_crash) end)

        # A cold VM can spend over 100 ms formatting the first crash report.
        assert_receive :ran_after_crash, 1_000
      end)

    assert log =~ "RateLimiter #{inspect(test)} task failed"
  end

  test "a task that exits normally without returning frees its slot without logging",
       %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    test_pid = self()

    log =
      capture_log(fn ->
        :ok = RateLimiter.enqueue(limiter, fn -> exit(:normal) end)
        :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, :ran_after_exit) end)

        assert_receive :ran_after_exit
      end)

    refute log =~ "RateLimiter #{inspect(test)} task failed"
  end

  test "an unexpected message is logged and ignored", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    log =
      capture_log(fn ->
        send(limiter, :unexpected)

        assert RateLimiter.status(limiter) == {:ok, %{waiting: 0, active: 0}}
      end)

    assert log =~ "RateLimiter #{inspect(test)} ignored unexpected message: :unexpected"
  end

  test "a reply from an unknown task is logged and ignored", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    unknown_ref = make_ref()

    log =
      capture_log(fn ->
        send(limiter, {unknown_ref, :result})

        assert RateLimiter.status(limiter) == {:ok, %{waiting: 0, active: 0}}
      end)

    assert log =~
             "RateLimiter #{inspect(test)} attempted to finish unknown task reference: #{inspect(unknown_ref)}"
  end

  test "limiters with different names do not share capacity", %{test: test} do
    busy = :"#{test} busy"
    idle = :"#{test} idle"

    start_supervised!(
      {RateLimiter, name: busy, algorithm: Unlimited, max_waiting: 1, max_active: 1}
    )

    start_supervised!(
      {RateLimiter, name: idle, algorithm: Unlimited, max_waiting: 1, max_active: 1}
    )

    test_pid = self()

    :ok = RateLimiter.enqueue(busy, blocking_task(test_pid, :busy))
    :ok = RateLimiter.enqueue(busy, fn -> send(test_pid, {:ran, :behind_busy}) end)
    :ok = RateLimiter.enqueue(idle, fn -> send(test_pid, {:ran, :idle}) end)

    assert_receive {:ran, :idle}
    assert RateLimiter.status(busy) == {:ok, %{waiting: 1, active: 1}}
  end

  test "a stopped limiter is reported as not running", %{test: test} do
    start_supervised!(
      {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
    )

    :ok = stop_supervised({RateLimiter, test})

    assert RateLimiter.enqueue(test, fn -> :ok end) == {:error, :not_running}
    assert RateLimiter.status(test) == {:error, :not_running}
  end

  test "start_link requires a name" do
    assert_raise KeyError, fn ->
      RateLimiter.start_link(algorithm: Unlimited, max_waiting: 1, max_active: 1)
    end
  end

  @tag capture_log: true
  test "start_link fails without an algorithm", %{test: test} do
    Process.flag(:trap_exit, true)

    assert {:error, {%KeyError{key: :algorithm}, _stacktrace}} =
             RateLimiter.start_link(name: test, max_waiting: 1, max_active: 1)
  end

  @tag capture_log: true
  test "start_link fails when max_waiting is not a positive integer", %{test: test} do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             RateLimiter.start_link(
               name: test,
               algorithm: Unlimited,
               max_waiting: 0,
               max_active: 1
             )

    assert message == ":max_waiting must be a positive integer, got: 0"
  end

  @tag capture_log: true
  test "start_link fails when max_active is not a positive integer", %{test: test} do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             RateLimiter.start_link(
               name: test,
               algorithm: Unlimited,
               max_waiting: 1,
               max_active: 1.5
             )

    assert message == ":max_active must be a positive integer, got: 1.5"
  end

  @tag capture_log: true
  test "start_link fails when the algorithm rejects its options", %{test: test} do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             RateLimiter.start_link(
               name: test,
               algorithm: RejectsOptions,
               max_waiting: 1,
               max_active: 1
             )

    assert message == "invalid algorithm options"
  end

  test "submit delivers the work's result to await", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    {:ok, ref} = RateLimiter.submit(limiter, fn -> :result end)

    assert RateLimiter.await(ref, 1_000) == {:ok, :result}
  end

  test "a submitted result arrives as a {ref, {:ok, result}} message", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    {:ok, ref} = RateLimiter.submit(limiter, fn -> 42 end)

    assert_receive {^ref, {:ok, 42}}
  end

  @tag capture_log: true
  test "a submitted task that raises is reported to await as an exit", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    {:ok, ref} = RateLimiter.submit(limiter, fn -> raise "boom" end)

    assert {:exit, {%RuntimeError{message: "boom"}, _stacktrace}} = RateLimiter.await(ref, 1_000)
  end

  test "a submitted task that exits normally without returning is reported to await",
       %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    {:ok, ref} = RateLimiter.submit(limiter, fn -> exit(:normal) end)

    assert RateLimiter.await(ref, 1_000) == {:exit, :normal}
  end

  test "await times out without cancelling the work, and drops the late reply", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    test_pid = self()
    {:ok, ref} = RateLimiter.submit(limiter, blocking_task(test_pid, :slow))

    assert RateLimiter.await(ref, 10) == {:error, :timeout}

    assert_receive {:started, :slow, task}
    task_monitor = Process.monitor(task)
    send(task, :release)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :normal}
    refute_received {^ref, _reply}
  end

  test "forget drops the reply without cancelling the work", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    test_pid = self()
    {:ok, ref} = RateLimiter.submit(limiter, blocking_task(test_pid, :forgotten))

    assert RateLimiter.forget(ref) == :ok

    assert_receive {:started, :forgotten, task}
    task_monitor = Process.monitor(task)
    send(task, :release)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :normal}
    refute_received {^ref, _reply}
  end

  test "forget drops a reply that has already arrived", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    test_pid = self()
    {:ok, ref} = RateLimiter.submit(limiter, blocking_task(test_pid, :arrived))

    assert_receive {:started, :arrived, task}
    task_monitor = Process.monitor(task)
    send(task, :release)
    assert_receive {:DOWN, ^task_monitor, :process, ^task, :normal}
    assert Process.info(self(), :messages) == {:messages, [{ref, {:ok, :ok}}]}

    assert RateLimiter.forget(ref) == :ok

    refute_received {^ref, _reply}
  end

  test "await reports a limiter that stops before the submitted work runs", %{test: test} do
    start_supervised!(
      {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
    )

    test_pid = self()
    :ok = RateLimiter.enqueue(test, blocking_task(test_pid, :active))
    {:ok, ref} = RateLimiter.submit(test, fn -> :never_runs end)
    assert_receive {:started, :active, _active}

    :ok = stop_supervised({RateLimiter, test})

    assert RateLimiter.await(ref, 1_000) == {:error, :not_running}
  end

  test "submit to a stopped limiter reports it as not running and keeps no monitor",
       %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    :ok = stop_supervised({RateLimiter, test})

    assert RateLimiter.submit(limiter, fn -> :ok end) == {:error, :not_running}
    assert Process.info(self(), :monitors) == {:monitors, []}
    refute_received {:DOWN, _ref, :process, _pid, _reason}
  end

  test "submit to a full queue is rejected and keeps no monitor", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 1, max_active: 1}
      )

    test_pid = self()
    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :active))
    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :waiting))

    assert RateLimiter.submit(limiter, fn -> :rejected end) == {:error, :queue_full}
    assert Process.info(self(), :monitors) == {:monitors, []}
  end

  test "enqueued and submitted work share one queue in submission order", %{test: test} do
    limiter =
      start_supervised!(
        {RateLimiter, name: test, algorithm: Unlimited, max_waiting: 3, max_active: 1}
      )

    test_pid = self()

    :ok = RateLimiter.enqueue(limiter, blocking_task(test_pid, :gate))
    {:ok, _a} = RateLimiter.submit(limiter, fn -> send(test_pid, {:ran, :a}) end)
    :ok = RateLimiter.enqueue(limiter, fn -> send(test_pid, {:ran, :b}) end)
    {:ok, _c} = RateLimiter.submit(limiter, fn -> send(test_pid, {:ran, :c}) end)

    assert_receive {:started, :gate, gate}
    send(gate, :release)

    assert_receive {:ran, first}
    assert_receive {:ran, second}
    assert_receive {:ran, third}
    assert [first, second, third] == [:a, :b, :c]
  end

  defp blocking_task(test_pid, label) do
    fn ->
      send(test_pid, {:started, label, self()})

      receive do
        :release -> :ok
      end
    end
  end
end
