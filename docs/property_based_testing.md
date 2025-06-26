# Property-Based Testing in Gumroad

This document describes the property-based tests (PBT) that have been added to the Gumroad codebase using the `prop_check` gem.

## What is Property-Based Testing?

Property-based testing is a testing methodology where instead of writing specific test cases, you define properties that your code should always satisfy. The testing framework then generates many random inputs to verify these properties hold true.

## Benefits

- **Better Coverage**: Tests a wide range of inputs automatically
- **Bug Discovery**: Can find edge cases you might not have thought of
- **Documentation**: Properties serve as executable documentation of behavior
- **Regression Prevention**: Catches changes that violate expected properties

## Added Tests

### 1. TipOptionsService Property Tests

**File**: `spec/services/tip_options_service_property_spec.rb`

Tests the validation methods in `TipOptionsService`:

- `are_tip_options_valid?`: Ensures only arrays of integers are accepted
- `is_default_tip_option_valid?`: Ensures only integers are accepted
- `set_tip_options`: Ensures ArgumentError is raised for invalid inputs
- `set_default_tip_option`: Ensures ArgumentError is raised for invalid inputs

**Key Properties Tested**:
- Arrays of integers are always valid
- Non-arrays are always rejected
- Arrays with non-integer elements are rejected
- Mixed arrays are rejected
- Empty arrays are accepted
- Large integers are handled correctly

### 2. UsernameGeneratorService Property Tests

**File**: `spec/services/username_generator_service_property_spec.rb`

Tests the `ensure_valid_username` method which sanitizes and validates usernames:

**Key Properties Tested**:
- Output is always 3-20 characters long
- Output contains only lowercase alphanumeric characters
- Output always contains at least one letter
- Output never matches DENYLIST entries
- Handles edge cases (empty strings, numbers-only, special characters)
- Converts mixed case to lowercase
- Truncates strings longer than 20 characters
- Pads strings shorter than 3 characters
- Preserves valid characters from input
- Is idempotent for already valid usernames

### 3. JsonValidator Property Tests

**File**: `spec/validators/json_validator_property_spec.rb`

Tests the JSON validation logic with various JSON schemas:

**Key Properties Tested**:
- String schemas accept strings, reject non-strings
- Integer schemas accept integers, reject non-integers
- Number schemas accept numbers, reject non-numbers
- Boolean schemas accept booleans, reject non-booleans
- Array schemas accept arrays with correct item types
- Object schemas accept objects with correct property types
- Enum schemas accept enum values, reject others
- Range constraints (minimum/maximum) work correctly
- Pattern constraints work correctly
- Required properties are enforced

## Running the Tests

### Prerequisites

Before running tests, ensure you have:

1. **Ruby environment set up** (rbenv, rvm, or system Ruby)
2. **MySQL installed** and running
3. **Redis installed** and running
4. **Required system libraries**:
   ```bash
   brew install mysql redis zstd
   ```

### Quick Test Setup

If you're having issues with the full bundle install, you can run the property-based tests in isolation:

```bash
# Install only the essential gems for testing
bundle install --without staging production

# Or install prop_check separately if needed
gem install prop_check

# Run just the property-based tests
bundle exec rspec spec/services/tip_options_service_property_spec.rb
bundle exec rspec spec/services/username_generator_service_property_spec.rb
bundle exec rspec spec/validators/json_validator_property_spec.rb
```

### Full Test Suite

To run all tests including property-based tests:

```bash
# Run all tests
bundle exec rspec

# Run with specific focus
bundle exec rspec --tag property_based

# Run with verbose output
bundle exec rspec --format documentation
```

### Troubleshooting Common Issues

#### 1. MySQL2 Compilation Error
```
ld: library 'zstd' not found
```
**Solution**: Install zstd library
```bash
brew install zstd
```

#### 2. Sidekiq-Pro Authentication Error
```
bad response Unauthorized 401
```
**Solution**: This is expected for external contributors. The property-based tests don't require Sidekiq-Pro.

#### 3. Redis Connection Error
```
Redis::CannotConnectError
```
**Solution**: Start Redis server
```bash
brew services start redis
```

#### 4. MySQL Connection Error
```
Mysql2::Error: Can't connect to MySQL server
```
**Solution**: Start MySQL server
```bash
brew services start mysql
```

## Configuration

The tests use the `prop_check` gem which is configured in the Gemfile:

```ruby
group :test do
  gem 'prop_check'
end
```

## Writing New Property-Based Tests

When writing new property-based tests:

1. **Identify Pure Functions**: Look for methods that don't have side effects and always return the same output for the same input.

2. **Define Properties**: Think about what should always be true about your function's behavior.

3. **Use Generators**: Use `prop_check` generators like:
   - `integer`, `string`, `boolean`, `float`
   - `array_of(generator)`, `hash_of(key_gen, value_gen)`
   - `one_of([generator1, generator2, ...])`
   - `string_of(character(min: 'a', max: 'z'))`

4. **Test Edge Cases**: Make sure your properties handle edge cases like empty arrays, nil values, etc.

5. **Mock External Dependencies**: Use RSpec mocks for external services, databases, etc.

## Example Property Test Structure

```ruby
require 'rails_helper'
require 'prop_check'

RSpec.describe MyService, type: :service do
  include PropCheck::RSpec

  describe 'my_method' do
    property 'always returns expected type' do
      forall do
        # Define input generator
        string
      end.check do |input|
        # Define the property to test
        result = MyService.my_method(input)
        expect(result).to be_a(ExpectedType)
      end
    end
  end
end
```

## Best Practices

1. **Start Simple**: Begin with basic properties and add complexity gradually
2. **Test Invariants**: Focus on properties that should always be true
3. **Use Descriptive Names**: Property names should clearly describe what's being tested
4. **Handle Edge Cases**: Make sure your generators can produce edge cases
5. **Mock Dependencies**: Avoid testing external services in property tests
6. **Keep Tests Fast**: Property tests can be slow, so keep them focused

## Troubleshooting

If tests are failing:

1. **Check Generators**: Make sure your generators produce valid inputs
2. **Verify Properties**: Ensure your properties are actually true for all valid inputs
3. **Check Mocks**: Verify that external dependencies are properly mocked
4. **Review Edge Cases**: Make sure edge cases are handled correctly

## Future Enhancements

Consider adding property-based tests for:

- Data transformation services
- Validation logic
- Mathematical calculations
- String processing functions
- Data serialization/deserialization
- Business rule implementations

## Resources

- [PropCheck Documentation](https://github.com/kinduff/prop_check)
- [Property-Based Testing Best Practices](https://hypothesis.works/articles/what-is-property-based-testing/)
- [QuickCheck Paper](https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quick.pdf)
