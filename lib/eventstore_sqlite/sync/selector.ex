defmodule EventstoreSqlite.Sync.Selector do
  @moduledoc false

  @doc """
  Parses a selector: an exact stream name, or a prefix ending in a single
  trailing `*` (`"venue:*"`). Raises `ArgumentError` for a `*` anywhere else,
  an empty selector, or a selector naming system streams (starting with `$`).
  """
  def parse!(selector) when is_binary(selector) do
    cond do
      selector == "" ->
        raise ArgumentError, "a selector can't be empty"

      String.starts_with?(selector, "$") ->
        raise ArgumentError, "system streams have no owner, got selector: #{inspect(selector)}"

      String.ends_with?(selector, "*") ->
        prefix = String.slice(selector, 0..-2//1)
        if String.contains?(prefix, "*"), do: raise_wildcard(selector)
        {:prefix, prefix}

      String.contains?(selector, "*") ->
        raise_wildcard(selector)

      true ->
        {:exact, selector}
    end
  end

  def parse!(selector), do: raise(ArgumentError, "expected a selector string, got: #{inspect(selector)}")

  defp raise_wildcard(selector) do
    raise ArgumentError, "only a single trailing * is supported in a selector, got: #{inspect(selector)}"
  end

  def matches?(selector, stream_id) when is_binary(selector), do: matches?(parse!(selector), stream_id)
  def matches?({:exact, name}, stream_id), do: name == stream_id
  def matches?({:prefix, prefix}, stream_id), do: String.starts_with?(stream_id, prefix)

  def overlap?(a, b) when is_binary(a), do: overlap?(parse!(a), b)
  def overlap?(a, b) when is_binary(b), do: overlap?(a, parse!(b))
  def overlap?({:exact, a}, {:exact, b}), do: a == b
  def overlap?({:exact, name}, {:prefix, prefix}), do: String.starts_with?(name, prefix)
  def overlap?({:prefix, _} = prefix, {:exact, _} = exact), do: overlap?(exact, prefix)

  def overlap?({:prefix, a}, {:prefix, b}), do: String.starts_with?(a, b) or String.starts_with?(b, a)
end
