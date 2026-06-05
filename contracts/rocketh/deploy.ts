import { setupDeployScripts } from "rocketh";
import artifacts from "../script/artifacts.js";
import {
  type Accounts,
  type Data,
  type Extensions,
  extensions,
} from "./config.js";

const { deployScript } = setupDeployScripts<Extensions, Accounts, Data>(
  extensions,
);

export { artifacts, deployScript, deployScript as execute };
