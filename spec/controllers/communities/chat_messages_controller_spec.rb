# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Communities::ChatMessagesController do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let!(:community) { create(:community, resource: product, seller:) }

  include_context "with user signed in as admin for seller"

  before do
    Feature.activate_user(:communities, seller)
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { community }
      let(:policy_method) { :show? }
      let(:request_params) { { community_id: community.external_id, community_chat_message: { content: "Hello" } } }
    end

    it "raises RecordNotFound when community is not found" do
      sign_in seller
      expect do
        post :create, params: { community_id: "nonexistent", community_chat_message: { content: "Hello" } }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "when seller is logged in" do
      before do
        sign_in seller
      end

      it "returns unauthorized response if the :communities feature flag is disabled" do
        Feature.deactivate_user(:communities, seller)

        post :create, params: { community_id: community.external_id, community_chat_message: { content: "Hello" } }

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end

      it "creates a new message" do
        expect do
          post :create, params: {
            community_id: community.external_id,
            community_chat_message: { content: "Hello, community!" }
          }
        end.to change { CommunityChatMessage.count }.by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        message = CommunityChatMessage.last
        expect(message.content).to eq("Hello, community!")
        expect(message.user).to eq(seller)
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
              content: "Hello, community!",
              created_at: kind_of(String),
              updated_at: kind_of(String),
              user: hash_including(
                id: seller.external_id,
                name: seller.display_name,
                is_seller: true,
                avatar_url: seller.avatar_url
              )
            )
          )
        )

        post :create, params: {
          community_id: community.external_id,
          community_chat_message: { content: "Hello, community!" }
        }
      end

      it "redirects with errors when content is invalid" do
        expect do
          post :create, params: {
            community_id: community.external_id,
            community_chat_message: { content: "" }
          }
        end.not_to change { CommunityChatMessage.count }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
      end
    end

    context "when buyer is logged in" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:purchase, purchaser: buyer, link: product) }

      before do
        sign_in buyer
      end

      it "creates a new message" do
        expect do
          post :create, params: {
            community_id: community.external_id,
            community_chat_message: { content: "Hello, community!" }
          }
        end.to change { CommunityChatMessage.count }.by(1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        message = CommunityChatMessage.last
        expect(message.content).to eq("Hello, community!")
        expect(message.user).to eq(buyer)
        expect(message.community).to eq(community)
      end

      it "broadcasts the message to the community channel" do
        expect do
          post :create, params: {
            community_id: community.external_id,
            community_chat_message: { content: "Hello, community!" }
          }
        end.to have_broadcasted_to("community:community_#{community.external_id}").with(
          type: CommunityChannel::CREATE_CHAT_MESSAGE_TYPE,
          message: hash_including(
            community_id: community.external_id,
            id: kind_of(String),
            content: "Hello, community!",
            created_at: kind_of(String),
            updated_at: kind_of(String),
            user: hash_including(
              id: buyer.external_id,
              name: buyer.display_name,
              is_seller: false,
              avatar_url: buyer.avatar_url
            ),
          )
        )
      end

      it "redirects with errors when content is invalid" do
        expect do
          post :create, params: {
            community_id: community.external_id,
            community_chat_message: { content: "" }
          }
        end.not_to change { CommunityChatMessage.count }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(flash[:alert]).to include("Content can't be blank")
        expect(flash[:alert]).to include("Content is too short (minimum is 1 character)")
      end
    end
  end

  describe "PUT update" do
    let!(:message) { create(:community_chat_message, community:, user: seller) }

    context "when seller is logged in" do
      before do
        sign_in seller
      end

      it_behaves_like "authorize called for action", :put, :update do
        let(:record) { message }
        let(:policy_method) { :update? }
        let(:request_params) { { community_id: community.external_id, id: message.external_id, community_chat_message: { content: "Updated" } } }
      end

      it "returns unauthorized response if the :communities feature flag is disabled" do
        Feature.deactivate_user(:communities, seller)

        put :update, params: { community_id: community.external_id, id: message.external_id, community_chat_message: { content: "Updated" } }

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end

      it "raises RecordNotFound when message is not found" do
        expect do
          put :update, params: { community_id: community.external_id, id: "nonexistent", community_chat_message: { content: "Updated" } }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "updates the message" do
        put :update, params: {
          community_id: community.external_id,
          id: message.external_id,
          community_chat_message: { content: "Updated content" }
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
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
              id: seller.external_id,
              name: seller.display_name,
              is_seller: true,
              avatar_url: seller.avatar_url
            )
          )
        )
      end

      it "redirects with errors when content is invalid" do
        expect do
          put :update, params: {
            community_id: community.external_id,
            id: message.external_id,
            community_chat_message: { content: "" }
          }
        end.not_to change { message.reload }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(flash[:alert]).to include("Content can't be blank")
        expect(flash[:alert]).to include("Content is too short (minimum is 1 character)")
      end

      it "does not allow updating other's message" do
        buyer = create(:user)
        create(:purchase, purchaser: buyer, link: product)
        buyer_message = create(:community_chat_message, community:, user: buyer)

        expect do
          put :update, params: {
            community_id: community.external_id,
            id: buyer_message.external_id,
            community_chat_message: { content: "Updated content" }
          }
        end.not_to change { buyer_message.reload }

        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "when buyer is logged in" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:purchase, purchaser: buyer, link: product) }
      let(:message) { create(:community_chat_message, community:, user: buyer) }

      before do
        sign_in buyer
      end

      it "raises RecordNotFound when message is not found" do
        expect do
          put :update, params: { community_id: community.external_id, id: "nonexistent", community_chat_message: { content: "Updated" } }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "updates the message" do
        put :update, params: {
          community_id: community.external_id,
          id: message.external_id,
          community_chat_message: { content: "Updated content" }
        }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(message.reload.content).to eq("Updated content")
      end

      it "broadcasts the update to the community channel" do
        expect(CommunityChannel).to receive(:broadcast_to).with(
          "community_#{community.external_id}",
          hash_including(
            type: CommunityChannel::UPDATE_CHAT_MESSAGE_TYPE,
            message: kind_of(Hash)
          )
        )

        put :update, params: {
          community_id: community.external_id,
          id: message.external_id,
          community_chat_message: { content: "Updated content" }
        }
      end

      it "redirects with errors when content is invalid" do
        expect do
          put :update, params: {
            community_id: community.external_id,
            id: message.external_id,
            community_chat_message: { content: "" }
          }
        end.not_to change { message.reload }

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
      end

      it "does not allow updating other's message" do
        seller_message = create(:community_chat_message, community:, user: seller)

        expect do
          put :update, params: {
            community_id: community.external_id,
            id: seller_message.external_id,
            community_chat_message: { content: "Updated content" }
          }
        end.not_to change { seller_message.reload }

        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end
  end

  describe "DELETE destroy" do
    let!(:message) { create(:community_chat_message, community:, user: seller) }

    context "when seller is logged in" do
      before do
        sign_in seller
      end

      it_behaves_like "authorize called for action", :delete, :destroy do
        let(:record) { message }
        let(:request_params) { { community_id: community.external_id, id: message.external_id } }
      end

      it "returns unauthorized response if the :communities feature flag is disabled" do
        Feature.deactivate_user(:communities, seller)

        delete :destroy, params: { community_id: community.external_id, id: message.external_id }

        expect(response).to redirect_to dashboard_path
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end

      it "raises RecordNotFound when message is not found" do
        expect do
          delete :destroy, params: { community_id: community.external_id, id: "nonexistent" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "destroys the message" do
        expect do
          delete :destroy, params: { community_id: community.external_id, id: message.external_id }
        end.to change { CommunityChatMessage.alive.count }.by(-1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(message.reload).to be_deleted
      end

      it "broadcasts the deletion to the community channel" do
        expect do
          delete :destroy, params: { community_id: community.external_id, id: message.external_id }
        end.to have_broadcasted_to("community:community_#{community.external_id}").with(
          type: CommunityChannel::DELETE_CHAT_MESSAGE_TYPE,
          message: hash_including(
            community_id: community.external_id,
            id: message.external_id
          )
        )
      end

      it "allows deleting member messages" do
        member = create(:user)
        create(:purchase, purchaser: member, link: product)
        message = create(:community_chat_message, community:, user: member)

        expect do
          delete :destroy, params: { community_id: community.external_id, id: message.external_id }
        end.to change { CommunityChatMessage.alive.count }.by(-1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(message.reload).to be_deleted
      end
    end

    context "when buyer is logged in" do
      let(:buyer) { create(:user) }
      let!(:purchase) { create(:purchase, purchaser: buyer, link: product) }
      let(:message) { create(:community_chat_message, community:, user: buyer) }

      before do
        sign_in buyer
      end

      it "destroys the message" do
        expect do
          delete :destroy, params: { community_id: community.external_id, id: message.external_id }
        end.to change { CommunityChatMessage.alive.count }.by(-1)

        expect(response).to redirect_to(community_path(seller.external_id, community.external_id))
        expect(message.reload).to be_deleted
      end

      it "broadcasts the deletion to the community channel" do
        expect(CommunityChannel).to receive(:broadcast_to).with(
          "community_#{community.external_id}",
          hash_including(
            type: CommunityChannel::DELETE_CHAT_MESSAGE_TYPE,
            message: kind_of(Hash)
          )
        )

        delete :destroy, params: { community_id: community.external_id, id: message.external_id }
      end

      it "does not allow deleting another user's message" do
        other_message = create(:community_chat_message, community:, user: seller)

        expect do
          delete :destroy, params: { community_id: community.external_id, id: other_message.external_id }
        end.not_to change { other_message.reload }

        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end
  end
end
