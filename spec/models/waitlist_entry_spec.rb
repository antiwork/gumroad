# frozen_string_literal: true

require "spec_helper"

describe WaitlistEntry do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:follower) { create(:follower, user: seller) }

  it "records one entry per follower and product" do
    create(:waitlist_entry, follower:, product:)

    duplicate = build(:waitlist_entry, follower:, product:)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:product_id]).to be_present
  end

  it "lets one follower join the waitlist of two products" do
    create(:waitlist_entry, follower:, product:)

    expect(build(:waitlist_entry, follower:, product: create(:product, user: seller))).to be_valid
  end
end
