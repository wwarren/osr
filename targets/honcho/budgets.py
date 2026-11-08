#!/usr/bin/env python3
"""Honcho's token budgets for the model's context window.

Usage: budgets.py PREVIOUS_RECORD RECORD_OUT SETTINGS_OUT

Reads the HONCHO_* budget variables from the environment. A variable that is
set wins; one that is set and empty returns that setting to Honcho's default;
one that is unset keeps the value recorded by the last run (PREVIOUS_RECORD).
HONCHO_CONTEXT_TOKENS derives starting values for the budgets left unset.

Writes RECORD_OUT (the explicit HONCHO_* values, for the next run) and
SETTINGS_OUT (Honcho environment lines that differ from its defaults), and
prints what it set. Exits 2 with a message on an invalid value.
"""
import os
import sys

# HONCHO_<name>: (Honcho setting(s), minimum, maximum, Honcho default).
# Bounds follow Honcho v3.5.0's own validation, raised where a smaller value
# cannot work (the deriver's batch target is 1024 tokens).
INTEGERS = {
    "CONTEXT_TOKENS": ((), 8192, 1_048_576, None),
    "DERIVER_MAX_INPUT_TOKENS": (("DERIVER_MAX_INPUT_TOKENS",), 1024, 25_000, 25_000),
    "DIALECTIC_MAX_INPUT_TOKENS": (("DIALECTIC_MAX_INPUT_TOKENS",), 1024, 200_000, 100_000),
    "DIALECTIC_MAX_OUTPUT_TOKENS": (("DIALECTIC_MAX_OUTPUT_TOKENS",), 256, 100_000, 8192),
    "DIALECTIC_SESSION_HISTORY_MAX_TOKENS": (("DIALECTIC_SESSION_HISTORY_MAX_TOKENS",), 0, 16_384, 4096),
    "SUMMARY_MAX_INPUT_TOKENS": (("SUMMARY_MAX_INPUT_TOKENS",), 1024, 200_000, 100_000),
    "SUMMARY_MAX_TOKENS_SHORT": (("SUMMARY_MAX_TOKENS_SHORT",), 128, 10_000, 1500),
    "SUMMARY_MAX_TOKENS_LONG": (("SUMMARY_MAX_TOKENS_LONG",), 128, 20_000, 6000),
    "LLM_DEFAULT_MAX_TOKENS": (("LLM_DEFAULT_MAX_TOKENS",), 256, 100_000, 2500),
    "LLM_MAX_TOOL_OUTPUT_CHARS": (("LLM_MAX_TOOL_OUTPUT_CHARS",), 500, 100_000, 10_000),
    # Both dream specialists' output caps; Honcho's own default is 8192.
    "DREAM_MAX_OUTPUT_TOKENS": (("DREAM_DEDUCTION_MODEL_CONFIG__MAX_OUTPUT_TOKENS",
                                 "DREAM_INDUCTION_MODEL_CONFIG__MAX_OUTPUT_TOKENS"), 256, 100_000, 8192),
    "DREAM_DEDUCTION_MAX_TOOL_ITERATIONS": (("DREAM_DEDUCTION_MAX_TOOL_ITERATIONS",), 1, 50, 12),
    "DREAM_INDUCTION_MAX_TOOL_ITERATIONS": (("DREAM_INDUCTION_MAX_TOOL_ITERATIONS",), 1, 50, 10),
}
BOOLEANS = {"DREAM_ENABLED": (("DREAM_ENABLED",), "true")}
NAMES = list(INTEGERS) + list(BOOLEANS)


class BudgetError(ValueError):
    pass


def read_record(path):
    record = {}
    try:
        with open(path, encoding="utf-8") as source:
            for line in source:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep and key.startswith("HONCHO_") and key[7:] in NAMES:
                    record[key[7:]] = value
    except FileNotFoundError:
        pass
    return record


def chosen(environ, previous):
    """The explicit values: set wins, set-empty clears, unset keeps the last run's."""
    values = {}
    for name in NAMES:
        key = "HONCHO_" + name
        value = environ[key] if key in environ else previous.get(name, "")
        if value != "":
            values[name] = value.strip()
    return values


