# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::RepairMissingSubscriptionAudienceMembers do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }

  def audience_member_for(purchase)
    AudienceMember.find_by(email: purchase.email, seller_id: seller.id)
  end

  # Puts a subscription into the broken state: still active and contactable, but absent from
  # the seller's audience, so every post and blast skips the buyer.
  def break_audience_row!(purchase)
    audience_member_for(purchase).destroy!
  end

  it "rebuilds the audience row for an active subscription that is missing one" do
    purchase = create(:membership_purchase, link: product, seller:)
    break_audience_row!(purchase)

    expect(described_class.process).to eq(scanned: 1, repaired: 1)

    member = audience_member_for(purchase)
    expect(member.details["purchases"].map { _1["id"] }).to eq([purchase.id])
  end

  it "rebuilds a row that exists but omits the subscription's original purchase" do
    purchase = create(:membership_purchase, link: product, seller:)
    member = audience_member_for(purchase)
    member.update_columns(details: { "follower" => { "id" => 1, "created_at" => 1.day.ago.iso8601 } })

    expect(described_class.process).to eq(scanned: 1, repaired: 1)

    expect(audience_member_for(purchase).details["purchases"].map { _1["id"] }).to eq([purchase.id])
  end

  it "leaves healthy subscriptions alone" do
    create(:membership_purchase, link: product, seller:)

    expect(described_class.process).to eq(scanned: 1, repaired: 0)
  end

  it "skips buyers who are genuinely unsubscribed" do
    purchase = create(:membership_purchase, link: product, seller:)
    purchase.unsubscribe_buyer
    member = audience_member_for(purchase)
    expect(member.deleted_at).to be_present
    expect(AudienceMember.active.where(id: member.id)).to be_empty

    expect(described_class.process).to eq(scanned: 0, repaired: 0)
    expect(member.reload.deleted_at).to be_present
  end

  it "skips deactivated subscriptions" do
    purchase = create(:membership_purchase, link: product, seller:)
    break_audience_row!(purchase)
    purchase.subscription.update!(deactivated_at: Time.current)

    expect(described_class.process).to eq(scanned: 0, repaired: 0)
    expect(audience_member_for(purchase)).to be_nil
  end

  it "reports without writing anything in dry run mode" do
    purchase = create(:membership_purchase, link: product, seller:)
    break_audience_row!(purchase)

    expect(described_class.process(dry_run: true)).to eq(scanned: 1, repaired: 1)
    expect(audience_member_for(purchase)).to be_nil
  end

  it "can be scoped to a single seller" do
    other_seller = create(:user)
    other_purchase = create(:membership_purchase, link: create(:membership_product, user: other_seller), seller: other_seller)
    AudienceMember.find_by(email: other_purchase.email, seller_id: other_seller.id).destroy!
    purchase = create(:membership_purchase, link: product, seller:)
    break_audience_row!(purchase)

    expect(described_class.process(seller_id: seller.id)).to eq(scanned: 1, repaired: 1)

    expect(audience_member_for(purchase)).to be_present
    expect(AudienceMember.find_by(email: other_purchase.email, seller_id: other_seller.id)).to be_nil
  end

  it "is safe to run twice" do
    purchase = create(:membership_purchase, link: product, seller:)
    break_audience_row!(purchase)

    described_class.process
    expect(described_class.process).to eq(scanned: 1, repaired: 0)

    expect(audience_member_for(purchase).details["purchases"].map { _1["id"] }).to eq([purchase.id])
  end
end
