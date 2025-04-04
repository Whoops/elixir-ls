defmodule ElixirLS.LanguageServer.Diagnostics do
  alias ElixirLS.LanguageServer.{SourceFile, JsonRpc}

  def normalize(diagnostics, root_path) do
    for diagnostic <- diagnostics do
      {type, file, position, description, stacktrace} =
        extract_message_info(diagnostic.message, root_path)

      diagnostic
      |> update_message(type, description, stacktrace)
      |> maybe_update_file(file)
      |> maybe_update_position(type, position, stacktrace)
    end
  end

  defp extract_message_info(diagnostic_message, root_path) do
    {reversed_stacktrace, reversed_description} =
      diagnostic_message
      |> IO.chardata_to_string()
      |> String.trim_trailing()
      |> SourceFile.lines()
      |> Enum.reverse()
      |> Enum.split_while(&is_stack?/1)

    message = reversed_description |> Enum.reverse() |> Enum.join("\n") |> String.trim()
    stacktrace = reversed_stacktrace |> Enum.map(&String.trim/1) |> Enum.reverse()

    {type, message_without_type} = split_type_and_message(message)
    {file, position, description} = split_file_and_description(message_without_type, root_path)

    {type, file, position, description, stacktrace}
  end

  defp update_message(diagnostic, type, description, stacktrace) do
    description =
      if type do
        "(#{type}) #{description}"
      else
        description
      end

    message =
      if stacktrace != [] do
        stacktrace =
          stacktrace
          |> Enum.map_join("\n", &"  │ #{&1}")
          |> String.trim_trailing()

        description <> "\n\n" <> "Stacktrace:\n" <> stacktrace
      else
        description
      end

    Map.put(diagnostic, :message, message)
  end

  defp maybe_update_file(diagnostic, path) do
    if path do
      Map.put(diagnostic, :file, path)
    else
      diagnostic
    end
  end

  defp maybe_update_position(diagnostic, "TokenMissingError", position, stacktrace) do
    case extract_line_from_missing_hint(diagnostic.message) do
      line when is_integer(line) and line > 0 ->
        %{diagnostic | position: line}

      _ ->
        do_maybe_update_position(diagnostic, position, stacktrace)
    end
  end

  defp maybe_update_position(diagnostic, _type, position, stacktrace) do
    do_maybe_update_position(diagnostic, position, stacktrace)
  end

  defp do_maybe_update_position(diagnostic, position, stacktrace) do
    cond do
      position != nil ->
        %{diagnostic | position: position}

      diagnostic.position ->
        diagnostic

      true ->
        line = extract_line_from_stacktrace(diagnostic.file, stacktrace)
        %{diagnostic | position: max(line, 0)}
    end
  end

  defp split_type_and_message(message) do
    case Regex.run(~r/^\*\* \(([\w\.]+?)?\) (.*)/su, message) do
      [_, type, rest] ->
        {type, rest}

      _ ->
        {nil, message}
    end
  end

  defp split_file_and_description(message, root_path) do
    with {file, line, column, description} <- get_message_parts(message),
         {:ok, path} <- file_path(file, root_path) do
      line = String.to_integer(line)

      position =
        cond do
          line == 0 -> 0
          column == "" -> line
          true -> {line, String.to_integer(column)}
        end

      {path, position, description}
    else
      _ ->
        {nil, nil, message}
    end
  end

  defp get_message_parts(message) do
    case Regex.run(~r/^(.*?):(\d+)(:(\d+))?: (.*)/su, message) do
      [_, file, line, _, column, description] -> {file, line, column, description}
      _ -> nil
    end
  end

  defp file_path(file, root_path) do
    path = Path.join([root_path, file])

    if File.exists?(path, [:raw]) do
      {:ok, path}
    else
      file_path_in_umbrella(file, root_path)
    end
  end

  defp file_path_in_umbrella(file, root_path) do
    case [root_path, "apps", "*", file] |> Path.join() |> Path.wildcard() do
      [] ->
        {:error, :file_not_found}

      [path] ->
        {:ok, path}

      _ ->
        {:error, :more_than_one_file_found}
    end
  end

  defp is_stack?("    " <> str) do
    Regex.match?(~r/.*\.(ex|erl):\d+: /u, str) ||
      Regex.match?(~r/.*expanding macro: /u, str)
  end

  defp is_stack?(_) do
    false
  end

  defp extract_line_from_missing_hint(message) do
    case Regex.run(
           ~r/HINT: it looks like the .+ on line (\d+) does not have a matching /u,
           message
         ) do
      [_, line] -> String.to_integer(line)
      _ -> nil
    end
  end

  defp extract_line_from_stacktrace(file, stacktrace) do
    Enum.find_value(stacktrace, fn stack_item ->
      with [_, _, file_relative, line] <-
             Regex.run(~r/(\(.+?\)\s+)?(.*\.ex):(\d+): /u, stack_item),
           true <- String.ends_with?(file, file_relative) do
        String.to_integer(line)
      else
        _ ->
          nil
      end
    end)
  end

  def publish_file_diagnostics(uri, uri_diagnostics, source_file, version) do
    diagnostics_json =
      for diagnostic <- uri_diagnostics do
        severity =
          case diagnostic.severity do
            :error -> 1
            :warning -> 2
            :information -> 3
            :hint -> 4
          end

        message =
          case diagnostic.message do
            m when is_binary(m) -> m
            m when is_list(m) -> m |> Enum.join("\n")
          end

        %{
          "message" => message,
          "severity" => severity,
          "range" => range(diagnostic.position, source_file),
          "source" => diagnostic.compiler_name
        }
      end
      |> Enum.sort_by(& &1["range"]["start"])

    message = %{
      "uri" => uri,
      "diagnostics" => diagnostics_json
    }

    message =
      if is_integer(version) do
        Map.put(message, "version", version)
      else
        message
      end

    JsonRpc.notify("textDocument/publishDiagnostics", message)
  end

  def mixfile_diagnostic({file, line, message}, severity) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "ElixirLS",
      file: file,
      position: line,
      message: message,
      severity: severity
    }
  end

  def code_diagnostic(%{
        file: file,
        severity: severity,
        message: message,
        position: position
      }) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "ElixirLS",
      file: file,
      position: position,
      message: message,
      severity: severity
    }
  end

  def error_to_diagnostic(kind, payload, stacktrace, path) do
    path = Path.absname(path)
    message = Exception.format(kind, payload, stacktrace)

    line =
      stacktrace
      |> Enum.find_value(fn {_m, _f, _a, opts} ->
        if opts |> Keyword.get(:file) |> Path.absname() == path do
          opts |> Keyword.get(:line)
        end
      end)

    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "ElixirLS",
      file: Path.absname(path),
      position: line || 0,
      message: message,
      severity: :error,
      details: payload
    }
  end

  def exception_to_diagnostic(error, path) do
    msg =
      case error do
        {:shutdown, 1} ->
          "Build failed for unknown reason. See output log."

        _ ->
          Exception.format_exit(error)
      end

    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "ElixirLS",
      file: path,
      # 0 means unknown
      position: 0,
      message: msg,
      severity: :error,
      details: error
    }
  end

  # for details see
  # https://hexdocs.pm/mix/1.13.4/Mix.Task.Compiler.Diagnostic.html#t:position/0
  # https://microsoft.github.io/language-server-protocol/specifications/specification-3-16/#diagnostic

  # position is a 1 based line number
  # we return a 0 length range at first non whitespace character in line
  defp range(line_start, source_file)
       when is_integer(line_start) and not is_nil(source_file) do
    # line is 1 based
    lines = SourceFile.lines(source_file)

    {line_start_lsp, char_start_lsp} =
      if line_start > 0 do
        case Enum.at(lines, line_start - 1) do
          nil ->
            # position is outside file range - this will return end of the file
            SourceFile.elixir_position_to_lsp(lines, {line_start, 1})

          line ->
            # find first non whitespace character in line
            start_idx = String.length(line) - String.length(String.trim_leading(line)) + 1
            {line_start - 1, SourceFile.elixir_character_to_lsp(line, start_idx)}
        end
      else
        # return begin of the file
        {0, 0}
      end

    %{
      "start" => %{
        "line" => line_start_lsp,
        "character" => char_start_lsp
      },
      "end" => %{
        "line" => line_start_lsp,
        "character" => char_start_lsp
      }
    }
  end

  # position is a 1 based line number and 0 based character cursor (UTF8)
  # we return a 0 length range exactly at that location
  defp range({line_start, char_start}, source_file)
       when not is_nil(source_file) do
    lines = SourceFile.lines(source_file)
    # elixir_position_to_lsp will handle positions outside file range
    {line_start_lsp, char_start_lsp} =
      SourceFile.elixir_position_to_lsp(lines, {line_start, char_start - 1})

    %{
      "start" => %{
        "line" => line_start_lsp,
        "character" => char_start_lsp
      },
      "end" => %{
        "line" => line_start_lsp,
        "character" => char_start_lsp
      }
    }
  end

  # position is a range defined by 1 based line numbers and 0 based character cursors (UTF8)
  # we return exactly that range
  defp range({line_start, char_start, line_end, char_end}, source_file)
       when not is_nil(source_file) do
    lines = SourceFile.lines(source_file)
    # elixir_position_to_lsp will handle positions outside file range
    {line_start_lsp, char_start_lsp} =
      SourceFile.elixir_position_to_lsp(lines, {line_start, char_start - 1})

    {line_end_lsp, char_end_lsp} =
      SourceFile.elixir_position_to_lsp(lines, {line_end, char_end - 1})

    %{
      "start" => %{
        "line" => line_start_lsp,
        "character" => char_start_lsp
      },
      "end" => %{
        "line" => line_end_lsp,
        "character" => char_end_lsp
      }
    }
  end

  # source file is unknown
  # we discard any position information as it is meaningless
  # unfortunately LSP does not allow `null` range so we need to return something
  defp range(_, _) do
    # we don't care about utf16 positions here as we send 0
    %{"start" => %{"line" => 0, "character" => 0}, "end" => %{"line" => 0, "character" => 0}}
  end
end
