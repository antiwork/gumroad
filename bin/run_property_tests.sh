#!/bin/bash

# Property-Based Testing Runner for Gumroad
# This script helps run property-based tests with minimal setup

set -e

echo "🚀 Property-Based Testing Runner for Gumroad"
echo "=============================================="

# Check if we're in the right directory
if [ ! -f "Gemfile" ]; then
    echo "❌ Error: Please run this script from the Gumroad project root directory"
    exit 1
fi

# Check if required services are running
echo "📋 Checking prerequisites..."

# Check Redis
if ! pgrep -x "redis-server" > /dev/null; then
    echo "⚠️  Redis is not running. Starting Redis..."
    brew services start redis 2>/dev/null || {
        echo "❌ Failed to start Redis. Please install Redis with: brew install redis"
        exit 1
    }
fi

# Check MySQL
if ! pgrep -x "mysqld" > /dev/null; then
    echo "⚠️  MySQL is not running. Starting MySQL..."
    brew services start mysql 2>/dev/null || {
        echo "❌ Failed to start MySQL. Please install MySQL with: brew install mysql"
        exit 1
    }
fi

echo "✅ Prerequisites check complete"

# Try to install prop_check if not available
if ! bundle list | grep -q "prop_check"; then
    echo "📦 Installing prop_check gem..."
    gem install prop_check || {
        echo "⚠️  Could not install prop_check via gem. Trying bundle install..."
        bundle install --without staging production || {
            echo "❌ Failed to install dependencies. Please run 'bundle install' manually"
            exit 1
        }
    }
fi

echo "🧪 Running Property-Based Tests..."
echo ""

# Run each property test file
test_files=(
    "spec/services/tip_options_service_property_spec.rb"
    "spec/services/username_generator_service_property_spec.rb"
    "spec/validators/json_validator_property_spec.rb"
)

for test_file in "${test_files[@]}"; do
    if [ -f "$test_file" ]; then
        echo "Running: $test_file"
        echo "----------------------------------------"
        bundle exec rspec "$test_file" --format documentation || {
            echo "❌ Test failed: $test_file"
            echo "💡 Try running with more verbose output:"
            echo "   bundle exec rspec '$test_file' --format documentation --backtrace"
        }
        echo ""
    else
        echo "⚠️  Test file not found: $test_file"
    fi
done

echo "🎉 Property-based tests completed!"
echo ""
echo "💡 Tips:"
echo "   - Run all tests: bundle exec rspec"
echo "   - Run only property tests: bundle exec rspec --tag property_based"
echo "   - Run with verbose output: bundle exec rspec --format documentation"
echo "   - See documentation: docs/property_based_testing.md"
