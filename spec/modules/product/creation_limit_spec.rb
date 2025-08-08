# frozen_string_literal: true

require "spec_helper"

describe Product::CreationLimit, :enforce_product_creation_limit do
  let(:user) { create(:user) }

  it "allows creating up to 10 products in 24 hours" do
    create_list(:product, 9, user: user)
    new_product = build(:product, user: user)
    expect(new_product).to be_valid
  end

  it "prevents creating more than 10 products in 24 hours" do
    create_list(:product, 10, user: user)

    new_product = build(:product, user: user)

    expect(new_product).not_to be_valid
    expect(new_product.errors.full_messages).to include("Sorry, you can only create 10 products per day.")
  end

  it "allows different users to each create 10 products in 24 hours" do
    user1 = create(:user)
    user2 = create(:user)
    create_list(:product, 10, user: user1)

    new_product = build(:product, user: user2)

    expect(new_product).to be_valid
  end

  it "allows creating products after 24 hours have passed" do
    create_list(:product, 10, user: user, created_at: 25.hours.ago)
    new_product = build(:product, user: user)
    expect(new_product).to be_valid
  end

  context "when user is a team member" do
    it "skips the daily product creation limit" do
      admin = create(:user, is_team_member: true)
      create_list(:product, 10, user: admin)

      new_product = build(:product, user: admin)

      expect(new_product).to be_valid
    end
  end

  describe ".bypass_product_creation_limit" do
    it "bypasses the limit within the block and restores it afterwards" do
      user = create(:user)
      create_list(:product, 10, user: user)

      Link.bypass_product_creation_limit do
        bypassed_product = build(:product, user: user)
        expect(bypassed_product).to be_valid
      end

      blocked_product = build(:product, user: user)
      expect(blocked_product).not_to be_valid
      expect(blocked_product.errors.full_messages).to include("Sorry, you can only create 10 products per day.")
    end
  end
end
