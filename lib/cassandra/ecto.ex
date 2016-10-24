defmodule Cassandra.Ecto do

  alias Ecto.Query
  alias Ecto.Query.{BooleanExpr, JoinExpr, QueryExpr}

  @unquoted_name ~r/[a-zA-Z_0-9]{1,48}/
  @binary_operators_map %{
    :== => "=",
    :<  => "<",
    :>  => ">",
    :<= => "<=",
    :>= => ">=",
    :!= => "!=",
  }
  @binary_operators Map.keys(@binary_operators_map)

  def to_cql(%{sources: sources} = query) do
    assemble([
      select(query, sources),
      from(query, sources),
      where(query, sources),
    ])
  end

  defp from(%{from: {name, _schema}, prefix: prefix} = query, sources) do
    from = quote_table(prefix, name)
    "FROM #{from}"
  end

  defp select(%{select: %{fields: fields}} = query, sources) do
    "SELECT " <> select_fields(fields, sources, query)
  end

  defp where(%{wheres: []}, _), do: ""
  defp where(%{wheres: wheres} = query, sources) do
    "WHERE " <> boolean(wheres, sources, query)
  end

  defp boolean([%{expr: expr} | exprs], sources, query) do
    Enum.reduce exprs, paren_expr(expr, sources, query), fn
      %BooleanExpr{expr: e, op: :and}, acc ->
        acc <> " AND " <> paren_expr(e, sources, query)
      %BooleanExpr{expr: e, op: :and}, acc ->
        acc <> " OR " <> paren_expr(e, sources, query)
    end
  end

  defp select_fields([], _sources, _query) do
    raise ArgumentError, "bad select clause"
  end

  defp select_fields(fields, sources, query) do
    Enum.map_join fields, ", ", fn
      {key, value} ->
        expr(value, sources, query) <> " AS " <> quote_name(key)
      value ->
        expr(value, sources, query)
    end
  end

  defp quote_name(name) when is_atom(name) do
    name |> Atom.to_string |> quote_name
  end

  defp quote_name(name) do
    if Regex.match?(@unquoted_name, name) do
      <<?", name::binary, ?">>
    else
      raise ArgumentError, "bad field name #{inspect name}"
    end
  end

  defp quote_table(nil, name),    do: quote_table(name)
  defp quote_table(prefix, name), do: quote_table(prefix) <> "." <> quote_table(name)

  defp quote_table(name) when is_atom(name) do
    name |> Atom.to_string |> quote_table
  end

  defp quote_table(name) do
    if Regex.match?(@unquoted_name, name) do
      <<?", name::binary, ?">>
    else
      raise ArgumentError, "bad table name #{inspect name}"
    end
  end

  defp assemble(list) do
    list
    |> List.flatten
    |> Enum.join(" ")
  end

  Enum.map @binary_operators_map, fn {op, term} ->
    defp call_type(unquote(op), 2), do: {:binary_operator, unquote(term)}
  end

  defp call_type(func, _arity), do: {:func, Atom.to_string(func)}

  defp paren_expr(expr, sources, query) do
    "(" <> expr(expr, sources, query) <> ")"
  end

  defp expr({:^, [], [_]}, _sources, _query), do: "?"

  defp expr({{:., _, [{:&, _, [_]}, field]}, _, []}, _sources, _query) when is_atom(field) do
    quote_name(field)
  end

  defp expr({:&, _, [idx, fields, _counter]}, _sources, _query) do
    Enum.map_join(fields, ", ", &quote_name/1)
  end

  defp expr({:fragment, _, [kw]}, _sources, query) when is_list(kw) or tuple_size(kw) == 3 do
    raise ArgumentError, "Cassandra adapter does not support keyword or interpolated fragments for now!"
  end

  defp expr({:fragment, _, parts}, sources, query) do
    Enum.map_join parts, "", fn
      {:raw, str}   -> str
      {:expr, expr} -> expr(expr, sources, query)
    end
  end

  defp expr({fun, _, args}, sources, query)
  when is_atom(fun) and is_list(args)
  do
    case call_type(fun, length(args)) do
      {:binary_operator, op} ->
        [left, right] = Enum.map(args, &binary_op_arg_expr(&1, sources, query))
        "#{left} #{op} #{right}"

      {:func, func} ->
        params = Enum.map_join(args, ", ", &expr(&1, sources, query))
        "#{func}(#{params})"
    end
  end

  defp expr(nil,   _sources, _query), do: "NULL"
  defp expr(true,  _sources, _query), do: "TRUE"
  defp expr(false, _sources, _query), do: "FALSE"

  defp expr(value, _sources, _query) when is_bitstring(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error      -> "'#{escape_string(value)}'"
    end
  end

  defp expr(value, _sources, _query) when is_integer(value) or is_float(value) do
    "#{value}"
  end

  defp escape_string(value) when is_bitstring(value) do
    String.replace(value, "'", "''")
  end

  defp binary_op_arg_expr({op, _, [_, _]} = expr, sources, query)
  when op in @binary_operators do
    paren_expr(expr, sources, query)
  end

  defp binary_op_arg_expr(expr, sources, query) do
    expr(expr, sources, query)
  end
end