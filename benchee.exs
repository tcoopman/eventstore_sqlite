Mix.install([
  {:benchee, "~> 1.0"},
  {:msgpax, "~> 2.4.0"},
  {:jason, "~> 1.5.0-alpha.2"}
])

data = %{a: 1, b: 2, c: [1, 2, 3], d: "Some string in here as well"}

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
    end
  },
  time: 10,
  memory_time: 2
)

# Msgpax.pack!(data) |> Msgpax.unpack!() |> dbg
