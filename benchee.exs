Mix.install([
  {:benchee, "~> 1.0"},
  {:msgpax, "~> 2.4.0"},
  {:jason, "~> 1.5.0-alpha.2"},
  {:poison, "~> 6.0"}
])

data = %{a: 1, b: 2, c: [1, 2, 3], d: "Some string in here as well", f: %{b: "nested"}}

# both
# Operating System: Linux
# CPU Information: AMD Ryzen 9 5950X 16-Core Processor
# Number of Available Cores: 32
# Available memory: 62.72 GB
# Elixir 1.17.2
# Erlang 27.0
# JIT enabled: true

# Benchmark suite executing with the following configuration:
# warmup: 2 s
# time: 10 s
# memory time: 2 s
# reduction time: 0 ns
# parallel: 1
# inputs: none specified
# Estimated total run time: 1 min 38 s

# Benchmarking erlang json ...
# Benchmarking jason ...
# Benchmarking jason atom keys ...
# Benchmarking msgpax ...
# Benchmarking msgpax atom keys ...
# Benchmarking native ...
# Benchmarking poison ...
# Calculating statistics...
# Formatting results...

# Name                       ips        average  deviation         median         99th %
# native                930.32 K        1.07 μs  ±2005.48%        0.88 μs        1.60 μs
# msgpax                873.60 K        1.14 μs  ±1778.61%        1.08 μs        1.32 μs
# erlang json           554.87 K        1.80 μs  ±1020.98%        1.64 μs           3 μs
# msgpax atom keys      552.49 K        1.81 μs   ±945.29%        1.68 μs        2.65 μs
# jason                 475.96 K        2.10 μs   ±708.34%        1.92 μs        3.96 μs
# poison                410.23 K        2.44 μs   ±760.48%        2.25 μs        4.40 μs
# jason atom keys       376.17 K        2.66 μs   ±491.71%        2.43 μs        4.84 μs

# Comparison:
# native                930.32 K
# msgpax                873.60 K - 1.06x slower +0.0698 μs
# erlang json           554.87 K - 1.68x slower +0.73 μs
# msgpax atom keys      552.49 K - 1.68x slower +0.74 μs
# jason                 475.96 K - 1.95x slower +1.03 μs
# poison                410.23 K - 2.27x slower +1.36 μs
# jason atom keys       376.17 K - 2.47x slower +1.58 μs

# Memory usage statistics:

# Name                Memory usage
# native                   0.34 KB
# msgpax                   2.15 KB - 6.40x memory usage +1.81 KB
# erlang json              2.46 KB - 7.33x memory usage +2.13 KB
# msgpax atom keys         2.88 KB - 8.58x memory usage +2.55 KB
# jason                    2.64 KB - 7.86x memory usage +2.30 KB
# poison                   3.70 KB - 11.00x memory usage +3.36 KB
# jason atom keys          2.66 KB - 7.93x memory usage +2.33 KB

# **All measurements for memory usage were the same**

Benchee.run(
  %{
    "native" => fn -> :erlang.term_to_binary(data) |> :erlang.binary_to_term() end,
    "jason" => fn -> Jason.encode!(data) |> Jason.decode!() end,
    "jason atom keys" => fn -> Jason.encode!(data) |> Jason.decode!(keys: :atoms) end,
    "msgpax" => fn -> Msgpax.pack!(data) |> Msgpax.unpack!() end,
    "msgpax atom keys" => fn ->
      Msgpax.pack!(data)
      |> Msgpax.unpack!()
      |> Enum.into(%{}, fn {key, val} -> {String.to_atom(key), val} end)
    end,
    "erlang json" => fn -> :json.encode(data) |> IO.iodata_to_binary() |> :json.decode() end,
    "poison" => fn -> Poison.encode!(data) |> Poison.decode!() end,
  },
  time: 10,
  memory_time: 2
)


# only encode
# Operating System: Linux
# CPU Information: AMD Ryzen 9 5950X 16-Core Processor
# Number of Available Cores: 32
# Available memory: 62.72 GB
# Elixir 1.17.2
# Erlang 27.0
# JIT enabled: true

# Benchmark suite executing with the following configuration:
# warmup: 2 s
# time: 10 s
# memory time: 2 s
# reduction time: 0 ns
# parallel: 1
# inputs: none specified
# Estimated total run time: 1 min 24 s

# Benchmarking erlang json ...
# Benchmarking erlang json without iodata ...
# Benchmarking jason ...
# Benchmarking msgpax ...
# Benchmarking native ...
# Benchmarking poison ...
# Calculating statistics...
# Formatting results...

# Name                                 ips        average  deviation         median         99th %
# msgpax                            2.03 M      492.66 ns  ±6006.97%         440 ns         640 ns
# native                            1.96 M      509.07 ns  ±5436.68%         370 ns         860 ns
# erlang json without iodata        1.81 M      552.82 ns  ±4758.67%         460 ns         680 ns
# erlang json                       1.07 M      936.65 ns  ±2459.75%         800 ns        1620 ns
# jason                             0.77 M     1305.48 ns  ±1529.90%        1120 ns        3070 ns
# poison                            0.61 M     1627.91 ns  ±1491.59%        1440 ns        3480 ns

