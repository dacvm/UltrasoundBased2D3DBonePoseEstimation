---
name: readable-implementation
description: Use when implementing a plan or writing new code, to keep the implementation simple, readable, and free of unnecessary defensive complexity. Trigger when the user asks to implement, build, or write code based on an already-agreed plan.
---

Do NOT overcomplicate the process.
Do NOT add excessive "extra safe" error-prevention code — no defensive try/catch, validation, or edge-case handling unless there is a clear, concrete need for it right now.

Prioritize readability over cleverness or robustness. Compensate for any necessary complexity by making the code easier to read, not harder.

Write the code as if it will be handed to a new junior developer who just joined the project:
- Use descriptive, intuitive variable and function names.
- Write clear, step-by-step logic rather than condensed or highly abstracted code.
- Add comments that explain the *reasoning* behind non-obvious decisions, not just what the code does. Multi-line comments are fine when they genuinely help a newcomer understand the "why."

The end goal: code that is easy to read today and easy to extend later, without premature generalization or unnecessary safety nets.
