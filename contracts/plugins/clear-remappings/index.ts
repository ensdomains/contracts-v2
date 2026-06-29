import { overrideTask } from "hardhat/config";
import type { HardhatPlugin } from "hardhat/types/plugins";

const plugin: HardhatPlugin = {
  id: "hardhat-clear-remappings",
  tasks: ["build", "compile"].map((action) =>
    overrideTask(action)
      .setAction(() => import("./task.ts"))
      .build(),
  ),
};

export default plugin;
