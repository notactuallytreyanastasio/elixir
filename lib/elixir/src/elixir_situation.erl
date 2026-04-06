%% SPDX-License-Identifier: Apache-2.0
-module(elixir_situation).
-export(['situation'/4, format_error/1]).
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
      %% Gather context and invoke LLM
      Context = gather_context(ELeft, SL, EL),
      Generated = invoke_llm(Intent, Context, CMeta, EL),
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

%% Hole detection

detect_hole({{'.', _, [{'___', _, Kind}]}, _, [Intent]})
    when is_atom(Kind), is_binary(Intent) ->
  {hole, Intent};
detect_hole({'___', _, Kind}) when is_atom(Kind) ->
  {hole, <<>>};
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

%% LLM invocation

invoke_llm(Intent, Context, Meta, E) ->
  case elixir_config:get(situation_command, false) of
    false ->
      file_error(Meta, E, ?MODULE, situation_not_configured);
    Command ->
      Timeout = elixir_config:get(situation_timeout, 30000),
      Prompt = build_prompt(Intent, Context),
      case invoke_command(Command, Prompt, Timeout) of
        {ok, Code} ->
          parse_code(Code, Meta, E);
        {error, timeout} ->
          file_error(Meta, E, ?MODULE, {hole_invocation_timeout, Timeout});
        {error, Reason} ->
          file_error(Meta, E, ?MODULE, {hole_invocation_error, Reason})
      end
  end.

build_prompt(Intent, Context) ->
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
    "You are generating Elixir code for a situation block.\n",
    "Generate ONLY the Elixir expression. No explanation. No markdown fences. No module definition.\n\n",
    "## Context\n",
    "Module: ", atom_to_list(Module), "\n",
    "Function: ", FunStr, "\n",
    "Matched pattern: ", Pattern, "\n\n",
    "## Available imports\n", ImportStr, "\n",
    "## References in this function\n", RefStr, "\n",
    "## Type specs\n", SpecStr, "\n",
    "## Intent\n", Intent, "\n"
  ]).

invoke_command(Command, Prompt, _Timeout) ->
  TmpFile = tmp_file(),
  ok = file:write_file(TmpFile, Prompt),
  FullCmd = unicode:characters_to_list(
    io_lib:format("~s < \"~s\" 2>/dev/null", [Command, TmpFile])),
  try
    Result = os:cmd(FullCmd),
    file:delete(TmpFile),
    {ok, unicode:characters_to_binary(Result)}
  catch
    _:Reason ->
      file:delete(TmpFile),
      {error, Reason}
  end.

tmp_file() ->
  {A, B, C} = erlang:timestamp(),
  Name = io_lib:format("/tmp/situation_~B_~B_~B.txt", [A, B, C]),
  unicode:characters_to_list(Name).

parse_code(Code, Meta, E) ->
  Trimmed = string:trim(Code),
  %% string_to_quoted expects a charlist
  Charlist = unicode:characters_to_list(Trimmed),
  try elixir:string_to_quoted(Charlist, 1, 1, <<"situation">>, []) of
    {ok, Quoted} -> Quoted;
    {error, {_, _, Msg}} ->
      file_error(Meta, E, ?MODULE, {hole_parse_error, Msg})
  catch
    _:_ ->
      file_error(Meta, E, ?MODULE, {hole_parse_error, "tokenization failed"})
  end.

%% Error formatting

format_error(situation_not_configured) ->
  "situation blocks require :situation_command compiler option to be set. "
  "Configure via Code.put_compiler_option(:situation_command, \"your-command\") "
  "or in mix.exs elixirc_options";

format_error({hole_parse_error, Msg}) ->
  io_lib:format("LLM returned code that could not be parsed: ~ts", [Msg]);

format_error({hole_invocation_error, Reason}) ->
  io_lib:format("LLM invocation failed: ~p", [Reason]);

format_error({hole_invocation_timeout, Timeout}) ->
  io_lib:format("LLM invocation timed out after ~Bms", [Timeout]).
