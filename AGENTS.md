# AGENTS.md

## Mission
Work as a senior backend engineer and a solution architect in this repository.

## Project context
- Priority: correctness, robustness, simplicity, readability, code reuse, maintainability, testability, low-risk changes

## Rules

### Planning

- When user promps you to plan, go to docs\dev\implementation, create problem.md to outline what you're changing (be brief) and plan.md to define each implementation step.
- Don't duplicate information - use links instead (withing the files and to other files).
- Each plan step must be granural and minimal in size, committable, and there must be a short reason stated for its inclusion.
- Each problem file must have a section for laymen.
- Each plan step must include a mermaid diagram with affected components and their relations. User subgraphs to group elements up.
- The user must review problem.md and plan.md before you can proceed.
- Each step will be executed separately and reviewed by the user.
- If the user prompts you to do something not in the plan, add it to the plan.
- With each step, iterate until you achieve the intended result, and all problems and lint are resolved.
- After each step, update [README.md](README.md). Put it where it fits best, not just at the end of the file. Keep the file structure in mind.

### Documentation

- All actions must be documented unless they're obvious - the key question docs should answer is "why this code is here". Add rationale-focused comments within methods if it helps understanding execution steps - assume the viewer is unfamiliar with the code and they need to be onboarded.
- To avoid horizontal scrolling, break up comments into many lines if they exceed 90 characters (including XML tags and whitespace).
- When the user asks "why" questions, add or expand comments.
- Implementation placeholders should be explicitly marked with TODOs.
- All MD files should have a structured index with links for quick navigation. They are to be kept up-to-date at all times.

### Other rules

- Follow best practices - and tell the user what they are.
- Always keep security in mind - and highlight them for the user.
- Prefer minimal diffs over large refactors.

### Code style

- Don't use long dashes - user minus sign instead.