# frozen_string_literal: true

require "test_helper"

class CommunityChannelTest < ActionCable::Channel::TestCase
  self.described_class = CommunityChannel
  tests CommunityChannel



  context_ CommunityChannel do
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

  context_ "#subscribed" do
  context_ "when user is not authenticated" do
        before do
          stub_connection current_user: nil
        end

  test "rejects subscription" do
          subscribe_to_channel

          expect(subscription).to be_rejected
        end
      end

  context_ "when user is authenticated" do
        before do
          stub_connection current_user: user
        end

  context_ "when community_id is not provided" do
  test "rejects subscription" do
            subscribe community_id: nil

            expect(subscription).to be_rejected
          end
        end

  context_ "when community is not found" do
  test "rejects subscription" do
            subscribe community_id: "non_existent_id"

            expect(subscription).to be_rejected
          end
        end

  context_ "when user does not have access to community" do
  test "rejects subscription" do
            subscribe_to_channel

            expect(subscription).to be_rejected
          end
        end

  context_ "when user has access to community" do
          let!(:purchase) { create(:purchase, link: product, seller:, purchaser: user) }

  test "subscribes to the community channel" do
            subscribe_to_channel

            expect(subscription).to be_confirmed
            expect(subscription).to have_stream_from("community:community_#{community.external_id}")
          end
        end
      end
    end
  end
end
