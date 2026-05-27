# Claude Instructions

## 环境约束

- 我用 VSCode Remote-SSH 连过来，无图形界面，CARLA 必须用 -RenderOffScreen
- conda 环境名固定：lead
- 不要自动启动 CARLA Server，启动命令很重，由我手动控制
- 不要 git commit，所有 commit 由我审核后手动执行
- 大量改动前先在 CLAUDE.md 写计划，等我确认

## 当前目标

1. 搭建 LEAD + CARLA + Scenario Runner 闭环，跑通一个闭环场景
2. 跑通r171相关的一个测试闭环仿真场景 

## Coding Guidelines

Read the relevant doc **before** writing or modifying code in the area it covers:

- [.claude/docs/code_style.md](docs/code_style.md) — typing and docstring conventions. Read when adding or changing Python code in the `lead` package.
- [.claude/docs/coding_rules.md](docs/coding_rules.md) — general rules (imports, error handling, naming). Read when creating any new code in this repo.
- [.claude/docs/project_structure.md](docs/project_structure.md) — directory layout (`lead/`, `3rd_party/`, `scripts/`, `slurm/`). Read when making large architectural changes that touch multiple directories.
- [.claude/docs/cluster.md](docs/cluster.md) — cluster profiles (TCML, MLCloud, bare metal), partitions, time limits, and GPU constraints. Read when generating SLURM scripts.
