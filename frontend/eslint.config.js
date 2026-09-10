// Flat config (ESLint v9+). frontend/package.json has "type": "module".
//
// The eslint-plugin-oxlint import below was MISSING in the previous delivery
// while the spreads at the bottom referenced it, producing
// "ReferenceError: oxlint is not defined" and correctly halting the canary
// gate. scripts/artifact_gate.sh now catches that class before it reaches disk.
import js from '@eslint/js';
import globals from 'globals';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';
import oxlint from 'eslint-plugin-oxlint';

export default [
  { ignores: ['dist/**', 'node_modules/**'] },
  js.configs.recommended,
  {
    files: ['**/*.{js,jsx}'],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: 'module',
      globals: globals.browser,
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'warn',
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],
    },
  },
  // Dedup layer: each spread switches off the eslint rules oxlint already
  // reports, so no defect is printed twice.
  //
  // 'flat/react' is DELIBERATELY EXCLUDED. Including it silences
  // react-refresh/only-export-components, which oxlint has no equivalent for
  // and which is eslint's only unique contribution here. Measured: with
  // flat/react included eslint reported 0 findings on a fixture that has two;
  // with it excluded eslint reports exactly those two.
  ...oxlint.configs['flat/recommended'],
  ...oxlint.configs['flat/react-hooks'],
  ...oxlint.configs['flat/jsx-a11y'],
  ...oxlint.configs['flat/import'],
  ...oxlint.configs['flat/unicorn'],
];
