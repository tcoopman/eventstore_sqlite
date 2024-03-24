# Setup: `MIX_ENV= bench mix ecto.setup`
# Run with: `MIX_ENV=bench mix run bench/eventstore.exs`

# # Writing
# MIX_ENV=bench mix run bench/eventstore.exs
# Operating System: Linux
# CPU Information: AMD Ryzen 9 5950X 16-Core Processor
# Number of Available Cores: 32
# Available memory: 62.72 GB
# Elixir 1.16.2
# Erlang 26.2.4
# JIT enabled: true

# Benchmark suite executing with the following configuration:
# warmup: 2 s
# time: 10 s
# memory time: 2 s
# reduction time: 0 ns
# parallel: 1
# inputs: none specified
# Estimated total run time: 42 s

# Benchmarking 1 ...
# Benchmarking 2 ...
# Benchmarking 5 ...
# Calculating statistics...
# Formatting results...

# Name           ips        average  deviation         median         99th %
# 1           2.11 K      474.14 μs    ±97.79%      422.77 μs     1436.72 μs
# 2           1.95 K      513.49 μs    ±95.59%      452.88 μs     2094.92 μs
# 5           1.65 K      607.80 μs    ±92.72%      535.73 μs     5110.86 μs

# Comparison:
# 1           2.11 K
# 2           1.95 K - 1.08x slower +39.35 μs
# 5           1.65 K - 1.28x slower +133.66 μs

# Memory usage statistics:

# Name         average  deviation         median         99th %
# 1           66.89 KB     ±0.01%       66.89 KB       66.89 KB
# 2           78.57 KB     ±0.05%       78.55 KB       78.66 KB
# 5          112.38 KB     ±0.10%      112.43 KB      112.55 KB

# Comparison:
# 1           66.89 KB
# 2           78.57 KB - 1.17x memory usage +11.68 KB
# 5          112.38 KB - 1.68x memory usage +45.49 KB

# # Reading
# # strongly depends on the number of records in the db
# MIX_ENV=bench mix run bench/eventstore.exs
# "Inserting 20K events ..."
# Operating System: Linux
# CPU Information: AMD Ryzen 9 5950X 16-Core Processor
# Number of Available Cores: 32
# Available memory: 62.72 GB
# Elixir 1.16.2
# Erlang 26.2.4
# JIT enabled: true

# Benchmark suite executing with the following configuration:
# warmup: 2 s
# time: 10 s
# memory time: 2 s
# reduction time: 0 ns
# parallel: 1
# inputs: none specified
# Estimated total run time: 1 min 24 s

# Benchmarking read backward 10 ...
# Benchmarking read backward 100 ...
# Benchmarking read backward 10_000 ...
# Benchmarking read forward 10 ...
# Benchmarking read forward 100 ...
# Benchmarking read forward 10_000 ...
# Calculating statistics...
# Formatting results...

# Name                           ips        average  deviation         median         99th %
# read forward 10              27.58       36.26 ms     ±1.33%       36.20 ms       37.63 ms
# read forward 100             27.48       36.39 ms     ±1.09%       36.36 ms       37.77 ms
# read backward 10             14.86       67.28 ms     ±1.55%       67.15 ms       70.98 ms
# read forward 10_000          13.33       75.02 ms     ±5.43%       73.57 ms       84.68 ms
# read backward 100             7.38      135.57 ms     ±1.06%      135.45 ms      139.05 ms
# read backward 10_000          5.45      183.60 ms     ±1.59%      183.26 ms      200.47 ms

# Comparison:
# read forward 10              27.58
# read forward 100             27.48 - 1.00x slower +0.134 ms
# read backward 10             14.86 - 1.86x slower +31.02 ms
# read forward 10_000          13.33 - 2.07x slower +38.76 ms
# read backward 100             7.38 - 3.74x slower +99.31 ms
# read backward 10_000          5.45 - 5.06x slower +147.34 ms

# Memory usage statistics:

# Name                    Memory usage
# read forward 10             42.43 KB
# read forward 100           284.55 KB - 6.71x memory usage +242.13 KB
# read backward 10            42.43 KB - 1.00x memory usage +0 KB
# read forward 10_000      29178.62 KB - 687.69x memory usage +29136.19 KB
# read backward 100          284.55 KB - 6.71x memory usage +242.13 KB
# read backward 10_000     29178.62 KB - 687.69x memory usage +29136.19 KB

# **All measurements for memory usage were the same**

use TypedStruct

typedstruct module: FooTestEvent do
  field(:text, :string)
end

typedstruct module: Complex do
  field(:c, :string)
end


defmodule Bench do
  def writing do
    event1 = %FooTestEvent{text: "bar"}
    event2 = %Complex{c: "bar"}

    events1 = [event1]
    events2 = [event1, event2]
    events5 = [event1, event2, event1, event2, event1]

    Benchee.run(
      %{
        "1" => fn -> EventstoreSqlite.append_to_stream("test", events1) end,
        "2" => fn -> EventstoreSqlite.append_to_stream("test", events2) end,
        "5" => fn -> EventstoreSqlite.append_to_stream("test", events5) end
      },
      time: 10,
      memory_time: 2
    )
  end

  def reading do
    event1 = %FooTestEvent{text: "bar"}
    event2 = %Complex{c: "bar"}

    events = [event1, event2]

    IO.inspect("Inserting 20K events ...")
    Enum.to_list(1..20_000) |> Enum.map(fn _ -> EventstoreSqlite.append_to_stream("test", events) end) 

    Benchee.run(
      %{
        "read forward 10" => fn -> EventstoreSqlite.read_stream_forward("test", count: 10) end,
        "read forward 100" => fn -> EventstoreSqlite.read_stream_forward("test", count: 100) end,
        "read forward 10_000" => fn -> EventstoreSqlite.read_stream_forward("test", count: 10_000) end,
        "read backward 10" => fn -> EventstoreSqlite.read_stream_backward("test", count: 10) end,
        "read backward 100" => fn -> EventstoreSqlite.read_stream_backward("test", count: 100) end,
        "read backward 10_000" => fn -> EventstoreSqlite.read_stream_backward("test", count: 10_000) end,
      },
      time: 10,
      memory_time: 2
    )
  end
end

Bench.reading()
