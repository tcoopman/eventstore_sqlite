defmodule EventstoreSqlite.Sync.StatePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias EventstoreSqlite.Sync.Import
  alias EventstoreSqlite.Sync.Selector
  alias EventstoreSqlite.Sync.State
  alias EventstoreSqlite.SystemEvents.NodeRetired
  alias EventstoreSqlite.SystemEvents.OwnershipAssigned
  alias EventstoreSqlite.SystemEvents.OwnershipReleased
  alias EventstoreSqlite.SystemEvents.OwnershipRevoked
  alias EventstoreSqlite.SystemEvents.ReleaseIgnored
  alias EventstoreSqlite.SystemEvents.SyncEnabled

  @home "home"
  @nodes ["n1", "n2"]
  @selectors ["a:*", "a:b*", "b:*", "c", "a:x", "b:1"]
  @streams ["a:1", "a:b1", "a:x", "b:1", "b:2", "c", "d"]

  defp operation do
    one_of([
      tuple({constant(:assign), member_of(@selectors), member_of(@nodes)}),
      tuple({constant(:release), integer(1..30)}),
      tuple({constant(:revoke), member_of(@nodes)})
    ])
  end

  defp initial do
    state = State.apply(%State{}, %SyncEnabled{node_id: @home, home: @home, sync_id: "g"})
    {state, %{active: %{}, released: %{}, revoked: %{}, retired: MapSet.new()}, [], 1}
  end

  defp step({:assign, selector, node}, {state, model, events, seq}) do
    if MapSet.member?(model.retired, node) or
         Enum.any?(model.active, fn {_, {active, _}} -> Selector.overlap?(active, selector) end) do
      {state, model, events, seq}
    else
      emit(
        {state, model, events, seq + 1},
        [%OwnershipAssigned{selector: selector, to: node, generation: seq}],
        fn model ->
          put_in(model.active[seq], {selector, node})
        end
      )
    end
  end

  defp step({:release, generation}, {state, model, events, seq} = acc) do
    case model.active[generation] do
      {_selector, node} ->
        emit(
          {state, model, events, seq + 1},
          [%OwnershipReleased{generation: generation, from: node, release_seq: seq}],
          fn model ->
            %{model | active: Map.delete(model.active, generation), released: Map.put(model.released, generation, node)}
          end
        )

      nil ->
        if Map.has_key?(model.released, generation) or Map.has_key?(model.revoked, generation) do
          emit(acc, [%ReleaseIgnored{generation: generation, from: "n1"}], & &1)
        else
          acc
        end
    end
  end

  defp step({:revoke, node}, {state, model, events, seq}) do
    if MapSet.member?(model.retired, node) do
      {state, model, events, seq}
    else
      revoked = for {generation, {selector, ^node}} <- model.active, do: {generation, selector}

      new_events =
        Enum.map(revoked, fn {generation, selector} ->
          %OwnershipRevoked{generation: generation, selector: selector, from: node, cutoff: 0}
        end) ++ [%NodeRetired{node_id: node, revoke_seq: seq}]

      emit({state, model, events, seq + 1}, new_events, fn model ->
        %{
          model
          | active: Map.drop(model.active, Enum.map(revoked, &elem(&1, 0))),
            revoked: Enum.reduce(revoked, model.revoked, fn {g, s}, acc -> Map.put(acc, g, {s, node}) end),
            retired: MapSet.put(model.retired, node)
        }
      end)
    end
  end

  defp emit({state, model, events, seq}, new_events, update_model) do
    {Enum.reduce(new_events, state, &State.apply(&2, &1)), update_model.(model), events ++ new_events, seq}
  end

  defp naive_owner(model, stream) do
    Enum.find_value(model.active, {@home, 0}, fn {generation, {selector, node}} ->
      if Selector.matches?(selector, stream), do: {node, generation}
    end)
  end

  defp naive_authorize(model, origin, stream, generation) do
    cond do
      match?({_, ^origin}, model.active[generation]) and Selector.matches?(elem(model.active[generation], 0), stream) ->
        :apply

      generation == 0 and origin == @home and naive_owner(model, stream) == {@home, 0} ->
        :apply

      match?({_, ^origin}, model.revoked[generation]) and Selector.matches?(elem(model.revoked[generation], 0), stream) ->
        :quarantine

      true ->
        :halt
    end
  end

  property "the replayed state matches a naive model of assignments, releases and revocations" do
    check all(operations <- list_of(operation(), max_length: 40)) do
      {state, model, events, _seq} = Enum.reduce(operations, initial(), &step/2)

      assert state.owners ==
               Map.new(model.active, fn {g, {selector, node}} -> {g, %{selector: selector, owner: node}} end)

      assert state.released |> Map.keys() |> Enum.sort() == model.released |> Map.keys() |> Enum.sort()
      assert state.revoked |> Map.keys() |> Enum.sort() == model.revoked |> Map.keys() |> Enum.sort()
      assert state.retired |> Map.keys() |> MapSet.new() == model.retired

      assert State.replay([%SyncEnabled{node_id: @home, home: @home, sync_id: "g"}], events) == state

      for stream <- @streams do
        assert State.owner(state, stream) == naive_owner(model, stream)

        for origin <- [@home | @nodes], generation <- 0..30 do
          decision =
            case Import.authorize(state, origin, %{stream_id: stream, generation: generation}) do
              {:halt, _} -> :halt
              decision -> decision
            end

          assert decision == naive_authorize(model, origin, stream, generation)
        end
      end

      for {a, _} <- model.active, {b, _} <- model.active, a < b do
        refute Selector.overlap?(elem(model.active[a], 0), elem(model.active[b], 0))
      end
    end
  end
end
