# frozen_string_literal: true

require "spec_helper"

RSpec.describe LogRedactor do
  describe ".redact" do
    context "with Hash" do
      it "redacts sensitive keys" do
        input = { "token" => "secret123", "name" => "John" }
        result = LogRedactor.redact(input)
        expect(result).to eq({ "token" => "[FILTERED]", "name" => "John" })
      end

      it "redacts all sensitive key types" do
        input = {
          "token" => "secret",
          "stripe_publishable_key" => "pk_test_123",
          "authorization" => "Bearer xyz",
          "paypal-auth-assertion" => "assertion123",
          "verify_sign" => "sign456",
          "email" => "user@example.com"
        }
        result = LogRedactor.redact(input)
        expect(result).to eq({
                               "token" => "[FILTERED]",
                               "stripe_publishable_key" => "[FILTERED]",
                               "authorization" => "[FILTERED]",
                               "paypal-auth-assertion" => "[FILTERED]",
                               "verify_sign" => "[FILTERED]",
                               "email" => "user@example.com"
                             })
      end

      it "handles case-insensitive sensitive keys" do
        input = { "TOKEN" => "secret", "Token" => "secret2", "ToKeN" => "secret3" }
        result = LogRedactor.redact(input)
        expect(result).to eq({ "TOKEN" => "[FILTERED]", "Token" => "[FILTERED]", "ToKeN" => "[FILTERED]" })
      end

      it "redacts nested hashes" do
        input = { "user" => { "token" => "secret", "name" => "John" } }
        result = LogRedactor.redact(input)
        expect(result).to eq({ "user" => { "token" => "[FILTERED]", "name" => "John" } })
      end

      it "redacts deeply nested hashes" do
        input = {
          "level1" => {
            "level2" => {
              "token" => "secret",
              "level3" => { "authorization" => "Bearer xyz", "data" => "public" }
            }
          }
        }
        result = LogRedactor.redact(input)
        expect(result).to eq({
                               "level1" => {
                                 "level2" => {
                                   "token" => "[FILTERED]",
                                   "level3" => { "authorization" => "[FILTERED]", "data" => "public" }
                                 }
                               }
                             })
      end

      it "handles empty hash" do
        expect(LogRedactor.redact({})).to eq({})
      end

      it "handles hash with symbol keys" do
        input = { token: "secret", name: "John" }
        result = LogRedactor.redact(input)
        expect(result).to eq({ token: "[FILTERED]", name: "John" })
      end
    end

    context "with Array" do
      it "redacts hashes within arrays" do
        input = [{ "token" => "secret" }, { "name" => "John" }]
        result = LogRedactor.redact(input)
        expect(result).to eq([{ "token" => "[FILTERED]" }, { "name" => "John" }])
      end

      it "handles nested arrays with mixed types" do
        input = ["public", { "token" => "secret" }, [{ "authorization" => "Bearer xyz" }]]
        result = LogRedactor.redact(input)
        expect(result).to eq(["public", { "token" => "[FILTERED]" }, [{ "authorization" => "[FILTERED]" }]])
      end

      it "preserves non-hash array elements" do
        input = ["string", 123, true, nil]
        result = LogRedactor.redact(input)
        expect(result).to eq(["string", 123, true, nil])
      end

      it "handles empty array" do
        expect(LogRedactor.redact([])).to eq([])
      end
    end

    context "with OpenStruct" do
      it "converts to hash and redacts" do
        input = OpenStruct.new(token: "secret", name: "John")
        result = LogRedactor.redact(input)
        expect(result).to eq({ token: "[FILTERED]", name: "John" })
      end

      it "handles nested OpenStruct" do
        input = OpenStruct.new(user: OpenStruct.new(token: "secret", name: "John"))
        result = LogRedactor.redact(input)
        expect(result).to eq({ user: { token: "[FILTERED]", name: "John" } })
      end
    end

    context "with complex nested structures" do
      it "handles mixed types at multiple levels" do
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
        result = LogRedactor.redact(input)
        expect(result).to eq({
                               "users" => [
                                 { "name" => "Alice", "token" => "[FILTERED]" },
                                 { "name" => "Bob", "authorization" => "[FILTERED]" }
                               ],
                               "config" => {
                                 "stripe_publishable_key" => "[FILTERED]",
                                 "public_key" => "public123"
                               },
                               "count" => 42
                             })
      end
    end
  end

  describe ".sensitive_key?" do
    it "returns true for exact sensitive key matches" do
      LogRedactor::SENSITIVE_KEYS.each do |key|
        expect(LogRedactor.sensitive_key?(key)).to be true
      end
    end

    it "returns true for case-insensitive matches" do
      expect(LogRedactor.sensitive_key?("TOKEN")).to be true
      expect(LogRedactor.sensitive_key?("Token")).to be true
      expect(LogRedactor.sensitive_key?("AUTHORIZATION")).to be true
    end

    it "handles symbol keys" do
      expect(LogRedactor.sensitive_key?(:token)).to be true
      expect(LogRedactor.sensitive_key?(:name)).to be false
    end
  end
end
