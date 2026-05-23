# frozen_string_literal: true

require "test_helper"

class SubscriptionsMagicLinkPresenterTest < ActiveSupport::TestCase
  self.described_class = Subscriptions::MagicLinkPresenter



  context_ Subscriptions::MagicLinkPresenter do
    let(:product) { create(:product, name: "Test product name") }
    let(:user) { create(:user, email: "user@email.com") }
    let(:subscription) do
      subscription = create(:subscription, user:, link: product)
      create(:membership_purchase, subscription:, email: "purchase@email.com")
      subscription
    end

  context_ "#magic_link_props" do
  test "returns the right props" do
        result = described_class.new(subscription:).magic_link_props

        expect(result).to match({
                                  subscription_id: subscription.external_id,
                                  is_installment_plan: false,
                                  product_name: "Test product name",
                                  user_emails: match_array([
                                                             { email: EmailRedactorService.redact("user@email.com"), source: be_in([:subscription, :user]) },
                                                             { email: EmailRedactorService.redact("purchase@email.com"), source: :purchase },
                                                           ])
                                })
      end
    end
  end
end
