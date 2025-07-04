import fs from "fs";
import yaml from "js-yaml";
import path from "path";
import { fileURLToPath } from "url";
import { dirname } from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const configPath = path.resolve(__dirname, "../shakapacker.yml");
const config = yaml.load(fs.readFileSync(configPath, "utf8"));

export default config[process.env.RAILS_ENV];
