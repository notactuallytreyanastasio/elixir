%% SPDX-License-Identifier: Apache-2.0
-module(elixir_situation).
-export(['situation'/4, is_claude_cli/1, format_error/1]).
-import(elixir_errors, [file_error/4]).
-include("elixir.hrl").

%% Main entry point — parallel to elixir_clauses:'case'/4

'situation'(Meta, [], _S, E) ->
  file_error(Meta, E, elixir_expand, {missing_option, 'situation', [do]});
'situation'(Meta, Opts, _S, E) when not is_list(Opts) ->
  file_error(Meta, E, elixir_expand, {invalid_args, 'situation'});
'situation'(Meta, Opts, S, E) ->
  ok = elixir_clauses:assert_at_most_once('do', Opts, 0, fun(Key) ->
    file_error(Meta, E, elixir_clauses, {duplicated_clauses, 'situation', Key})
  end),
  {Result, SA} = lists:mapfoldl(fun(X, SA) ->
    expand_situation_opt(Meta, X, SA, E)
  end, S, Opts),
  {Result, SA, E}.

expand_situation_opt(Meta, {'do', _} = Do, S, E) ->
  expand_situation_clauses(Meta, Do, S, E);
expand_situation_opt(Meta, {Key, _}, _S, E) ->
  file_error(Meta, E, elixir_clauses, {unexpected_option, 'situation', Key}).

%% Clause expansion — like expand_clauses_origin but with hole interception

expand_situation_clauses(Meta, {Key, [_ | _] = Clauses}, S, E) ->
  Transformer = fun(Clause, SA) ->
    {EClause, SAcc, EAcc} =
      expand_situation_clause(Meta, Clause, elixir_env:reset_unused_vars(SA), E),
    {EClause, elixir_env:merge_and_check_unused_vars(SAcc, SA, EAcc)}
  end,
  {Values, SE} = lists:mapfoldl(Transformer, S, Clauses),
  {{Key, Values}, SE};
expand_situation_clauses(Meta, {Key, _}, _, E) ->
  file_error(Meta, E, elixir_clauses, {bad_or_missing_clauses, {'situation', Key}}).

%% Individual clause expansion with hole detection

expand_situation_clause(Meta, {'->', CMeta, [Left, Right]}, S, E) ->
  %% Expand the left side (pattern) using case head expansion
  Fun = elixir_clauses:expand_head('situation', 'do'),
  {ELeft, SL, EL} = Fun(CMeta, Left, S, E),

  %% Check if the right side is a hole
  case detect_hole(Right) of
    {hole, Intent} ->
      File = maps:get(file, EL, <<"nofile">>),
      Line = case lists:keyfind(line, 1, CMeta) of
        {line, L} -> L; false -> 0
      end,
      Module = maps:get(module, EL, nil),
      {FunName, FunArity} = case maps:get(function, EL, nil) of
        {N, A} -> {N, A}; _ -> {'?', 0}
      end,
      Pattern = iolist_to_binary('Elixir.Macro':to_string(ELeft)),

      %% Print header
      io:format(standard_error,
        "\n\e[36m┌─ situation\e[0m ~ts:~B \e[2m~s.~s/~B\e[0m\n"
        "\e[36m│\e[0m \e[2mpattern:\e[0m ~ts\n"
        "\e[36m│\e[0m \e[2mintent:\e[0m\n",
        [File, Line, Module, FunName, FunArity, Pattern]),
      print_indented_lines(string:trim(Intent)),
      io:format(standard_error, "\e[36m│\e[0m\n\e[36m│\e[0m \e[33mInvoking Claude...\e[0m\n", []),

      %% Gather context and invoke LLM
      Context = gather_context(ELeft, SL, EL),
      {RawCode, Generated} = invoke_llm(Intent, Context, CMeta, EL),

      %% Print generated code
      io:format(standard_error, "\e[36m│\e[0m \e[32mGenerated:\e[0m\n", []),
      print_indented_lines(RawCode),

      %% Rewrite the source file
      rewrite_source(File, Line, Right, RawCode),

      %% Show git diff
      show_diff(File),

      io:format(standard_error, "\e[36m└─\e[0m\n\n", []),

      %% Expand the generated code as the clause body
      {ERight, SR, ER} = elixir_expand:expand(Generated, SL, EL),
      {{'->', CMeta, [ELeft, ERight]}, SR, ER};
    false ->
      %% Normal clause — expand body directly
      {ERight, SR, ER} = elixir_expand:expand(Right, SL, EL),
      {{'->', CMeta, [ELeft, ERight]}, SR, ER}
  end;
