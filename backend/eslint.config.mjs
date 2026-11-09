// @ts-check
import js from '@eslint/js';
import { defineConfig } from 'eslint/config';
import tseslint from 'typescript-eslint';

export default defineConfig(
  { ignores: ['.serverless/', '.esbuild/', 'node_modules/', 'coverage/'] },
  js.configs.recommended,
  tseslint.configs.recommended,
  {
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      // Money is integers. parseFloat or Math.round near money is almost certainly a bug.
      'no-restricted-globals': ['error', { name: 'parseFloat', message: 'Use parseCents() from domain/money.' }],
      'no-restricted-properties': [
        'error',
        { object: 'Number', property: 'parseFloat', message: 'Use parseCents() from domain/money.' },
        { object: 'Math', property: 'round', message: 'Rounding money? Use the largest-remainder split in domain/split.' },
      ],
    },
  },
);
