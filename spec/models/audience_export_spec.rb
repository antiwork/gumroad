# frozen_string_literal: true

require "spec_helper"

describe AudienceExport do
  describe "associations" do
    it { is_expected.to belong_to(:seller).class_name("User") }
    it { is_expected.to belong_to(:recipient).class_name("User") }
    it { is_expected.to have_many(:chunks).class_name("AudienceExportChunk").with_foreign_key(:export_id).dependent(:delete_all) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:audience_options) }
  end

  describe "serialization" do
    it "serializes audience_options as YAML" do
      export = create(:audience_export, audience_options: { followers: true, customers: true })
      export.reload
      expect(export.audience_options).to eq({ followers: true, customers: true })
    end
  end
end
