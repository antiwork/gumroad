# frozen_string_literal: true

require "spec_helper"

describe Subscriptions::MagicLinkPresenter do
  let(:product) { create(:product, name: "Test product name") }
  let(:user) { create(:user, email: "user@email.com") }
  let(:subscription) do
    subscription = create(:subscription, user:, link: product)
    create(:membership_purchase, subscription:, email: "purchase@email.com")
    subscription
  end

  describe "#magic_link_props" do
    it "returns the right props" do
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
