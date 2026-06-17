import js from "@eslint/js";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import tseslint from "typescript-eslint";

export default tseslint.config(
  // Ignore built output
  { ignores: ["dist", "src-tauri"] },

  // Base JS recommended rules
  js.configs.recommended,

  // TypeScript type-aware rules
  ...tseslint.configs.recommendedTypeChecked,

  // Project-level parser config (required for type-aware rules)
  {
    languageOptions: {
      parserOptions: {
        project: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },

  // React-specific rules
  {
    plugins: {
      "react-hooks": reactHooks,
      "react-refresh": reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      // Warn when a component export isn't safe for Fast Refresh
      "react-refresh/only-export-components": ["warn", { allowConstantExport: true }],
    },
  },

  // Project overrides
  {
    rules: {
      // tsc already enforces these; avoid double-reporting
      "@typescript-eslint/no-unused-vars": "off",
      // Allow type assertions where needed (e.g. Tauri invoke generics)
      "@typescript-eslint/consistent-type-assertions": ["error", { assertionStyle: "as" }],
      // Require explicit return types on exported functions
      "@typescript-eslint/explicit-module-boundary-types": "off",
      // Catch floating promises in logic code, but not in JSX event handlers
      // (onClick={asyncFn} is idiomatic React and void there is noise).
      "@typescript-eslint/no-floating-promises": "error",
      "@typescript-eslint/no-misused-promises": [
        "error",
        { checksVoidReturn: { attributes: false } },
      ],
      // Forbid // @ts-ignore; use // @ts-expect-error with a description
      "@typescript-eslint/ban-ts-comment": [
        "error",
        { "ts-ignore": true, "ts-expect-error": "allow-with-description" },
      ],
    },
  },
);
