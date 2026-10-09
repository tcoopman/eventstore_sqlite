defmodule EventstoreSqlite.Sync.StressTest do
  use ExUnit.Case

  @moduletag :stress
  @moduletag timeout: :infinity

  test "a randomized run of two writing nodes under chaos keeps every invariant" do
    seconds = String.to_integer(System.get_env("SYNC_STRESS_SECONDS", "300"))
    seed = String.to_integer(System.get_env("SYNC_STRESS_SEED", "#{:rand.uniform(1_000_000)}"))
    max_partition_ms = String.to_integer(System.get_env("SYNC_STRESS_MAX_PARTITION_MS", "30000"))

    report = EventstoreSqlite.SyncStress.run(seed: seed, seconds: seconds, max_partition_ms: max_partition_ms)
    IO.puts("\nsync stress report: " <> inspect(report, pretty: true, limit: :infinity))

    assert report.violations == [], "violations with seed #{seed}: #{inspect(report.violations)}"
  end
end
