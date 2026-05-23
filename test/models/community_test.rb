# frozen_string_literal: true

require "test_helper"

class CommunityTest < ActiveSupport::TestCase
  self.described_class = Community



  context_ Community do
    subject(:community) { build(:community) }

  context_ "associations" do
      it { is_expected.to belong_to(:seller).class_name("User") }
      it { is_expected.to belong_to(:resource) }
      it { is_expected.to have_many(:community_chat_messages).dependent(:destroy) }
      it { is_expected.to have_many(:last_read_community_chat_messages).dependent(:destroy) }
      it { is_expected.to have_many(:community_chat_recaps).dependent(:destroy) }
    end

  context_ "validations" do
      it { is_expected.to validate_uniqueness_of(:seller_id).scoped_to([:resource_id, :resource_type, :deleted_at]) }
    end

  context_ "#name" do
  test "returns the resource name" do
        community = build(:community, resource: create(:product, name: "Test product"))

        expect(community.name).to eq("Test product")
      end
    end

  context_ "#thumbnail_url" do
  test "returns the resource thumbnail url for email" do
        community = build(:community, resource: create(:product))

        expect(community.thumbnail_url).to eq(ActionController::Base.helpers.image_url("native_types/thumbnails/digital.png"))
      end
    end
  end
end
