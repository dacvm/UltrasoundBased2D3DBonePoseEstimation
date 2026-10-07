---
name: readable-refactor
description: Use this skill when the user asks to refactor code, a file, or a function for readability — including phrasing like "clean this up," "make this more readable," "simplify this code," or "refactor for clarity." Applies to any file or function the user has referenced, pasted, or attached. Do NOT use this for refactors aimed at performance, architecture changes, or bug fixes — only pure readability refactors.
---

# Readable Refactor

Apply this approach whenever the user asks to refactor code for readability. The target code is whatever they've referenced, pasted, or attached in their message. If no target is specified or attached, ask the user which file or function to refactor before proceeding.

## Core rule

Do NOT change any behavior, outputs, or logic — this is a pure refactor. Nothing about what the code *does* should change, only how easy it is to read.

## Mindset

Imagine a junior developer, new to this codebase, has to read and understand this code with no one around to ask. Optimize for THEIR comprehension, not for cleverness or brevity.

## What to do

- Improve formatting and structure of the code
- Prefer obvious code over "smart" one-liners, clever chaining, or dense functional tricks — explicit and a few lines longer is better than compressed and hard to parse
- Add comments only where genuinely helpful: explain the "why" behind non-obvious decisions, not the "what" that the code already states

## Constraints

- Preserve exact input/output behavior for every function
- Do not change any algorithm, logic branch, or edge-case handling
- Do not change public interfaces/signatures unless explicitly asked
- If a behavior change would genuinely improve the code, call it out separately — never make it silently as part of the refactor

## Output

After refactoring, briefly explain each change as if walking a junior developer through why the code is now easier to follow. If a test suite exists for the code being refactored, run it before and after the refactor to confirm behavior is unchanged, and mention the result.
