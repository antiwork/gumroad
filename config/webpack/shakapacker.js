import fs from "fs";
import yaml from "js-yaml";
import { fileURLToPath } from "node:url";

export default yaml.load(fs.readFileSync(fileURLToPath(import.meta.resolve("../shakapacker.yml"))))[
  process.env.RAILS_ENV
];
