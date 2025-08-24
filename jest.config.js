/** @type {import('jest').Config} */
export default {
  preset: 'ts-jest',
  testEnvironment: 'jsdom',
  roots: ['<rootDir>/app/javascript'],
  testMatch: [
    '**/__tests__/**/*.+(ts|tsx|js)',
    '**/?(*.)+(spec|test).+(ts|tsx|js)'
  ],
  transform: {
    '^.+\\.(ts|tsx)$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.jest.json', useESM: true, diagnostics: false }],
    '^.+\\.(png|jpg|jpeg|gif|webp|svg)$': '<rootDir>/__mocks__/fileTransformer.cjs'
  },
  moduleNameMapper: {
    '^\\$app/(.*)$': '<rootDir>/app/javascript/$1',
    '^\\$assets/(.*)$': '<rootDir>/app/assets/$1',
    '\\.(css|less|scss|sass)$': 'identity-obj-proxy'
  },
  setupFilesAfterEnv: ['<rootDir>/jest.setup.js'],
  collectCoverageFrom: [
    'app/javascript/**/*.{ts,tsx}',
    '!app/javascript/**/*.d.ts',
    '!app/javascript/**/index.{ts,tsx}',
    '!app/javascript/**/*.stories.{ts,tsx}'
  ],
  coveragePathIgnorePatterns: [
    '/node_modules/',
    '/__tests__/',
    '/test/',
  ],
  testPathIgnorePatterns: [
    '/node_modules/',
    '/build/',
    '/dist/',
  ],
  transformIgnorePatterns: [
    '/node_modules/(?!(ts-safe-cast)/)'
  ],
  moduleDirectories: ['node_modules', 'app/javascript'],
  extensionsToTreatAsEsm: ['.ts', '.tsx'],
};
