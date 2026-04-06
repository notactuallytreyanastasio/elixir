# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Kernel.SituationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @mock_script Path.expand("../../fixtures/situation_mock.sh", __DIR__)

  setup do
    Code.put_compiler_option(:situation_command, @mock_script)
    on_exit(fn -> Code.put_compiler_option(:situation_command, false) end)
  end

  describe "basic situation blocks" do
    test "compiles and returns generated code" do
      {result, _} =
        Code.eval_string("""
        situation :test do
          :test -> ___.("return ok")
        end
        """)

      assert result == :ok
    end

    test "with no holes works like case" do
      {result, _} =
        Code.eval_string("""
        situation :hello do
          :hello -> :world
          _ -> :other
        end
        """)

      assert result == :world
    end

    test "multiple clauses with mixed holes and regular code" do
      {result, _} =
        Code.eval_string("""
        situation {:ok, 42} do
          {:ok, x} -> ___.("return x")
          {:error, _} -> :error_branch
        end
        """)

      assert result == 42
    end

    test "bare ___ hole without intent string" do
      {result, _} =
        Code.eval_string("""
        situation :test do
          :test -> ___
        end
        """)

      assert result == :generated_default
    end
  end

  describe "variable scoping" do
    test "variables in clause patterns available to generated code" do
      {result, _} =
        Code.eval_string("""
        situation {:ok, 42} do
          {:ok, x} -> ___.("return x")
        end
        """)

      assert result == 42
    end

    test "pattern with guards" do
      {result, _} =
        Code.eval_string("""
        situation 5 do
          x when x > 3 -> ___.("return ok")
          _ -> :small
        end
        """)

      assert result == :ok
    end
  end

  describe "error handling" do
    test "___ outside situation block raises compile error" do
      output =
        capture_io(:stderr, fn ->
          assert_raise CompileError, fn ->
            Code.eval_string("___")
          end
        end)

      assert output =~ "hole operator"
      assert output =~ "can only be used inside situation"
    end

    test "___.(intent) outside situation block raises compile error" do
      output =
        capture_io(:stderr, fn ->
          assert_raise CompileError, fn ->
            Code.eval_string(~s[___.("do something")])
          end
        end)

      assert output =~ "hole operator"
      assert output =~ "can only be used inside situation"
    end

    test "___ in pattern position raises compile error" do
      output =
        capture_io(:stderr, fn ->
          assert_raise CompileError, fn ->
            Code.eval_string("""
            situation :test do
              ___ -> :ok
            end
            """)
          end
        end)

      assert output =~ "hole operator"
      assert output =~ "cannot be used in patterns"
    end

    test "situation_command not configured raises error" do
      Code.put_compiler_option(:situation_command, false)

      output =
        capture_io(:stderr, fn ->
          assert_raise CompileError, fn ->
            Code.eval_string("""
            situation :test do
              :test -> ___.("return ok")
            end
            """)
          end
        end)

      assert output =~ "situation_command"
    end

    test "LLM returns unparseable code" do
      output =
        capture_io(:stderr, fn ->
          assert_raise CompileError, fn ->
            Code.eval_string("""
            situation :test do
              :test -> ___.("invalid code")
            end
            """)
          end
        end)

      assert output =~ "could not be parsed"
    end
  end

  describe "compiler options" do
    test "put_compiler_option accepts valid situation_command" do
      assert :ok = Code.put_compiler_option(:situation_command, "echo ok")
      assert :ok = Code.put_compiler_option(:situation_command, false)
    end

    test "put_compiler_option accepts valid situation_timeout" do
      assert :ok = Code.put_compiler_option(:situation_timeout, 60_000)
    end

    test "put_compiler_option rejects invalid situation_timeout" do
      assert_raise RuntimeError, ~r/positive integer/, fn ->
        Code.put_compiler_option(:situation_timeout, -1)
      end
    end

    test "put_compiler_option accepts valid situation_cache" do
      assert :ok = Code.put_compiler_option(:situation_cache, true)
      assert :ok = Code.put_compiler_option(:situation_cache, false)
    end

    test "put_compiler_option accepts valid situation_expert_node" do
      assert :ok = Code.put_compiler_option(:situation_expert_node, :my_node)
      assert :ok = Code.put_compiler_option(:situation_expert_node, false)
    end

    test "put_compiler_option accepts valid situation_model" do
      assert :ok = Code.put_compiler_option(:situation_model, "opus")
      assert :ok = Code.put_compiler_option(:situation_model, "sonnet")
    end

    test "put_compiler_option rejects invalid situation_model" do
      assert_raise RuntimeError, ~r/should be a string/, fn ->
        Code.put_compiler_option(:situation_model, :opus)
      end
    end
  end

  describe "command routing" do
    test "claude command is detected as Claude CLI" do
      assert :elixir_situation.is_claude_cli("claude")
      assert :elixir_situation.is_claude_cli("/usr/local/bin/claude")
      assert :elixir_situation.is_claude_cli("claude --model opus")
      refute :elixir_situation.is_claude_cli(@mock_script)
      refute :elixir_situation.is_claude_cli("echo ok")
    end
  end
end