expand_situation_clause(Meta, _, _, E) ->
  file_error(Meta, E, elixir_clauses, {bad_or_missing_clauses, {'situation', 'do'}}).

%% ===================================================================
%% Diagnostic output helpers
%% ===================================================================

print_indented_lines(Text) ->
  Lines = string:split(unicode:characters_to_list(Text), "\n", all),
  lists:foreach(fun(Line) ->
    io:format(standard_error, "\e[36m│\e[0m   ~ts\n", [Line])
  end, Lines).

show_diff(File) ->
  FilePath = unicode:characters_to_list(File),
  Cmd = lists:flatten(["git diff --no-color -- \"", FilePath, "\" 2>/dev/null"]),
  case os:cmd(Cmd) of
    [] -> ok;
    Diff ->
      io:format(standard_error, "\e[36m│\e[0m\n\e[36m│\e[0m \e[2mdiff:\e[0m\n", []),
      DiffLines = string:split(Diff, "\n", all),
      lists:foreach(fun(DLine) ->
        Colored = color_diff_line(DLine),
        io:format(standard_error, "\e[36m│\e[0m   ~ts\n", [Colored])
      end, DiffLines)
  end.

color_diff_line([$+ | _] = Line) -> "\e[32m" ++ Line ++ "\e[0m";
color_diff_line([$- | _] = Line) -> "\e[31m" ++ Line ++ "\e[0m";
color_diff_line([$@ | _] = Line) -> "\e[35m" ++ Line ++ "\e[0m";
color_diff_line(Line) -> Line.

%% ===================================================================
%% Source file rewriting
%% ===================================================================

