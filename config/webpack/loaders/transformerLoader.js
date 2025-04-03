import path from "path";
import ts from "typescript";

let service = undefined;
let versions = new Map();

export default function (source) {
  this.cacheable();
  if (!service) {
    const configPath = this.query.tsconfigPath ?? ts.findConfigFile(process.cwd(), ts.sys.fileExists, "tsconfig.json");
    const configFile = ts.readConfigFile(configPath, ts.sys.readFile);
    const tsConfigFile = ts.parseJsonConfigFileContent(configFile.config, ts.sys, path.dirname(configPath));
    service = ts.createLanguageService({
      getScriptFileNames: () => tsConfigFile.fileNames,
      getScriptVersion: (fileName) => (versions.get(fileName)?.safeTime ?? 1).toString(),
      getScriptSnapshot: (fileName) => ts.ScriptSnapshot.fromString(ts.sys.readFile(fileName)),
      getCompilationSettings: () => tsConfigFile.options,
      // There is also a `ts.getDefaultLibFileName` function, but this wants `getDefaultLibFilePath`.
      getDefaultLibFileName: ts.getDefaultLibFilePath,
      getCurrentDirectory: ts.sys.getCurrentDirectory,
      readFile: ts.sys.readFile,
      realpath: ts.sys.realpath,
      fileExists: ts.sys.fileExists,
    });
  }
  if (this._compiler.fileTimestamps) versions = this._compiler.fileTimestamps;
  if (!this._compilation.__transformerProgram) {
    this._compilation.__transformerProgram = service.getProgram();
  }
  const program = this._compilation.__transformerProgram;
  const sourceFile = program.getSourceFile(this.resourcePath);
  if (!sourceFile) return source;
  const transformers = this.query.getTransformers(program);
  return ts.createPrinter().printFile(ts.transform(sourceFile, transformers).transformed[0]);
}
