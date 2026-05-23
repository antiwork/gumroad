# frozen_string_literal: true

require "test_helper"

class LogRedactorTest < ActiveSupport::TestCase
  test "redacts sensitive keys in a hash" do
    input = { "token" => "secret123", "name" => "John" }
    assert_equal({ "token" => "[FILTERED]", "name" => "John" }, LogRedactor.redact(input))
  end

  test "redacts all known sensitive key types" do
    input = {
      "token" => "secret",
      "stripe_publishable_key" => "pk_test_123",
      "authorization" => "Bearer xyz",
      "paypal-auth-assertion" => "assertion123",
      "verify_sign" => "sign456",
      "email" => "user@example.com"
    }
    expected = {
      "token" => "[FILTERED]",
      "stripe_publishable_key" => "[FILTERED]",
      "authorization" => "[FILTERED]",
      "paypal-auth-assertion" => "[FILTERED]",
      "verify_sign" => "[FILTERED]",
      "email" => "user@example.com"
    }
    assert_equal expected, LogRedactor.redact(input)
  end

  test "handles case-insensitive sensitive keys" do
    input = { "TOKEN" => "secret", "Token" => "secret2", "ToKeN" => "secret3" }
    expected = { "TOKEN" => "[FILTERED]", "Token" => "[FILTERED]", "ToKeN" => "[FILTERED]" }
    assert_equal expected, LogRedactor.redact(input)
  end

  test "redacts nested hashes" do
    input = { "user" => { "token" => "secret", "name" => "John" } }
    expected = { "user" => { "token" => "[FILTERED]", "name" => "John" } }
    assert_equal expected, LogRedactor.redact(input)
  end

  test "redacts deeply nested hashes" do
    input = {
      "level1" => {
        "level2" => {
          "token" => "secret",
          "level3" => { "authorization" => "Bearer xyz", "data" => "public" }
        }
      }
    }
    expected = {
      "level1" => {
        "level2" => {
          "token" => "[FILTERED]",
          "level3" => { "authorization" => "[FILTERED]", "data" => "public" }
        }
      }
    }
    assert_equal expected, LogRedactor.redact(input)
  end

  test "handles an empty hash" do
    assert_equal({}, LogRedactor.redact({}))
  end

  test "handles hashes with symbol keys" do
    input = { token: "secret", name: "John" }
    assert_equal({ token: "[FILTERED]", name: "John" }, LogRedactor.redact(input))
  end

  test "redacts hashes within arrays" do
    input = [{ "token" => "secret" }, { "name" => "John" }]
    assert_equal([{ "token" => "[FILTERED]" }, { "name" => "John" }], LogRedactor.redact(input))
  end

  test "handles nested arrays with mixed types" do
    input = ["public", { "token" => "secret" }, [{ "authorization" => "Bearer xyz" }]]
    expected = ["public", { "token" => "[FILTERED]" }, [{ "authorization" => "[FILTERED]" }]]
    assert_equal expected, LogRedactor.redact(input)
  end

  test "preserves non-hash array elements" do
    assert_equal ["string", 123, true, nil], LogRedactor.redact(["string", 123, true, nil])
  end

  test "handles an empty array" do
    assert_equal [], LogRedactor.redact([])
  end

  test "converts OpenStruct to hash and redacts" do
    input = OpenStruct.new(token: "secret", name: "John")
    assert_equal({ token: "[FILTERED]", name: "John" }, LogRedactor.redact(input))
  end

  test "handles nested OpenStruct" do
    input = OpenStruct.new(user: OpenStruct.new(token: "secret", name: "John"))
    assert_equal({ user: { token: "[FILTERED]", name: "John" } }, LogRedactor.redact(input))
  end

  test "handles mixed types at multiple levels" do
    input = {
      "users" => [
        { "name" => "Alice", "token" => "secret1" },
        { "name" => "Bob", "authorization" => "Bearer xyz" }
      ],
      "config" => {
        "stripe_publishable_key" => "pk_test",
        "public_key" => "public123"
      },
      "count" => 42
    }
    expected = {
      "users" => [
        { "name" => "Alice", "token" => "[FILTERED]" },
        { "name" => "Bob", "authorization" => "[FILTERED]" }
      ],
      "config" => {
        "stripe_publishable_key" => "[FILTERED]",
        "public_key" => "public123"
      },
      "count" => 42
    }
    assert_equal expected, LogRedactor.redact(input)
  end

  test "sensitive_key? returns true for exact sensitive key matches" do
    LogRedactor::SENSITIVE_KEYS.each do |key|
      assert LogRedactor.sensitive_key?(key), "Expected #{key.inspect} to be sensitive"
    end
  end

  test "sensitive_key? matches case-insensitively" do
    assert LogRedactor.sensitive_key?("TOKEN")
    assert LogRedactor.sensitive_key?("Token")
    assert LogRedactor.sensitive_key?("AUTHORIZATION")
  end

  test "sensitive_key? handles symbol keys" do
    assert LogRedactor.sensitive_key?(:token)
    assert_not LogRedactor.sensitive_key?(:name)
  end
end
