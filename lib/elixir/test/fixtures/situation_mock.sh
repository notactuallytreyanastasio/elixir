#!/bin/bash
# Mock LLM for situation block tests
# Reads prompt from stdin, returns Elixir code based on intent patterns

PROMPT=$(cat)

case "$PROMPT" in
  *"return ok"*)     echo ":ok" ;;
  *"return x"*)      echo "x" ;;
  *"return error"*)  echo "{:error, :failed}" ;;
  *"return tuple"*)  echo "{:ok, :generated}" ;;
  *"add x and y"*)   echo "x + y" ;;
  *"return list"*)   echo "[x, y, z]" ;;
  *"invalid code"*)  echo "def this is not valid ^^^" ;;
  *)                 echo ":generated_default" ;;
esac
