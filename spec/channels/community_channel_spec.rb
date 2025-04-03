# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunityChannel do
  let(:user) { create(:user) }
  let(:seller) { create(:user) }
  let(:product) { create(:product, community_chat_enabled: true, user: seller) }
  let!(:community) { create(:community, seller: seller, resource: product) }

  before do
    Feature.activate_user(:communities, seller)
  end

  def subscribe_to_channel
    subscribe(community_id: community.external_id)
  end

  describe "#subscribed" do
    context "when user is not authenticated" do
      before do
        stub_connection current_user: nil
      end

      it "rejects subscription" do
        subscribe_to_channel

        expect(subscription).to be_rejected
      end
    end

    context "when user is authenticated" do
      before do
        stub_connection current_user: user
      end

      context "when community_id is not provided" do
        it "rejects subscription" do
          subscribe community_id: nil

          expect(subscription).to be_rejected
        end
      end

      context "when community is not found" do
        it "rejects subscription" do
          subscribe community_id: "non_existent_id"

          expect(subscription).to be_rejected
        end
      end

      context "when user does not have access to community" do
        it "rejects subscription" do
          subscribe_to_channel

          expect(subscription).to be_rejected
        end
      end

      context "when user has access to community" do
        let!(:purchase) { create(:purchase, link: product, seller:, purchaser: user) }

        it "subscribes to the community channel" do
          subscribe_to_channel

          expect(subscription).to be_confirmed
          expect(subscription).to have_stream_from("community:community_#{community.external_id}")
        end
      end
    end
  end
end
