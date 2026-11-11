import js from "@eslint/js";
import globals from "globals";

export default [
  { ignores: ["App/Extensions-bundle/**", "deploy/**", "build/**", "dist/**", "node_modules/**"] },
  js.configs.recommended,
  {
    files: ["App/Resources/**/*.js", "Tests/Fixtures/**/*.js"],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: "script",
      globals: { ...globals.browser, chrome: "readonly" },
    },
    rules: {
      "no-unused-vars": ["error", { args: "none", caughtErrors: "none" }],
      "no-empty": ["error", { allowEmptyCatch: true }],
      eqeqeq: ["error", "always", { null: "ignore" }],
      "no-implicit-globals": "error",
    },
  },
  {
    files: ["eslint.config.js"],
    languageOptions: { sourceType: "module", globals: globals.node },
  },
];