def validate(values):
    numbers = {}
    for name, value in values.items():
        if name in BOOLEANS:
            if value not in ("true", "false"):
                raise BudgetError(f"HONCHO_{name} must be true or false, not {value!r}.")
            continue
        _, low, high, _ = INTEGERS[name]
        if not value.isdigit() or not low <= int(value) <= high:
            raise BudgetError(f"HONCHO_{name} must be a whole number from {low} to {high}, not {value!r}.")
        numbers[name] = int(value)
    return numbers


def derived(context):
    """Starting values for a context window of CONTEXT tokens.

    Each call's input budget leaves room for its output and for the system
    prompt and tool definitions (an eighth of the window, at most 4096 tokens).
    Dreams have no input budget in Honcho, so their tool results are capped
    instead, to let about 12 tool rounds fit.
    """
    reserve = min(4096, context // 8)
    dialectic_out = min(8192, context // 8)
    deriver_out = min(2500, context // 8)
    summary_long = min(6000, context // 8)
    return {
        "DIALECTIC_MAX_OUTPUT_TOKENS": dialectic_out,
        "DIALECTIC_MAX_INPUT_TOKENS": min(100_000, context - dialectic_out - reserve),
        "LLM_DEFAULT_MAX_TOKENS": deriver_out,
        "DERIVER_MAX_INPUT_TOKENS": min(25_000, context - deriver_out - reserve),
        "SUMMARY_MAX_TOKENS_LONG": summary_long,
        "SUMMARY_MAX_TOKENS_SHORT": min(1500, context // 16),
        "SUMMARY_MAX_INPUT_TOKENS": min(100_000, context - summary_long - reserve),
        "DREAM_MAX_OUTPUT_TOKENS": min(8192, context // 8),
        "LLM_MAX_TOOL_OUTPUT_CHARS": min(10_000, max(1000, (context * 3 // 4 - reserve) // 6)),
    }


def effective(values):
    """(explicit values, Honcho settings that differ from its defaults)."""
    numbers = validate(values)
    budget = {name: spec[3] for name, spec in INTEGERS.items() if spec[3] is not None}
    if "CONTEXT_TOKENS" in numbers:
        budget.update(derived(numbers["CONTEXT_TOKENS"]))
    budget.update({name: value for name, value in numbers.items() if name != "CONTEXT_TOKENS"})
    largest_summary = max(budget["SUMMARY_MAX_TOKENS_SHORT"], budget["SUMMARY_MAX_TOKENS_LONG"])
    if budget["SUMMARY_MAX_INPUT_TOKENS"] < 2 * largest_summary:
        raise BudgetError("The summary input budget must be at least twice the larger summary cap "
                          f"({budget['SUMMARY_MAX_INPUT_TOKENS']} < 2 x {largest_summary}).")
    settings = {}
    for name, (keys, _, _, default) in INTEGERS.items():
        if name == "CONTEXT_TOKENS" or budget[name] == default:
            continue
        for key in keys:
            settings[key] = str(budget[name])
    for name, (keys, default) in BOOLEANS.items():
        value = values.get(name, default)
        if value != default:
            for key in keys:
                settings[key] = value
    return settings


def main(argv):
    previous_path, record_path, settings_path = argv
    values = chosen(os.environ, read_record(previous_path))
    settings = effective(values)
    with open(record_path, "w", encoding="utf-8") as record:
        record.writelines(f"HONCHO_{name}={values[name]}\n" for name in NAMES if name in values)
    with open(settings_path, "w", encoding="utf-8") as out:
        out.writelines(f"{key}={value}\n" for key, value in settings.items())
    if settings:
        context = values.get("CONTEXT_TOKENS")
        print("Honcho budgets" + (f" for a {context}-token context" if context else "") + ": "
              + ", ".join(f"{key}={value}" for key, value in settings.items()))
    else:
        print("Honcho budgets: Honcho's defaults.")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BudgetError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(2)
