# frozen_string_literal: true

require "spec_helper"

RSpec.describe GlobalConfig do
  describe ".get" do
    context "when the environment variable is set" do
      it "returns the value of the environment variable" do
        allow(ENV).to receive(:fetch).with("TEST_VAR", anything).and_return("test_value")
        expect(described_class.get("TEST_VAR")).to eq("test_value")
      end
    end

    context "when the environment variable is not set" do
      it "returns the default value if provided" do
        allow(ENV).to receive(:fetch).with("MISSING_VAR", anything).and_return("default")
        expect(described_class.get("MISSING_VAR", "default")).to eq("default")
      end

      it "returns nil if no default is provided and no credentials match" do
        allow(ENV).to receive(:fetch).with("MISSING_VAR", nil).and_return(nil)
        expect(described_class.get("MISSING_VAR")).to be_nil
      end

      it "falls back to Rails credentials" do
        allow(ENV).to receive(:fetch).with("CREDENTIAL_KEY", anything) do |name, fallback|
          fallback
        end
        # Mock the private method that accesses Rails credentials
        allow(described_class).to receive(:fetch_from_credentials).with("CREDENTIAL_KEY").and_return("credential_value")
        expect(described_class.get("CREDENTIAL_KEY")).to eq("credential_value")
      end

      it "falls back to Rails credentials for multi-level keys with __ separator" do
        allow(ENV).to receive(:fetch).with("HELLO_WORLD__FOO_BAR", anything) do |name, fallback|
          fallback
        end
        # Mock the private method that accesses Rails credentials
        allow(described_class).to receive(:fetch_from_credentials).with("HELLO_WORLD__FOO_BAR").and_return("123")
        expect(described_class.get("HELLO_WORLD__FOO_BAR")).to eq("123")
      end
    end

    context "when the environment variable is empty or blank" do
      it "returns nil if the environment variable is empty" do
        allow(ENV).to receive(:fetch).with("EMPTY_VAR", anything).and_return("")
        expect(described_class.get("EMPTY_VAR")).to be_nil
      end

      it "returns nil if the environment variable is blank" do
        allow(ENV).to receive(:fetch).with("BLANK_VAR", anything).and_return("   ")
        expect(described_class.get("BLANK_VAR")).to be_nil
      end

      it "doesn't check for blank values when default is provided" do
        allow(ENV).to receive(:fetch).with("BLANK_VAR", anything).and_return("")
        expect(described_class.get("BLANK_VAR", "default")).to eq("")
      end
    end
  end

  describe ".dig" do
    context "when the nested environment variable is set" do
      it "joins the parts with double underscores and returns the value" do
        allow(ENV).to receive(:fetch).with("PART1__PART2__PART3", anything).and_return("nested_value")
        expect(described_class.dig("part1", "part2", "part3")).to eq("nested_value")
      end

      it "converts all parts to uppercase" do
        allow(ENV).to receive(:fetch).with("LOWERCASE__PARTS", anything).and_return("uppercase_result")
        expect(described_class.dig("lowercase", "parts")).to eq("uppercase_result")
      end

      it "handles mixed case parts correctly" do
        allow(ENV).to receive(:fetch).with("MIXED__CASE__PARTS", anything).and_return("result")
        expect(described_class.dig("MiXeD", "cAsE", "PaRtS")).to eq("result")
      end

      it "works with a single part" do
        allow(ENV).to receive(:fetch).with("SINGLE", anything).and_return("value")
        expect(described_class.dig("single")).to eq("value")
      end
    end

    context "when the nested environment variable is not set" do
      it "returns the default value if provided" do
        allow(ENV).to receive(:fetch).with("MISSING__NESTED__VAR", anything).and_return("default")
        expect(described_class.dig("missing", "nested", "var", default: "default")).to eq("default")
      end

      it "returns nil if no default is provided and credentials return nil" do
        allow(ENV).to receive(:fetch).with("MISSING__NESTED__VAR", nil).and_return(nil)
        expect(described_class.dig("missing", "nested", "var")).to be_nil
      end

      it "falls back to Rails credentials for nested keys" do
        allow(ENV).to receive(:fetch).with("PART1__PART2__PART3", anything) do |name, fallback|
          fallback
        end
        # Mock the private method that accesses Rails credentials
        allow(described_class).to receive(:fetch_from_credentials).with("PART1__PART2__PART3").and_return("credential_value")
        expect(described_class.dig("part1", "part2", "part3")).to eq("credential_value")
      end
    end

    context "when the nested environment variable is blank" do
      it "returns nil" do
        allow(ENV).to receive(:fetch).with("NESTED__BLANK__VAR", anything).and_return("  ")
        expect(described_class.dig("nested", "blank", "var")).to be_nil
      end
    end
  end
end
