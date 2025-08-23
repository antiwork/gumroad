# Running Gumroad Tests Without Secrets

This feature allows you to run the Gumroad test suite without requiring real API keys or external service credentials.

## Overview

The test suite now includes a `TestSecretsManager` that provides mock credentials for all external services, allowing tests to run in isolated environments without the need for:

- Real Stripe API keys
- AWS credentials
- PayPal credentials
- External API keys (SendGrid, Dropbox, etc.)
- System dependencies

## Usage

### Default Behavior (Mock Secrets)

By default, the test suite will use mock secrets:

```bash
bundle exec rspec
```

### Using Real Secrets

If you need to test with real credentials (e.g., for integration testing), set the environment variable:

```bash
USE_REAL_SECRETS=true bundle exec rspec
```

## What's Mocked

### Services
- **Stripe**: Balance checks, payment intents, charges
- **AWS**: S3 operations, MediaConvert, other AWS services
- **PayPal**: OAuth, API calls, sandbox operations
- **Braintree**: Configuration and API calls
- **External APIs**: SendGrid, Dropbox, EasyPost, TaxJar, VATStack, etc.

### Credentials
All external service credentials are replaced with safe mock values that won't make real API calls.

### Balance Enforcement
The `StripeBalanceEnforcer` is automatically disabled when using mock secrets, eliminating the need for a real Stripe account with sufficient balance.

## Implementation Details

### TestSecretsManager
- Provides mock credentials for all external services
- Patches `GlobalConfig.get()` to return mock values
- Can be enabled/disabled as needed

### ServiceMockManager
- Handles WebMock stubs for external API calls
- Provides realistic mock responses
- Covers all major external services used in tests

### VCR Integration
- Automatically uses mock credentials in VCR cassettes
- Maintains compatibility with existing VCR setup
- Switches between real and mock credentials based on environment

## Benefits

1. **No Setup Required**: Tests run immediately without credential configuration
2. **CI/CD Friendly**: No secrets needed in CI environments
3. **Faster Tests**: No real API calls, reduced flakiness
4. **Secure**: No risk of accidentally using real credentials in tests
5. **Isolated**: Tests don't depend on external service availability

## Backward Compatibility

This change is fully backward compatible. Existing test behavior is preserved when `USE_REAL_SECRETS=true` is set.

## Related Files

- `spec/support/test_secrets_manager.rb` - Mock credentials provider
- `spec/support/service_mock_manager.rb` - External service mocks
- `spec/spec_helper.rb` - Integration and configuration
