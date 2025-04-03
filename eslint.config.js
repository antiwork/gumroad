import { includeIgnoreFile } from "@eslint/compat";
import js from "@eslint/js";
import prettierConfig from "eslint-config-prettier";
import importPlugin from "eslint-plugin-import";
import prettierRecommended from "eslint-plugin-prettier/recommended";
import reactRecommended from "eslint-plugin-react/configs/recommended.js";
import globals from "globals";
import { fileURLToPath } from "node:url";
import tseslint from "typescript-eslint";

const baseConfig = {
  plugins: { import: importPlugin },
  languageOptions: {
    ecmaVersion: 2022,
    sourceType: "module",
    globals: {
      ...globals.browser,
      ...globals.jquery,
      Routes: "readonly",
      FB: "readonly",
      process: "readonly",
      SSR: "readonly",
    },
  },
  linterOptions: {
    reportUnusedDisableDirectives: process.env.DISABLE_TYPE_CHECKED ? "off" : "error",
  },
  rules: {
    "arrow-body-style": "error",
    eqeqeq: ["error", "smart"],
    "logical-assignment-operators": "error",
    "no-alert": "error",
    "no-console": "error",
    "no-else-return": "error",
    "no-empty": ["error", { allowEmptyCatch: true }],
    "no-lone-blocks": "error",
    "no-lonely-if": "error",
    "no-var": "error",
    "no-unneeded-ternary": "error",
    "no-useless-call": "error",
    "no-useless-computed-key": "error",
    "no-useless-concat": "error",
    "no-useless-rename": "error",
    "no-useless-return": "error",
    "object-shorthand": "error",
    "operator-assignment": "error",
    "prefer-arrow-callback": "error",
    "prefer-const": "error",
    "prefer-exponentiation-operator": "error",
    "prefer-numeric-literals": "error",
    "prefer-object-spread": "error",
    "prefer-promise-reject-errors": "error",
    "prefer-regex-literals": "error",
    "prefer-spread": "error",
    "prefer-template": "error",
    radix: "error",
    "require-await": "error",
    "require-unicode-regexp": "error",
    yoda: "error",
    "import/no-duplicates": "error",
    "import/order": [
      "error",
      {
        "newlines-between": "always",
        alphabetize: { order: "asc", caseInsensitive: true },
        groups: [["builtin", "external"], "internal", "parent", ["sibling", "index"]],
        pathGroups: [
          { pattern: "$app/vendor/**", group: "external" },
          { pattern: "$vendor/**", group: "external" },
          { pattern: "$app/components/**", group: "internal", position: "after" },
          { pattern: "$app/**", group: "internal" },
        ],
      },
    ],
  },
};

const tsConfig = tseslint.config({
  files: ["**/*.ts", "**/*.tsx"],
  extends: [...tseslint.configs.strictTypeChecked, ...tseslint.configs.stylisticTypeChecked],
  rules: {
    "@typescript-eslint/consistent-type-assertions": ["error", { assertionStyle: "never" }],
    "@typescript-eslint/consistent-type-definitions": "off",
    "@typescript-eslint/no-confusing-void-expression": "off",
    "@typescript-eslint/no-empty-function": "off",
    "@typescript-eslint/no-require-imports": "error",
    "@typescript-eslint/no-unused-vars": [
      "warn",
      {
        args: "all",
        argsIgnorePattern: "^_",
        caughtErrors: "all",
        caughtErrorsIgnorePattern: "^_",
        destructuredArrayIgnorePattern: "^_",
        varsIgnorePattern: "^_",
        ignoreRestSiblings: true,
        reportUsedIgnorePattern: true,
      },
    ],
    "@typescript-eslint/prefer-nullish-coalescing": "off",
    "@typescript-eslint/require-array-sort-compare": ["error", { ignoreStringArrays: true }],
    "@typescript-eslint/restrict-template-expressions": ["error", { allowNumber: true }],
    "@typescript-eslint/switch-exhaustiveness-check": "error",
  },
  languageOptions: {
    parserOptions: {
      project: true,
      tsconfigRootDir: import.meta.dirname,
    },
  },
});

const tsxConfig = tseslint.config({
  files: ["**/*.tsx"],
  extends: [reactRecommended],
  rules: {
    "@typescript-eslint/no-unnecessary-type-constraint": "off", // sometimes required in TSX lest it be parsed as a tag
    "react/iframe-missing-sandbox": "error",
    "react/jsx-no-leaked-render": "error",
    "react/jsx-boolean-value": "error",
    "react/jsx-curly-brace-presence": ["error", { props: "never", children: "never", propElementValues: "always" }],
    "react/jsx-fragments": "error",
    "react/jsx-no-constructed-context-values": "error",
    "react/jsx-no-script-url": "error",
    "react/jsx-no-useless-fragment": "error",
    "react/no-unescaped-entities": "off",
    "react/no-unstable-nested-components": ["error", { allowAsProps: true }],
    "react/prop-types": "off",
  },
  settings: {
    react: {
      version: "detect",
    },
  },
});

const nodeConfig = {
  files: ["config/webpack/*", "eslint.config.js"],
  languageOptions: {
    globals: {
      ...globals.node,
    },
  },
};

export default [
  includeIgnoreFile(fileURLToPath(import.meta.resolve("./.gitignore"))),
  { ignores: ["vendor", "web/**/*"] },
  prettierRecommended,
  js.configs.recommended,
  baseConfig,
  ...tsConfig,
  ...tsxConfig,
  nodeConfig,
  prettierConfig,
  process.env.DISABLE_TYPE_CHECKED ? tseslint.configs.disableTypeChecked : {},
];
