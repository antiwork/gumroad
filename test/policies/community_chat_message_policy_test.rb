# frozen_string_literal: true

require "test_helper"

class CommunityChatMessagePolicyTest < ActiveSupport::TestCase
  self.described_class = CommunityChatMessagePolicy



  context_ CommunityChatMessagePolicy do
    subject { described_class }

    let(:seller) { create(:named_seller) }
    let(:buyer) { create(:user) }
    let(:other_buyer) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let!(:community) { create(:community, seller:, resource: product) }
    let!(:message) { create(:community_chat_message, community:, user: buyer) }

    permissions :update? do
  context_ "when user is the message creator" do
  test "grants access" do
          seller_context = SellerContext.new(user: buyer, seller:)
          expect(subject).to permit(seller_context, message)
        end
      end

  context_ "when user is not the message creator" do
  test "denies access to the community seller" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).not_to permit(seller_context, message)
        end

  test "denies access to other buyer" do
          seller_context = SellerContext.new(user: other_buyer, seller:)
          expect(subject).not_to permit(seller_context, message)
        end
      end
    end

    permissions :destroy? do
  context_ "when user is the message creator" do
  test "grants access" do
          seller_context = SellerContext.new(user: buyer, seller:)
          expect(subject).to permit(seller_context, message)
        end
      end

  context_ "when user is the community seller" do
  test "grants access" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).to permit(seller_context, message)
        end
      end

  context_ "when user is neither the message creator nor the community seller" do
  test "denies access" do
          seller_context = SellerContext.new(user: other_buyer, seller:)
          expect(subject).not_to permit(seller_context, message)
        end
      end
    end
  end
end
