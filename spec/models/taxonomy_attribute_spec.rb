# frozen_string_literal: true

require "spec_helper"

describe TaxonomyAttribute do
  describe "#filter_token_for" do
    it "builds stable filter tokens for enum and boolean attributes" do
      taxonomy = create(:taxonomy)
      format = described_class.create!(taxonomy:, name: "format", label: "Format", value_type: "enum", values: ["OTF", "App embedding"], position: 0)
      variable_font = described_class.create!(taxonomy:, name: "variable_font", label: "Variable font", value_type: "boolean", position: 1)
      styles = described_class.create!(taxonomy:, name: "styles", label: "Styles", value_type: "number", position: 2)

      expect(format.filter_token_for("App embedding")).to eq("format:app_embedding")
      expect(variable_font.filter_token_for(true)).to eq("variable_font:true")
      expect(variable_font.filter_options).to eq(%w[true false])
      expect(variable_font.filter_label_for("true")).to eq("Yes")
      expect(variable_font.filter_label_for("false")).to eq("No")
      expect(styles.filter_token_for(12)).to be_nil
    end
  end

  describe ".valid_filter_tokens" do
    # Tokens are `name:value` and NOT taxonomy-scoped, because that is what is indexed on the
    # product. So these names must be absent from TaxonomyAttributeDefinitions — an attribute
    # retired in one taxonomy stays a valid token while any other taxonomy still defines it.
    it "includes tokens from active attributes/values and excludes retired ones" do
      taxonomy = create(:taxonomy)
      described_class.create!(taxonomy:, name: "spec_only_active", label: "Active", value_type: "enum", values: %w[OTF TTF])
      retired = described_class.create!(taxonomy:, name: "spec_only_retired", label: "Retired", value_type: "enum", values: %w[Commercial], active: false)

      tokens = described_class.valid_filter_tokens

      expect(tokens).to include("spec_only_active:otf", "spec_only_active:ttf")
      expect(tokens).not_to include("spec_only_retired:commercial")
      expect(retired.filter_token_for("Commercial")).to eq("spec_only_retired:commercial")
    end
  end
end
