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
      expect(styles.filter_token_for(12)).to be_nil
    end
  end
end
