# frozen_string_literal: true

require "test_helper"

class CommunityChatMessagePresenterTest < ActiveSupport::TestCase
  self.described_class = CommunityChatMessagePresenter



  context_ CommunityChatMessagePresenter do
    let(:seller) { create(:named_seller) }
    let(:buyer) { create(:user) }
    let(:community) { create(:community, seller:) }
    let(:message) { create(:community_chat_message, community:, user: buyer) }
    let(:presenter) { described_class.new(message:) }

  context_ "#props" do
      subject(:props) { presenter.props }

  test "returns message data in the expected format" do
        expect(props).to eq({
                              id: message.external_id,
                              community_id: community.external_id,
                              content: message.content,
                              created_at: message.created_at.iso8601,
                              updated_at: message.updated_at.iso8601,
                              user: {
                                id: buyer.external_id,
                                name: buyer.display_name,
                                avatar_url: buyer.avatar_url,
                                is_seller: false
                              }
                            })
      end

  context_ "when message is from the community seller" do
        let(:message) { create(:community_chat_message, community:, user: seller) }

  test "sets is_seller to true" do
          expect(props[:user][:is_seller]).to be(true)
        end
      end
    end
  end
end
