defmodule Surface.Translator.ComponentTranslatorHelper do
  @moduledoc false

  alias Surface.Translator.SlotableTranslator
  alias Surface.IOHelper

  def add_render_call(renderer, args, has_children? \\ false) do
    ["<%= ", renderer, "(", Enum.join(args, ", "), ") ", maybe_add("do ", has_children?), "%>"]
  end

  def maybe_add(value, condition) do
    if condition, do: value, else: ""
  end

  def add_require(mod_str) do
    ["<% require ", mod_str, " %>"]
  end

  def add_begin_context(_mod, mod_str) do
    ["<% {props, context} = begin_context(props, context, ", mod_str, ") %>"]
  end

  def add_end_context(_mod, mod_str) do
    ["<% context = end_context(context, ", mod_str, ") %><% _ = context %>"]
  end

  defp find_bindings_from_lists(module, attributes) do
    # TODO: Warn if :binding is not defined and we have lhs
    for {name, {:attribute_expr, [expr], _}, _line} <- attributes,
        [lhs, _] <- [String.split(expr, "<-")],
        prop_info = module.__get_prop__(String.to_atom(name)),
        prop_info.type == :list,
        into: %{} do
      {String.to_atom(name), String.trim(lhs)}
    end
  end

  defp find_let_bindings(attributes, caller) do
    case Enum.find(attributes, fn attr -> match?({":let", _, _}, attr) end) do
      {":let", {:attribute_expr, [expr], _}, %{line: line}} ->
        bindings =
          expr
          |> validate_let_bindings_expr!(caller, line)
          |> Enum.map(fn {k, v} -> {k, Macro.to_string(v)} end)

        {bindings, line}

      _ ->
        {[], nil}
    end
  end

  defp validate_let_bindings_expr!(expr, caller, line) do
    expr = String.trim(expr)

    with {:ok, quoted_expr} <- expr_to_quoted(expr),
         true <- Keyword.keyword?(quoted_expr) do
      quoted_expr
    else
      _ ->
        message = """
        invalid value for directive :let. Expected a keyword list of bindings, \
        got: #{expr}.\
        """

        IOHelper.compile_error(message, caller.file, caller.line + line)
    end
  end

  defp expr_to_quoted(expr) do
    try do
      quoted_expr =
        "[#{expr}]"
        |> Code.string_to_quoted!()
        |> List.flatten()

      {:ok, quoted_expr}
    rescue
      e ->
        {:error, e}
    end
  end

  def translate_children(mod_str, mod, attributes, directives, children, caller) do
    {parent_bindings, line} = find_let_bindings(directives, caller)
    slots_with_args = get_slots_with_args(mod, attributes)

    validate_let_bindings!(
      :default,
      parent_bindings,
      slots_with_args[:default] || [],
      mod,
      caller,
      line
    )

    opts = %{
      parent: mod,
      parent_mod_str: mod_str,
      parent_args: parent_bindings,
      slots_with_args: slots_with_args,
      caller: caller
    }

    init_slots_meta = %{__default__: %{size: 0}}

    {slots_props, slots_meta, contents, _temp_contents, _opts} =
      children
      |> Enum.reduce({%{}, init_slots_meta, [], [], opts}, &handle_child/2)
      |> maybe_add_default_content()

    children_props =
      for {prop_name, value} <- slots_props do
        [to_string(prop_name), ": [", Enum.join(Enum.reverse(value), ", "), "]"]
      end

    {children_props, inspect(slots_meta), Enum.reverse(contents)}
  end

  def translate_attributes(attributes, mod, mod_str, space, caller, opts \\ []) do
    put_default_props = Keyword.get(opts, :put_default_props, true)

    if function_exported?(mod, :__props__, 0) do
      translated_values =
        Enum.reduce(attributes, [], fn {key, value, %{line: line, spaces: spaces}},
                                       translated_values ->
          key_atom = String.to_atom(key)
          prop = mod.__get_prop__(key_atom)

          if mod.__props__() != [] && !mod.__validate_prop__(key_atom) do
            message = "Unknown property \"#{key}\" for component <#{mod_str}>"
            IOHelper.warn(message, caller, &(&1 + line))
          end

          value = translate_value(prop[:type], key, value, caller, line)
          [{key, value, spaces, ","} | translated_values]
        end)

      translated_values =
        case translated_values do
          [{key, value, spaces, _} | rest] ->
            [{key, value, spaces, ""} | rest]

          _ ->
            translated_values
        end

      translated_props =
        Enum.reduce(translated_values, [], fn {key, value, spaces, comma}, translated_props ->
          [translate_prop(key, value, spaces, comma) | translated_props]
        end)

      props = ["%{", translated_props, space, "}"]

      if put_default_props do
        ["put_default_props(", props, ", ", mod_str, ")"]
      else
        props
      end
    else
      "%{}"
    end
  end

  def translate_value(:event, key, value, caller, line) do
    case value do
      {:attribute_expr, [expr], meta} ->
        {:attribute_expr, ["event_value(\"#{key}\", [#{expr}], assigns[:myself])"], meta}

      event ->
        if Module.open?(caller.module) do
          event_reference = {to_string(event), caller.line + line}
          Module.put_attribute(caller.module, :event_references, event_reference)
        end

        # TODO: We need to validate if this line is correct after the compiler is ready
        {:attribute_expr, ["event_value(\"#{key}\", \"#{event}\", assigns[:myself])"],
         %{line: line}}
    end
  end

  def translate_value(:list, _key, {:attribute_expr, [expr], meta}, _caller, _line) do
    value =
      case String.split(expr, "<-") do
        [_lhs, value] ->
          value

        [value] ->
          value
      end

    {:attribute_expr, [value], meta}
  end

  def translate_value(:css_class, _key, {:attribute_expr, [expr], meta}, _caller, _line) do
    # TODO: Validate expression
    {:attribute_expr, ["css_class([", expr, "])"], meta}
  end

  def translate_value(:keyword, key, {:attribute_expr, [expr], meta}, _caller, _line) do
    # TODO: Validate expression
    {:attribute_expr, ["keyword_value(\"", key, "\", ", expr, ")"], meta}
  end

  def translate_value(:map, key, {:attribute_expr, [expr], meta}, _caller, _line) do
    # TODO: Validate expression
    {:attribute_expr, ["map_value(\"", key, "\", ", expr, ")"], meta}
  end

  def translate_value(_type, _key, value, _caller, _line) when is_list(value) do
    for item <- value do
      case item do
        {:attribute_expr, [expr], _} ->
          ["\#{", expr, "}"]

        _ ->
          item
      end
    end
  end

  def translate_value(_type, _key, value, _caller, _line) do
    value
  end

  @blanks ' \n\r\t\v\b\f\e\d\a'

  def blank?([]), do: true

  def blank?([h | t]), do: blank?(h) && blank?(t)

  def blank?(""), do: true

  def blank?(char) when char in @blanks, do: true

  def blank?(<<h, t::binary>>) when h in @blanks, do: blank?(t)

  def blank?(_), do: false

  defp handle_child({_, _, _, %{translator: SlotableTranslator}} = child, acc) do
    {mod_str, attributes, children, meta} = child
    %{module: module, space: space, directives: directives, line: child_line} = meta
    {slots_props, slots_meta, contents, _, opts} = maybe_add_default_content(acc)

    {slot_name, slot_name_line} =
      if module do
        {module.__slot_name__(), child_line}
      else
        case Map.get(meta, :slot) do
          {value, line} ->
            {value, line}

          _ ->
            {nil, nil}
        end
      end

    slot_args = opts.slots_with_args[slot_name] || []
    slot_args_with_generators = Enum.filter(slot_args, fn {_k, v} -> v end)

    {child_bindings, line} = find_let_bindings(directives, opts.caller)
    validate_slot!(slot_name, opts.parent, opts.parent_mod_str, opts.caller, slot_name_line)

    validate_let_bindings!(
      slot_name,
      child_bindings,
      slot_args,
      module || opts.parent,
      opts.caller,
      line
    )

    merged_args = Keyword.merge(slot_args_with_generators, child_bindings)
    args = args_to_map_string(merged_args)

    slots_meta = Map.put_new(slots_meta, slot_name, %{size: 0})
    meta = slots_meta[slot_name]

    content = [
      "<% {",
      inspect(slot_name),
      ", ",
      to_string(meta.size),
      ", ",
      args,
      "} -> %>",
      children
    ]

    slots_meta = Map.put(slots_meta, slot_name, %{size: meta.size + 1})

    slots_props = Map.put_new(slots_props, slot_name, [])
    props = translate_attributes(attributes, module, mod_str, space, opts.caller)
    slots_props = Map.update(slots_props, slot_name, [], &[props | &1])

    {slots_props, slots_meta, [content | contents], [], opts}
  end

  defp handle_child(child, acc) do
    {slots_props, slots_meta, contents, temp_contents, opts} = acc
    {slots_props, slots_meta, contents, [child | temp_contents], opts}
  end

  defp maybe_add_default_content(acc) do
    {slots_props, slots_meta, contents, temp_contents, opts} = acc

    {slots_meta, contents} =
      if blank?(temp_contents) do
        {slots_meta, [Enum.reverse(temp_contents) | contents]}
      else
        meta = slots_meta[:__default__]
        args = args_to_map_string(opts.parent_args)

        content = [
          "<% {:__default__, ",
          to_string(meta.size),
          ", ",
          args,
          "} -> %>",
          Enum.reverse(temp_contents)
        ]

        slots_meta = update_in(slots_meta, [:__default__, :size], &(&1 + 1))
        {slots_meta, [content | contents]}
      end

    {slots_props, slots_meta, contents, [], opts}
  end

  defp get_slots_with_args(mod, attributes) do
    bindings = find_bindings_from_lists(mod, attributes)

    for %{name: name, opts: opts} <- mod.__slots__(),
        args_list = Keyword.get(opts, :props, []),
        into: %{} do
      args =
        for %{name: name, generator: generator} <- args_list do
          {name, bindings[generator]}
        end

      {name, args}
    end
  end

  defp args_to_map_string(args) do
    map_content =
      args
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join(", ")

    ["%{", map_content, "}"]
  end

  defp translate_prop(key, value, spaces, comma) do
    rhs =
      case value do
        {:attribute_expr, value, _} ->
          expr = value |> IO.iodata_to_binary() |> String.trim()
          ["(", expr, ")"]

        value when is_integer(value) ->
          to_string(value)

        value when is_boolean(value) ->
          inspect(value)

        _ ->
          [~S("), value, ~S(")]
      end

    case spaces do
      [space1, space2, space3] ->
        space = space2 <> space3
        space = if space != "", do: space, else: " "
        [space1, key, ":", space, rhs, comma]

      [space1, space2] ->
        [space1, key, ": ", rhs, comma, space2]
    end
  end

  defp validate_let_bindings!(_slot_name, _child_bindings, _slot_args, nil, _caller, _line) do
    # TODO
    :ok
  end

  defp validate_let_bindings!(slot_name, child_bindings, slot_args, mod, caller, line) do
    child_bindings_keys = Keyword.keys(child_bindings)
    slot_args_keys = Keyword.keys(slot_args)
    undefined_keys = child_bindings_keys -- slot_args_keys

    cond do
      child_bindings_keys != [] && slot_args_keys == [] ->
        message = """
        there's no `#{slot_name}` slot defined in `#{inspect(mod)}`.

        Directive :let can only be used on explicitly defined slots.

        Hint: You can define a `#{slot_name}` slot and its props using: \
        `slot #{slot_name}, props: #{inspect(child_bindings_keys)}\
        """

        IOHelper.compile_error(message, caller.file, caller.line + line)

      undefined_keys != [] ->
        [prop | _] = undefined_keys

        message = """
        undefined prop `#{inspect(prop)}` for slot `#{slot_name}` in `#{inspect(mod)}`.

        Available props: #{inspect(slot_args_keys)}.

        Hint: You can define a new slot prop using the `props` option: \
        `slot #{slot_name}, props: [..., #{inspect(prop)}]`\
        """

        IOHelper.compile_error(message, caller.file, caller.line + line)

      true ->
        nil
    end
  end

  defp validate_slot!(slot_name, parent_mod, parent_alias, caller, line) do
    cond do
      !function_exported?(parent_mod, :__slots__, 0) ->
        message = """
        parent component `#{inspect(parent_mod)}` does not define any slots. \
        Cannot insert component #{inspect(caller.module)} here.
        """

        IOHelper.compile_error(message, caller.file, caller.line)

      parent_mod.__get_slot__(slot_name) == nil ->
        parent_slots = parent_mod.__slots__() |> Enum.map(& &1.name)

        similar_slot_message =
          case did_you_mean(slot_name, parent_slots) do
            {similar, score} when score > 0.8 ->
              "\n\n  Did you mean #{inspect(to_string(similar))}?"

            _ ->
              ""
          end

        existing_slots_message =
          if parent_slots == [] do
            ""
          else
            slots = Enum.map(parent_slots, &to_string/1)
            available = list_to_string("slot:", "slots:", slots)
            "\n\n  Available #{available}"
          end

        message = """
        no slot "#{slot_name}" defined in parent component <#{parent_alias}>\
        #{similar_slot_message}\
        #{existing_slots_message}\
        """

        IOHelper.warn(message, caller, fn _ -> caller.line + line end)

      true ->
        :ok
    end
  end

  defp did_you_mean(target, list) do
    Enum.reduce(list, {nil, 0}, &max_similar(&1, to_string(target), &2))
  end

  defp max_similar(source, target, {_, current} = best) do
    score = source |> to_string() |> String.jaro_distance(target)
    if score < current, do: best, else: {source, score}
  end

  defp list_to_string(_singular, _plural, []) do
    ""
  end

  defp list_to_string(singular, _plural, [item]) do
    "#{singular} #{inspect(item)}"
  end

  defp list_to_string(_singular, plural, items) do
    [last | rest] = items |> Enum.map(&inspect/1) |> Enum.reverse()
    "#{plural} #{rest |> Enum.reverse() |> Enum.join(", ")} and #{last}"
  end
end
