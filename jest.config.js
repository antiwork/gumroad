module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'jsdom',
  setupFilesAfterEnv: ['<rootDir>/jest.setup.js'],
  moduleNameMapping: {
    '^\\$app/(.*)$': '<rootDir>/app/javascript/$1',
    '^\\$assets/(.*)$': '<rootDir>/app/assets/$1',
    '\\.(css|less|scss|sass)$': 'identity-obj-proxy',
    '\\.(jpg|jpeg|png|gif|eot|otf|webp|svg|ttf|woff|woff2|mp4|webm|wav|mp3|m4a|aac|oga)$':
      '<rootDir>/__mocks__/fileMock.js',
  },
  testMatch: [
    '<rootDir>/spec/javascript/**/*.test.{ts,tsx}',
    '<rootDir>/app/javascript/**/*.test.{ts,tsx}',
  ],
  collectCoverageFrom: [
    'app/javascript/**/*.{ts,tsx}',
    '!app/javascript/**/*.d.ts',
    '!app/javascript/**/*.stories.{ts,tsx}',
  ],
  transform: {
    '^.+\\.(ts|tsx)$': 'ts-jest',
  },
  globals: {
    'ts-jest': {
      tsconfig: 'tsconfig.json',
    },
  },
  testEnvironmentOptions: {
    customExportConditions: [''],
  },
};
