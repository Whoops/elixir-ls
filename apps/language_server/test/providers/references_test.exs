defmodule ElixirLS.LanguageServer.Providers.ReferencesTest do
  use ExUnit.Case, async: false

  alias ElixirLS.LanguageServer.Providers.References
  alias ElixirLS.LanguageServer.SourceFile
  alias ElixirLS.LanguageServer.Test.FixtureHelpers
  alias ElixirLS.LanguageServer.Tracer
  alias ElixirLS.LanguageServer.Build
  require ElixirLS.Test.TextLoc

  setup_all context do
    File.rm_rf!(FixtureHelpers.get_path(".elixir_ls/calls.dets"))
    {:ok, pid} = Tracer.start_link([])
    Tracer.set_project_dir(FixtureHelpers.get_path(""))

    compiler_options = Code.compiler_options()
    Build.set_compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(compiler_options)
      Process.monitor(pid)

      GenServer.stop(pid)

      receive do
        {:DOWN, _, _, _, _} -> :ok
      end
    end)

    Code.compile_file(FixtureHelpers.get_path("references_referenced.ex"))
    Code.compile_file(FixtureHelpers.get_path("references_imported.ex"))
    Code.compile_file(FixtureHelpers.get_path("references_remote.ex"))
    Code.compile_file(FixtureHelpers.get_path("uses_macro_a.ex"))
    Code.compile_file(FixtureHelpers.get_path("macro_a.ex"))
    Code.compile_file(FixtureHelpers.get_path("references_erlang.ex"))
    Code.compile_file(FixtureHelpers.get_path("references_alias.ex"))
    {:ok, context}
  end

  test "finds local, remote and imported references to a function" do
    file_path = FixtureHelpers.get_path("references_referenced.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)

    {line, char} = {1, 8}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
      def referenced_fun do
            ^
    """)

    list = References.references(text, uri, line, char, true)

    assert length(list) == 3
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_remote.ex")))
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_imported.ex")))
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_referenced.ex")))
  end

  test "finds local, remote and imported references to a macro" do
    file_path = FixtureHelpers.get_path("references_referenced.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)

    {line, char} = {8, 12}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
      defmacro referenced_macro(clause, do: expression) do
                ^
    """)

    list = References.references(text, uri, line, char, true)

    assert length(list) == 3
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_remote.ex")))
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_imported.ex")))
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_referenced.ex")))
  end

  test "find a references to a macro generated function call" do
    file_path = FixtureHelpers.get_path("uses_macro_a.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)
    {line, char} = {6, 13}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
        macro_a_func()
                 ^
    """)

    assert References.references(text, uri, line, char, true) == [
             %{
               "range" => %{
                 "end" => %{"character" => 16, "line" => 6},
                 "start" => %{"character" => 4, "line" => 6}
               },
               "uri" => uri
             }
           ]
  end

  test "finds a references to a macro imported function call" do
    file_path = FixtureHelpers.get_path("uses_macro_a.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)
    {line, char} = {10, 4}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
        macro_imported_fun()
        ^
    """)

    assert References.references(text, uri, line, char, true) == [
             %{
               "range" => %{
                 "start" => %{"line" => 10, "character" => 4},
                 "end" => %{"line" => 10, "character" => 22}
               },
               "uri" => uri
             }
           ]
  end

  test "finds references to a variable" do
    file_path = FixtureHelpers.get_path("references_referenced.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)
    {line, char} = {4, 14}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
        IO.puts(referenced_variable + 1)
                  ^
    """)

    assert References.references(text, uri, line, char, true) == [
             %{
               "range" => %{
                 "end" => %{"character" => 23, "line" => 2},
                 "start" => %{"character" => 4, "line" => 2}
               },
               "uri" => uri
             },
             %{
               "range" => %{
                 "end" => %{"character" => 31, "line" => 4},
                 "start" => %{"character" => 12, "line" => 4}
               },
               "uri" => uri
             }
           ]
  end

  test "finds references to an attribute" do
    file_path = FixtureHelpers.get_path("references_referenced.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)
    {line, char} = {24, 5}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
      @referenced_attribute \"123\"
         ^
    """)

    assert References.references(text, uri, line, char, true) == [
             %{
               "range" => %{
                 "end" => %{"character" => 23, "line" => 24},
                 "start" => %{"character" => 2, "line" => 24}
               },
               "uri" => uri
             },
             %{
               "range" => %{
                 "end" => %{"character" => 25, "line" => 27},
                 "start" => %{"character" => 4, "line" => 27}
               },
               "uri" => uri
             }
           ]
  end

  test "finds remote references to erlang function" do
    file_path = FixtureHelpers.get_path("references_referenced.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)

    {line, char} = {31, 10}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
        :ets.new(:abc, [])
              ^
    """)

    list = References.references(text, uri, line, char, true)

    assert length(list) == 2
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_erlang.ex")))
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_referenced.ex")))
  end

  test "finds remote references to erlang module" do
    file_path = FixtureHelpers.get_path("references_referenced.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)

    {line, char} = {31, 6}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
        :ets.new(:abc, [])
          ^
    """)

    list = References.references(text, uri, line, char, true)

    assert length(list) == 2
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_erlang.ex")))
    assert Enum.any?(list, &(&1["uri"] |> String.ends_with?("references_referenced.ex")))
  end

  test "finds alias references" do
    file_path = FixtureHelpers.get_path("references_referenced.ex")
    text = File.read!(file_path)
    uri = SourceFile.Path.to_uri(file_path)

    {line, char} = {0, 25}

    ElixirLS.Test.TextLoc.annotate_assert(file_path, line, char, """
    defmodule ElixirLS.Test.ReferencesReferenced do
                             ^
    """)

    list =
      References.references(text, uri, line, char, true)
      |> Enum.filter(&String.ends_with?(&1["uri"], "references_alias.ex"))

    references_lines = Enum.map(list, & &1["range"]["start"]["line"])

    assert references_lines == [1, 2, 3, 4, 7, 11, 15, 19, 20]
  end
end