# Comparison:
# msgpax                            2.03 M
# native                            1.96 M - 1.03x slower +16.41 ns
# erlang json without iodata        1.81 M - 1.12x slower +60.16 ns
# erlang json                       1.07 M - 1.90x slower +443.99 ns
# jason                             0.77 M - 2.65x slower +812.82 ns
# poison                            0.61 M - 3.30x slower +1135.25 ns

# Memory usage statistics:

# Name                          Memory usage
# msgpax                             0.93 KB
# native                           0.0625 KB - 0.07x memory usage -0.86719 KB
# erlang json without iodata         1.57 KB - 1.69x memory usage +0.64 KB
# erlang json                        1.63 KB - 1.76x memory usage +0.70 KB
# jason                              1.57 KB - 1.69x memory usage +0.64 KB
# poison                             2.61 KB - 2.81x memory usage +1.68 KB

# **All measurements for memory usage were the same**

Benchee.run(
  %{
    "native" => fn -> :erlang.term_to_binary(data) end,
    "jason" => fn -> Jason.encode!(data) end,
    "msgpax" => fn -> Msgpax.pack!(data) end,
    "erlang json" => fn -> :json.encode(data) |> IO.iodata_to_binary() end,
    "erlang json without iodata" => fn -> :json.encode(data) end,
    "poison" => fn -> Poison.encode!(data) end,
  },
  time: 10,
  memory_time: 2
)

# only decode
# 
# 
# 
# elixir benchee.exs
# Operating System: Linux
# CPU Information: AMD Ryzen 9 5950X 16-Core Processor
# Number of Available Cores: 32
# Available memory: 62.72 GB
# Elixir 1.17.2
# Erlang 27.0
# JIT enabled: true

# Benchmark suite executing with the following configuration:
# warmup: 2 s
# time: 10 s
# memory time: 2 s
# reduction time: 0 ns
# parallel: 1
# inputs: none specified
# Estimated total run time: 1 min 38 s

# Benchmarking erlang json ...
# Benchmarking jason ...
# Benchmarking jason atom keys ...
# Benchmarking msgpax ...
# Benchmarking msgpax atom keys ...
# Benchmarking native ...
# Benchmarking poison ...
# Calculating statistics...
# Formatting results...

# Name                       ips        average  deviation         median         99th %
# native                  1.72 M      581.99 ns  ±2457.00%         450 ns        1150 ns
# msgpax                  1.44 M      694.17 ns  ±3597.63%         630 ns         830 ns
# poison                  1.33 M      751.57 ns  ±3124.63%         690 ns        1130 ns
# erlang json             1.33 M      753.56 ns  ±2897.06%         690 ns         970 ns
# jason                   1.07 M      937.89 ns  ±2244.52%         830 ns        1460 ns
# msgpax atom keys        0.73 M     1370.54 ns  ±1616.19%        1200 ns        2200 ns
# jason atom keys         0.68 M     1465.06 ns  ±1263.78%        1340 ns        2420 ns

# Comparison:
# native                  1.72 M
# msgpax                  1.44 M - 1.19x slower +112.18 ns
# poison                  1.33 M - 1.29x slower +169.57 ns
# erlang json             1.33 M - 1.29x slower +171.56 ns
# jason                   1.07 M - 1.61x slower +355.90 ns
# msgpax atom keys        0.73 M - 2.35x slower +788.54 ns
# jason atom keys         0.68 M - 2.52x slower +883.07 ns

# Memory usage statistics:

# Name                Memory usage
# native                   0.27 KB
# msgpax                   1.27 KB - 4.63x memory usage +0.99 KB
# poison                   1.09 KB - 3.97x memory usage +0.81 KB
# erlang json              0.83 KB - 3.03x memory usage +0.55 KB
# jason                    1.07 KB - 3.91x memory usage +0.80 KB
# msgpax atom keys            2 KB - 7.31x memory usage +1.73 KB
# jason atom keys          1.15 KB - 4.20x memory usage +0.88 KB

# **All measurements for memory usage were the same**
json_data = Jason.encode!(data)
binary_data = :erlang.term_to_binary(data)
msg_data = Msgpax.pack!(data)

Benchee.run(
  %{
    "native" => fn -> :erlang.binary_to_term(binary_data) end,
    "jason" => fn -> json_data |> Jason.decode!() end,
    "jason atom keys" => fn -> json_data |> Jason.decode!(keys: :atoms) end,
    "msgpax" => fn -> msg_data |> Msgpax.unpack!() end,
    "msgpax atom keys" => fn -> msg_data
      |> Msgpax.unpack!()
      |> Enum.into(%{}, fn {key, val} -> {String.to_atom(key), val} end)
    end,
    "erlang json" => fn -> json_data |> :json.decode() end,
    "poison" => fn -> json_data |> Poison.decode!() end,
  },
  time: 10,
  memory_time: 2
)
# Msgpax.pack!(data) |> Msgpax.unpack!() |> dbg
