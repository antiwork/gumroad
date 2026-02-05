# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Communities::ChatMessagesController do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true, price_cents: 0) }
  let!(:community) { create(:community, resource: product, seller: seller) }

  before do
    Feature.activate_user(:communities, seller)
  end

  describe "POST #create" do
    context "when community not found" do
      before do
        sign_in(seller)
      end

      it "returns 404" do
        post :create, params: {
          community_id: "nonexistent",
          community_chat_message: { content: "Hello" }
        }

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when logged in as a user with access" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:free_purchase, seller: seller, purchaser: buyer, link: product) }

      before do
        sign_in(buyer)
      end

      it "creates a chat message" do
        expect do
          post :create, params: {
            community_id: community.external_id,
            community_chat_message: { content: "Hello, world!" }
          }
        end.to change(CommunityChatMessage, :count).by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)

        message = CommunityChatMessage.last
        expect(message.content).to eq("Hello, world!")
        expect(message.user).to eq(buyer)
        expect(message.community).to eq(community)
      end

      it "broadcasts the message to the community channel" do
        expect(CommunityChannel).to receive(:broadcast_to).with(
          "community_#{community.external_id}",
          hash_including(
            type: CommunityChannel::CREATE_CHAT_MESSAGE_TYPE,
            message: hash_including(
              community_id: community.external_id,
              id: kind_of(String),
              content: "Hello, world!",
              created_at: kind_of(String),
              updated_at: kind_of(String),
              user: hash_including(
                id: buyer.external_id,
                name: buyer.display_name,
                is_seller: false,
                avatar_url: buyer.avatar_url
              )
            )
          )
        )

        post :create, params: {
          community_id: community.external_id,
          community_chat_message: { content: "Hello, world!" }
        }
      end

      it "redirects with error for invalid content" do
        post :create, params: {
          community_id: community.external_id,
          community_chat_message: { content: "" }
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
      end
    end
  end

  describe "PUT #update" do
    context "when message not found" do
      before do
        sign_in(seller)
      end

      it "returns 404" do
        put :update, params: {
          community_id: community.external_id,
          id: "nonexistent",
          community_chat_message: { content: "Updated" }
        }

        expect(response).to have_http_status(:not_found)
      end
    end

    let(:buyer) { create(:user) }
    let!(:purchase) { create(:purchase, seller: seller, purchaser: buyer, link: product) }
    let!(:message) { create(:community_chat_message, community: community, user: buyer, content: "Original") }

    context "when logged in as the message author" do
      before do
        sign_in(buyer)
      end

      it "updates the message" do
        put :update, params: {
          community_id: community.external_id,
          id: message.external_id,
          community_chat_message: { content: "Updated content" }
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)
        expect(message.reload.content).to eq("Updated content")
      end

      it "broadcasts the update to the community channel" do
        expect do
          put :update, params: {
            community_id: community.external_id,
            id: message.external_id,
            community_chat_message: { content: "Updated content" }
          }
        end.to have_broadcasted_to("community:community_#{community.external_id}").with(
          type: CommunityChannel::UPDATE_CHAT_MESSAGE_TYPE,
          message: hash_including(
            community_id: community.external_id,
            id: message.external_id,
            content: "Updated content",
            created_at: kind_of(String),
            updated_at: kind_of(String),
            user: hash_including(
              id: buyer.external_id,
              name: buyer.display_name,
              is_seller: false,
              avatar_url: buyer.avatar_url
            )
          )
        )
      end
    end

    context "when logged in as a different user" do
      let(:other_buyer) { create(:user) }
      let!(:other_purchase) { create(:free_purchase, seller: seller, purchaser: other_buyer, link: product) }

      before do
        sign_in(other_buyer)
      end

      it "redirects unauthorized users" do
        put :update, params: {
          community_id: community.external_id,
          id: message.external_id,
          community_chat_message: { content: "Updated content" }
        }

        expect(response).to have_http_status(:redirect)
        expect(message.reload.content).to eq("Original")
      end
    end
  end

  describe "DELETE #destroy" do
    context "when message not found" do
      before do
        sign_in(seller)
      end

      it "returns 404" do
        delete :destroy, params: {
          community_id: community.external_id,
          id: "nonexistent"
        }

        expect(response).to have_http_status(:not_found)
      end
    end

    let(:buyer) { create(:user) }
    let!(:purchase) { create(:purchase, seller: seller, purchaser: buyer, link: product) }
    let!(:message) { create(:community_chat_message, community: community, user: buyer, content: "To be deleted") }

    context "when logged in as the message author" do
      before do
        sign_in(buyer)
      end

      it "soft deletes the message" do
        delete :destroy, params: {
          community_id: community.external_id,
          id: message.external_id
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)
        expect(message.reload).to be_deleted
      end

      it "broadcasts the deletion to the community channel" do
        expect do
          delete :destroy, params: {
            community_id: community.external_id,
            id: message.external_id
          }
        end.to have_broadcasted_to("community:community_#{community.external_id}").with(
          type: CommunityChannel::DELETE_CHAT_MESSAGE_TYPE,
          message: hash_including(
            community_id: community.external_id,
            id: message.external_id
          )
        )
      end
    end

    context "when logged in as the community seller" do
      before do
        sign_in(seller)
      end

      it "allows seller to delete any message" do
        delete :destroy, params: {
          community_id: community.external_id,
          id: message.external_id
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(response).to have_http_status(:see_other)
        expect(message.reload).to be_deleted
      end

      it "broadcasts the deletion to the community channel" do
        expect do
          delete :destroy, params: {
            community_id: community.external_id,
            id: message.external_id
          }
        end.to have_broadcasted_to("community:community_#{community.external_id}").with(
          type: CommunityChannel::DELETE_CHAT_MESSAGE_TYPE,
          message: hash_including(
            community_id: community.external_id,
            id: message.external_id
          )
        )
      end
    end
  end

  describe "POST #mark_read" do
    context "when community not found" do
      before do
        sign_in(seller)
      end

      it "returns 404" do
        post :mark_read, params: {
          community_id: "nonexistent",
          message_id: "nonexistent"
        }

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when message not found" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:purchase, seller: seller, purchaser: buyer, link: product) }

      before do
        sign_in(buyer)
      end

      it "returns 404" do
        post :mark_read, params: {
          community_id: community.external_id,
          message_id: "nonexistent"
        }

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when logged in as a buyer" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:purchase, seller: seller, purchaser: buyer, link: product) }
      let!(:message) { create(:community_chat_message, community: community, user: seller, content: "Read me") }

      before do
        sign_in(buyer)
      end

      it "marks the message as read and redirects" do
        expect do
          post :mark_read, params: {
            community_id: community.external_id,
            message_id: message.external_id
          }
        end.to change(LastReadCommunityChatMessage, :count).by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))

        last_read = LastReadCommunityChatMessage.last
        expect(last_read.user).to eq(buyer)
        expect(last_read.community).to eq(community)
        expect(last_read.community_chat_message).to eq(message)
      end

      it "updates existing last read record when marking a newer message as read" do
        message1 = create(:community_chat_message, community:, user: seller, created_at: 2.minutes.ago)
        message2 = create(:community_chat_message, community:, user: seller, created_at: 1.minute.ago)
        last_read = create(:last_read_community_chat_message, user: buyer, community:, community_chat_message: message1)

        expect do
          post :mark_read, params: {
            community_id: community.external_id,
            message_id: message2.external_id
          }
        end.to change { last_read.reload.community_chat_message }.to(message2)
          .and not_change { LastReadCommunityChatMessage.count }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
      end

      it "does not update last read record when marking an older message as read" do
        message1 = create(:community_chat_message, community:, user: seller, created_at: 2.minutes.ago)
        message2 = create(:community_chat_message, community:, user: seller, created_at: 1.minute.ago)
        last_read = create(:last_read_community_chat_message, user: buyer, community:, community_chat_message: message2)

        expect do
          post :mark_read, params: {
            community_id: community.external_id,
            message_id: message1.external_id
          }
        end.to not_change { last_read.reload.community_chat_message }
          .and not_change { LastReadCommunityChatMessage.count }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
      end
    end

    context "when logged in as the seller" do
      before do
        sign_in(seller)
      end

      it "marks the message as read" do
        message = create(:community_chat_message, community: community, user: seller, content: "Read me")

        expect do
          post :mark_read, params: {
            community_id: community.external_id,
            message_id: message.external_id
          }
        end.to change(LastReadCommunityChatMessage, :count).by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))

        last_read = LastReadCommunityChatMessage.last
        expect(last_read.user).to eq(seller)
        expect(last_read.community).to eq(community)
        expect(last_read.community_chat_message).to eq(message)
      end
    end
  end
end