%% Replace the ___("...") call in the source file with generated code.
%% Scans for the literal text ___( starting near the hole's line,
%% then finds the matching close paren to determine the full extent.

rewrite_source(File, Line, _HoleExpr, RawCode) ->
  FilePath = unicode:characters_to_list(File),
  case file:read_file(FilePath) of
    {ok, Source} ->
      %% Find byte offset of the target line
      LineOffset = offset_of_line(Source, Line),
      %% Scan forward from that line for ___( or ___.(
      case find_hole_call(Source, LineOffset) of
        {Start, End} ->
          %% Determine indentation of the ___( call
          Indent = column_at(Source, Start),
          IndentStr = lists:duplicate(Indent, $\s),

          %% Indent the generated code to match
          Trimmed = unicode:characters_to_binary(string:trim(RawCode)),
          CodeLines = binary:split(Trimmed, <<"\n">>, [global]),
          Indented = indent_code(CodeLines, IndentStr),

          %% Replace in source
          Before = binary:part(Source, 0, Start),
          After = binary:part(Source, End, byte_size(Source) - End),
          NewSource = <<Before/binary, Indented/binary, After/binary>>,
          file:write_file(FilePath, NewSource);
        not_found ->
          ok
      end;
    {error, _} ->
      ok
  end.

%% Find the byte offset of a given line number (1-based)
offset_of_line(Source, Line) ->
  offset_of_line(Source, 1, 0, Line).

offset_of_line(_Source, Current, Offset, Target) when Current >= Target -> Offset;
offset_of_line(Source, Current, Offset, Target) when Offset >= byte_size(Source) -> Offset;
offset_of_line(Source, Current, Offset, Target) ->
  case binary:at(Source, Offset) of
    $\n -> offset_of_line(Source, Current + 1, Offset + 1, Target);
    _   -> offset_of_line(Source, Current, Offset + 1, Target)
  end.

%% Scan forward from Offset looking for ___( or ___.(
%% Returns {Start, End} where Start is the byte of the first _
%% and End is the byte after the closing )
find_hole_call(Source, Offset) ->
  case binary:match(Source, [<<"___(">>, <<"___.(">>, <<"___.(\"">>], [{scope, {Offset, byte_size(Source) - Offset}}]) of
    {Start, MatchLen} ->
      %% Find the opening paren
      ParenPos = Start + MatchLen - 1,
      %% Find the matching close paren
      case find_matching_paren(Source, ParenPos, 0) of
        {ok, ClosePos} -> {Start, ClosePos + 1};
        error -> not_found
      end;
    nomatch ->
      not_found
  end.

%% Find matching close paren, handling nested parens and strings
find_matching_paren(Source, Pos, _Depth) when Pos >= byte_size(Source) -> error;
find_matching_paren(Source, Pos, Depth) ->
  case binary:at(Source, Pos) of
    $( -> find_matching_paren(Source, Pos + 1, Depth + 1);
    $) when Depth =:= 1 -> {ok, Pos};
    $) -> find_matching_paren(Source, Pos + 1, Depth - 1);
    $" -> skip_string(Source, Pos + 1, Depth);
    _  -> find_matching_paren(Source, Pos + 1, Depth)
  end.

%% Skip past a string literal (handling escaped quotes)
skip_string(Source, Pos, Depth) when Pos >= byte_size(Source) -> error;
skip_string(Source, Pos, Depth) ->
  case binary:at(Source, Pos) of
    $\\ -> skip_string(Source, Pos + 2, Depth);  %% skip escaped char
    $"  -> find_matching_paren(Source, Pos + 1, Depth);
    _   -> skip_string(Source, Pos + 1, Depth)
  end.

%% Find the column (number of spaces from start of line) at a byte position
column_at(Source, Pos) ->
  column_at(Source, Pos, 0).

column_at(_Source, 0, Acc) -> Acc;
column_at(Source, Pos, Acc) ->
  case binary:at(Source, Pos - 1) of
    $\n -> Acc;
    _   -> column_at(Source, Pos - 1, Acc + 1)
  end.

%% Indent all lines of generated code except the first
indent_code([First], _Indent) -> First;
indent_code([First | Rest], Indent) ->
  IndentBin = unicode:characters_to_binary(Indent),
  Indented = [<<IndentBin/binary, L/binary>> || L <- Rest, L =/= <<>>],
  iolist_to_binary(lists:join(<<"\n">>, [First | Indented]));
indent_code([], _Indent) -> <<>>.

%% Hole detection
%%
%% Recognized forms:
%%   ___("intent")     — function call syntax: {:___, meta, ["intent"]}
%%   ___.("intent")    — anonymous call syntax (also supported for backwards compat)

detect_hole({'___', _, [Intent]}) when is_binary(Intent) ->
  {hole, Intent};
detect_hole({{'.', _, [{'___', _, Kind}]}, _, [Intent]})
    when is_atom(Kind), is_binary(Intent) ->
  {hole, Intent};
detect_hole(_) ->
  false.

%% Context gathering (base — enriched by Expert when available)

gather_context(Pattern, _S, E) ->
  Base = #{
    module    => maps:get(module, E, nil),
    function  => maps:get(function, E, nil),
    file      => maps:get(file, E, <<"nofile">>),
    line      => maps:get(line, E, 0),
    pattern   => iolist_to_binary('Elixir.Macro':to_string(Pattern)),
    aliases   => maps:get(aliases, E, []),
    imports   => format_imports(maps:get(functions, E, #{}))
  },
  case connect_to_expert_engine() of
    {ok, Node} -> enrich_with_expert(Base, Node, E);
    error      -> Base
  end.

format_imports(Imports) when is_map(Imports) ->
  maps:fold(fun(Mod, Funs, Acc) ->
    FormattedFuns = [io_lib:format("~s/~B", [F, A]) || {F, A} <- Funs],
    [{Mod, FormattedFuns} | Acc]
  end, [], Imports);
format_imports(Imports) when is_list(Imports) ->
  lists:foldl(fun({Mod, Funs}, Acc) ->
    FormattedFuns = [io_lib:format("~s/~B", [F, A]) || {F, A} <- Funs],
    [{Mod, FormattedFuns} | Acc]
  end, [], Imports);
format_imports(_) -> [].

%% Expert Language Server integration

connect_to_expert_engine() ->
  case elixir_config:get(situation_expert_node, false) of
    false ->
      %% Auto-discover Expert engine node
      Nodes = [N || N <- erlang:nodes(known),
               is_expert_engine_node(N)],
      case Nodes of
        [Node | _] -> {ok, Node};
        [] -> error
      end;
    Node when is_atom(Node) ->
      {ok, Node}
  end.

is_expert_engine_node(Node) ->
  case atom_to_list(Node) of
    "expert_engine" ++ _ -> true;
    _ -> false
  end.

enrich_with_expert(Context, Node, E) ->
  Module = maps:get(module, E, nil),
  Function = maps:get(function, E, nil),
  try
    %% Get references for current function
    Refs = case Function of
      {FunName, Arity} ->
        Subject = iolist_to_binary(io_lib:format("~s.~s/~B", [Module, FunName, Arity])),
        erpc:call(Node, 'Elixir.Engine.Search.Store', exact,
          [Subject, [{type, {function, usage}}, {subtype, reference}]], 5000);
      _ -> []
    end,

    %% Get module type specs/attributes
    Specs = erpc:call(Node, 'Elixir.Engine.Search.Store', exact,
      [atom_to_list(Module), [{type, module_attribute}]], 5000),

    Context#{
      references => format_refs(Refs),
      type_specs => format_specs(Specs)
    }
  catch
    _:_ ->
      %% Expert query failed — return base context
      Context
  end.

format_refs(Refs) when is_list(Refs) ->
  [maps:get(subject, R, <<"">>) || R <- Refs, is_map(R)];
format_refs(_) -> [].

format_specs(Specs) when is_list(Specs) ->
  [maps:get(subject, S, <<"">>) || S <- Specs, is_map(S)];
format_specs(_) -> [].

%% ===================================================================
%% LLM invocation
%% ===================================================================

invoke_llm(Intent, Context, Meta, E) ->
  case elixir_config:get(situation_command, false) of
    false ->
      file_error(Meta, E, ?MODULE, situation_not_configured);
    Command ->
      Timeout = elixir_config:get(situation_timeout, 30000),
      UserPrompt = build_user_prompt(Intent, Context),
      case invoke_command(Command, UserPrompt, Timeout) of
        {ok, Code} ->
          Trimmed = string:trim(Code),
          Parsed = parse_code(Trimmed, Meta, E),
          {Trimmed, Parsed};
        {error, timeout} ->
          file_error(Meta, E, ?MODULE, {hole_invocation_timeout, Timeout});
        {error, Reason} ->
          file_error(Meta, E, ?MODULE, {hole_invocation_error, Reason})
      end
  end.

%% System prompt — tells the LLM how to behave.
%% Separated from user prompt so Claude CLI receives it via --system-prompt.

system_prompt() ->
  "You are the Elixir compiler's code generation backend. "
  "You receive a code context and an intent description, and you output "
  "a single Elixir expression that fulfills the intent.\n\n"
  "RULES:\n"
  "1. Output ONLY the Elixir expression. Nothing else.\n"
  "2. No markdown fences, no explanation, no comments, no module definition.\n"
  "3. The expression will be inserted as a clause body in a case-like block.\n"
  "4. Variables from the matched pattern are in scope — use them directly.\n"
  "5. Imported functions are available — do not qualify them.\n"
  "6. The code must be a valid Elixir expression that the parser can handle.\n"
  "7. Prefer simple, idiomatic Elixir. No metaprogramming.\n"
  "8. If the intent is empty, return a reasonable default for the pattern.".

%% User prompt — the context and intent for this specific hole.

build_user_prompt(Intent, Context) ->
  Module = maps:get(module, Context, nil),
  Function = maps:get(function, Context, nil),
  Pattern = maps:get(pattern, Context, <<"">>),
  Imports = maps:get(imports, Context, []),
  Refs = maps:get(references, Context, []),
  Specs = maps:get(type_specs, Context, []),

  FunStr = case Function of
    {Name, Arity} -> io_lib:format("~s/~B", [Name, Arity]);
    _ -> "unknown"
  end,

  ImportStr = lists:foldl(fun({Mod, Funs}, Acc) ->
    [io_lib:format("  ~s: ~s~n", [Mod, lists:join(", ", Funs)]) | Acc]
  end, [], Imports),

  RefStr = case Refs of
    [] -> "  (none available)\n";
    _ -> lists:foldl(fun(R, Acc) -> [io_lib:format("  ~s~n", [R]) | Acc] end, [], Refs)
  end,

  SpecStr = case Specs of
    [] -> "  (none available)\n";
    _ -> lists:foldl(fun(S, Acc) -> [io_lib:format("  ~s~n", [S]) | Acc] end, [], Specs)
  end,

  iolist_to_binary([
    "Module: ", atom_to_list(Module), "\n",
    "Function: ", FunStr, "\n",
    "Matched pattern: ", Pattern, "\n\n",
    "Available imports:\n", ImportStr, "\n",
    "References in this function:\n", RefStr, "\n",
    "Type specs:\n", SpecStr, "\n",
    "Intent: ", Intent, "\n"
  ]).

%% ===================================================================
%% Command invocation
%% ===================================================================

invoke_command(Command, UserPrompt, Timeout) ->
  case is_claude_cli(Command) of
    true  -> invoke_claude_cli(Command, UserPrompt, Timeout);
    false -> invoke_raw_command(Command, UserPrompt, Timeout)
  end.

is_claude_cli(Command) ->
  Trimmed = string:trim(Command),
  FirstWord = hd(string:split(Trimmed, " ")),
  Basename = filename:basename(unicode:characters_to_list(FirstWord)),
  Basename =:= "claude".

invoke_claude_cli(BaseCommand, UserPrompt, Timeout) ->
  Model = elixir_config:get(situation_model, "sonnet"),
  SystemPrompt = system_prompt(),

  TmpFile = tmp_file(),
  ok = file:write_file(TmpFile, UserPrompt),

  EscapedSystemPrompt = lists:flatten(shell_escape(SystemPrompt)),

  FullCmd = lists:flatten([
    unicode:characters_to_list(BaseCommand),
    " --print --dangerously-skip-permissions"
    " --output-format text --model ",
    unicode:characters_to_list(Model),
    " --system-prompt ", EscapedSystemPrompt,
    " < \"", TmpFile, "\""
  ]),

  Result = invoke_with_timeout(FullCmd, Timeout),
  file:delete(TmpFile),
  Result.

invoke_raw_command(Command, UserPrompt, Timeout) ->
  TmpFile = tmp_file(),
  ok = file:write_file(TmpFile, UserPrompt),
  FullCmd = unicode:characters_to_list(
    io_lib:format("~s < \"~s\"", [Command, TmpFile])),
  Result = invoke_with_timeout(FullCmd, Timeout),
  file:delete(TmpFile),
  Result.

invoke_with_timeout(Cmd, Timeout) ->
  Port = open_port({spawn, Cmd}, [stream, exit_status, binary, stderr_to_stdout]),
  collect_port_output(Port, <<>>, Timeout).

collect_port_output(Port, Acc, Timeout) ->
  receive
    {Port, {data, Data}} ->
      collect_port_output(Port, <<Acc/binary, Data/binary>>, Timeout);
    {Port, {exit_status, 0}} ->
      {ok, Acc};
    {Port, {exit_status, Status}} ->
      {error, iolist_to_binary(io_lib:format("command exited with status ~B: ~s",
                                              [Status, string:trim(Acc)]))}
  after Timeout ->
    port_close(Port),
    catch os:cmd("kill -9 " ++ integer_to_list(erlang:port_info(Port, os_pid))),
    {error, timeout}
  end.

shell_escape(Str) ->
  Flat = unicode:characters_to_list(Str),
  "'" ++ escape_single_quotes(Flat) ++ "'".

escape_single_quotes([]) -> [];
escape_single_quotes([$' | Rest]) -> "'\\''" ++ escape_single_quotes(Rest);
escape_single_quotes([C | Rest]) -> [C | escape_single_quotes(Rest)].

tmp_file() ->
  {A, B, C} = erlang:timestamp(),
  Name = io_lib:format("/tmp/situation_~B_~B_~B.txt", [A, B, C]),
  unicode:characters_to_list(Name).

%% ===================================================================
%% Response parsing
%% ===================================================================

parse_code(Code, Meta, E) ->
  Charlist = unicode:characters_to_list(Code),
  try elixir:string_to_quoted(Charlist, 1, 1, <<"situation">>, []) of
    {ok, Quoted} -> Quoted;
    {error, {_, _, Msg}} ->
      file_error(Meta, E, ?MODULE, {hole_parse_error, Msg})
  catch
    _:_ ->
      file_error(Meta, E, ?MODULE, {hole_parse_error, "tokenization failed"})
  end.

%% ===================================================================
%% Error formatting
%% ===================================================================

format_error(situation_not_configured) ->
  "situation blocks require :situation_command compiler option to be set. "
  "Configure via Code.put_compiler_option(:situation_command, \"claude\") "
  "or in mix.exs: [elixirc_options: [situation_command: \"claude\"]]";

format_error({hole_parse_error, Msg}) ->
  io_lib:format("LLM returned code that could not be parsed: ~ts", [Msg]);

format_error({hole_invocation_error, Reason}) ->
  io_lib:format("LLM invocation failed: ~ts", [Reason]);

format_error({hole_invocation_timeout, Timeout}) ->
  io_lib:format("LLM invocation timed out after ~Bms", [Timeout]).
