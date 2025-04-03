# frozen_string_literal: true

require "spec_helper"

RSpec.describe Community do
  subject(:community) { build(:community) }

  describe "associations" do
    it { is_expected.to belong_to(:seller).class_name("User") }
    it { is_expected.to belong_to(:resource) }
    it { is_expected.to have_many(:community_chat_messages).dependent(:destroy) }
    it { is_expected.to have_many(:last_read_community_chat_messages).dependent(:destroy) }
    it { is_expected.to have_many(:community_chat_recaps).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_uniqueness_of(:seller_id).scoped_to([:resource_id, :resource_type, :deleted_at]) }
  end

  describe "#name" do
    it "returns the resource name" do
      community = build(:community, resource: create(:product, name: "Test product"))

      expect(community.name).to eq("Test product")
    end
  end

  describe "#thumbnail_url" do
    it "returns the resource thumbnail url for email" do
      community = build(:community, resource: create(:product))

      expect(community.thumbnail_url).to eq(ActionController::Base.helpers.asset_url("native_types/thumbnails/digital.png"))
    end
  end
end
