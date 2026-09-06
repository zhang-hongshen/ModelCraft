---
name: skill-creator
description: Use when a user asks to create, design, revise, or package an Agent Skill for reusable instructions, scripts, references, or assets.
---

# Skill Creator

Create portable skills that follow the open Agent Skills format and are not tied to a particular agent product.

## Location

Use the destination requested by the user. Otherwise create personal skills under `~/.agents/skills/<skill-name>/`.

When updating a skill, inspect its existing files first and preserve resources or metadata that remain relevant.

## Required structure

Every skill is a directory whose name matches its `name` and contains `SKILL.md`:

```text
skill-name/
├── SKILL.md
├── scripts/       optional reusable automation
├── references/    optional details loaded only when needed
└── assets/        optional files used in generated output
```

Do not add empty directories, placeholders, a README, vendor-specific metadata, or supporting files without a concrete purpose.

## Write `SKILL.md`

Start with YAML frontmatter containing:

```yaml
---
name: skill-name
description: Describe what the skill enables and the situations in which it should be used.
---
```

The name must be 1–64 characters using lowercase letters, numbers, and single hyphens. The description must be non-empty, no longer than 1024 characters, and specific enough to distinguish the skill from neighboring capabilities.

In the Markdown body, provide the outcome, non-obvious constraints, decision criteria, and instructions needed to perform the work. Assume the agent is already capable: omit generic advice and explanations that do not change its decisions.

Keep shared guidance in `SKILL.md`. Put substantial conditional details in `references/`, repeatable deterministic operations in `scripts/`, and output templates or media in `assets/`. Link each supporting file from `SKILL.md` where the agent should use it.

Preserve the user's scope and authorization boundaries. A skill may explain when authorization is required, but it must not treat activation as permission to perform unrelated or externally mutating actions.

## Finish

Check that:

- the directory name and frontmatter name match;
- the frontmatter has valid opening and closing delimiters;
- every referenced file exists and uses a path relative to the skill directory;
- the description supports accurate discovery without duplicating the body;
- the skill contains no unfinished placeholders.

Report the created or changed files and any capability the current agent environment cannot validate.
