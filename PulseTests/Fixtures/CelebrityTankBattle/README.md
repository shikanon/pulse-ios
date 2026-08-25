# 一句话应用生成 E2E 测试案例

- 唯一用户指令：`生成一个各种名人头像的坦克大战`
- 素材：本目录 4 张头像图片。
- 执行入口：`scripts/run-celebrity-tank-generation-e2e.sh`

该脚本创建仓库外临时沙箱，把素材复制到固定 React + TypeScript + Vite 工作区，调用真实 Coding Agent 生成应用，然后独立执行生成项目声明的测试和生产构建，并检查 4 张图片全部进入产物。模型调用、依赖安装、测试或构建任一步失败都会返回非零状态；不得用 `pulse-api` 的 `deterministic-local` 模拟结果替代。

默认模型为 `gpt-5.4`，可通过 `PULSE_CODING_MODEL` 覆盖。默认自动删除沙箱；需要诊断生成结果时设置 `PULSE_KEEP_GENERATION_SANDBOX=1`。
