# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunitiesPresenter do
  let(:seller) { create(:named_seller) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let!(:community) { create(:community, seller:, resource: product) }
  let(:presenter) { described_class.new(current_user:) }

  describe "#props" do
    let(:current_user) { buyer }
    subject(:props) { presenter.props }

    context "when user has no accessible communities" do
      it "returns appropriate props" do
        expect(props).to eq(
          has_products: false,
          communities: [],
          notification_settings: {},
        )
      end
    end

    context "when user has accessible communities" do
      let(:current_user) { buyer }
      let!(:purchase) { create(:purchase, purchaser: buyer, link: product) }
      let!(:notification_setting) { create(:community_notification_setting, user: buyer, seller:) }

      before do
        Feature.activate_user(:communities, seller)
        product.update!(community_chat_enabled: true)
      end

      it "returns appropriate props" do
        expect(props).to eq(
          has_products: false,
          communities: [
            CommunityPresenter.new(community:, current_user:).props
          ],
          notification_settings: {
            seller.external_id => { recap_frequency: "daily" }
          }
        )
      end

      context "when notification settings are missing" do
        before { notification_setting.destroy! }

        it "returns default notification settings" do
          expect(props[:notification_settings]).to eq({})
        end
      end

      context "when there are unread messages" do
        let!(:message1) { create(:community_chat_message, community:, user: seller, created_at: 3.minutes.ago) }
        let!(:message2) { create(:community_chat_message, community:, user: seller, created_at: 2.minutes.ago) }
        let!(:message3) { create(:community_chat_message, community:, user: seller, created_at: 1.minute.ago) }
        let!(:last_read) do
          create(:last_read_community_chat_message, user: buyer, community:, community_chat_message: message1)
        end

        it "includes unread counts and last read timestamps" do
          community_props = props[:communities].sole
          expect(community_props[:last_read_community_chat_message_created_at]).to eq(message1.created_at.iso8601)
          expect(community_props[:unread_count]).to eq(2)
        end
      end

      context "when there are no last read messages" do
        let!(:message1) { create(:community_chat_message, community:, user: seller, created_at: 3.minutes.ago) }
        let!(:message2) { create(:community_chat_message, community:, user: seller, created_at: 2.minutes.ago) }
        let!(:message3) { create(:community_chat_message, community:, user: seller, created_at: 1.minute.ago) }

        it "returns all messages as unread" do
          community_props = props[:communities].sole
          expect(community_props[:last_read_community_chat_message_created_at]).to be_nil
          expect(community_props[:unread_count]).to eq(3)
        end
      end

      context "when user has multiple communities" do
        let(:other_seller) { create(:user, username: "otherseller123", email: "other_seller@example.com") }
        let(:other_product) { create(:product, user: other_seller, community_chat_enabled: true) }
        let!(:other_community) { create(:community, seller: other_seller, resource: other_product) }
        let!(:other_purchase) { create(:purchase, purchaser: buyer, link: other_product) }
        let!(:other_notification_setting) { create(:community_notification_setting, user: buyer, seller: other_seller) }

        before do
          Feature.activate_user(:communities, other_seller)
          other_product.update!(community_chat_enabled: true)
        end

        it "returns appropriate props" do
          expect(props[:communities].size).to eq(2)
          expect(props[:communities].map { |c| c[:id] }).to match_array([community.external_id, other_community.external_id])
          expect(props[:notification_settings]).to eq({
                                                        seller.external_id => { recap_frequency: "daily" },
                                                        other_seller.external_id => { recap_frequency: "daily" }
                                                      })
        end
      end
    end
  end
end
