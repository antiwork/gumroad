# frozen_string_literal: true

require "test_helper"

class UserChannelTest < ActionCable::Channel::TestCase
  self.described_class = UserChannel
  tests UserChannel



  context_ UserChannel do
    let(:user) { create(:user) }
    let(:seller) { create(:user) }
    let(:product) { create(:product, community_chat_enabled: true, user: seller) }
    let!(:community) { create(:community, seller: seller, resource: product) }

    before do
      Feature.activate_user(:communities, seller)
    end

  context_ "#subscribed" do
  context_ "when user is not authenticated" do
        before do
          stub_connection current_user: nil
        end

  test "rejects subscription" do
          subscribe

          expect(subscription).to be_rejected
        end
      end

  context_ "when user is authenticated" do
        before do
          stub_connection current_user: user
        end

  test "subscribes to the user channel" do
          subscribe

          expect(subscription).to be_confirmed
          expect(subscription).to have_stream_from("user:user_#{user.external_id}")
        end
      end
    end

  context_ "#receive" do
      before do
        stub_connection current_user: user

        subscribe
      end

  context_ "when type is 'latest_community_info'" do
        let(:type) { described_class::LATEST_COMMUNITY_INFO_TYPE }

  context_ "when community_id is not provided" do
  test "rejects the message" do
            perform :receive, { type: }

            expect(subscription).to be_rejected
          end
        end

  context_ "when community is not found" do
  test "rejects the message" do
            perform :receive, { type:, community_id: "non_existent_id" }

            expect(subscription).to be_rejected
          end
        end

  context_ "when user does not have access to community" do
  test "rejects the message" do
            perform :receive, { type:, community_id: community.external_id }

            expect(subscription).to be_rejected
          end
        end

  context_ "when user has access to community" do
          let!(:purchase) { create(:purchase, link: product, seller:, purchaser: user) }

  test "broadcasts community info" do
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

  context_ "when type is unknown" do
  test "does nothing" do
          expect do
            perform :receive, { type: "unknown_type" }
          end.not_to have_broadcasted_to("user:user_#{user.external_id}")

          expect(subscription).to be_confirmed
        end
      end
    end
  end
end
