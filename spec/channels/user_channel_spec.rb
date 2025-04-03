# frozen_string_literal: true

require "spec_helper"

RSpec.describe UserChannel do
  let(:user) { create(:user) }
  let(:seller) { create(:user) }
  let(:product) { create(:product, community_chat_enabled: true, user: seller) }
  let!(:community) { create(:community, seller: seller, resource: product) }

  before do
    Feature.activate_user(:communities, seller)
  end

  describe "#subscribed" do
    context "when user is not authenticated" do
      before do
        stub_connection current_user: nil
      end

      it "rejects subscription" do
        subscribe

        expect(subscription).to be_rejected
      end
    end

    context "when user is authenticated" do
      before do
        stub_connection current_user: user
      end

      it "subscribes to the user channel" do
        subscribe

        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_from("user:user_#{user.external_id}")
      end
    end
  end

  describe "#receive" do
    before do
      stub_connection current_user: user

      subscribe
    end

    context "when type is 'latest_community_info'" do
      let(:type) { described_class::LATEST_COMMUNITY_INFO_TYPE }

      context "when community_id is not provided" do
        it "rejects the message" do
          perform :receive, { type: }

          expect(subscription).to be_rejected
        end
      end

      context "when community is not found" do
        it "rejects the message" do
          perform :receive, { type:, community_id: "non_existent_id" }

          expect(subscription).to be_rejected
        end
      end

      context "when user does not have access to community" do
        it "rejects the message" do
          perform :receive, { type:, community_id: community.external_id }

          expect(subscription).to be_rejected
        end
      end

      context "when user has access to community" do
        let!(:purchase) { create(:purchase, link: product, seller:, purchaser: user) }

        it "broadcasts community info" do
          expect do
            perform :receive, { type:, community_id: community.external_id }
          end.to have_broadcasted_to("user:user_#{user.external_id}").with(
            type:,
            data: include(
              id: community.external_id,
              name: community.name,
              thumbnail_url: community.thumbnail_url,
              seller: include(
                id: community.seller.external_id,
                name: community.seller.display_name,
                avatar_url: community.seller.avatar_url
              ),
              last_read_community_chat_message_created_at: nil,
              unread_count: 0
            )
          )

          expect(subscription).to be_confirmed
        end
      end
    end

    context "when type is unknown" do
      it "does nothing" do
        expect do
          perform :receive, { type: "unknown_type" }
        end.not_to have_broadcasted_to("user:user_#{user.external_id}")

        expect(subscription).to be_confirmed
      end
    end
  end
end
