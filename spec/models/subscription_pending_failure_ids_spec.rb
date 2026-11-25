# frozen_string_literal: true

require "spec_helper"

describe Subscription, ".pending_failure_ids_for" do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }
  let(:buyer) { create(:user) }

  def membership
    create(:membership_purchase, link: product, seller:, purchaser: buyer).subscription
  end

  def renewal(subscription, state)
    create(:membership_purchase, link: product, seller:, subscription:, purchaser: buyer, is_original_subscription_purchase: false, purchase_state: state)
  end

  it "includes a live membership whose newest purchase failed" do
    failing = membership
    travel(1.minute) { renewal(failing, "failed") }

    expect(described_class.pending_failure_ids_for(seller)).to eq([failing.id])
  end

  it "excludes a membership whose failed renewal was followed by a successful one" do
    recovered = membership
    travel(1.minute) { renewal(recovered, "failed") }
    travel(2.minutes) { renewal(recovered, "successful") }

    expect(described_class.pending_failure_ids_for(seller)).to be_empty
  end

  it "excludes a membership that already ran out of retries" do
    ended = membership
    travel(1.minute) { renewal(ended, "failed") }
    ended.update!(failed_at: 1.minute.ago, deactivated_at: 1.minute.ago)

    expect(described_class.pending_failure_ids_for(seller)).to be_empty
  end

  it "excludes healthy memberships and other sellers' memberships" do
    membership
    other_product = create(:membership_product)
    other = create(:membership_purchase, link: other_product, seller: other_product.user).subscription
    travel(1.minute) { create(:membership_purchase, link: other_product, seller: other_product.user, subscription: other, is_original_subscription_purchase: false, purchase_state: "failed") }

    expect(described_class.pending_failure_ids_for(seller)).to be_empty
  end
end
