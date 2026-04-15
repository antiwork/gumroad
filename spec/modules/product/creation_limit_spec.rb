# frozen_string_literal: true

require "spec_helper"

describe Product::CreationLimit, :enforce_product_creation_limit do
  let(:non_compliant_user) { create(:user, user_risk_state: "not_reviewed") }
  let(:compliant_user) { create(:user, user_risk_state: "compliant") }

  context "for non-compliant users" do
    it "prevents creating more than 10 products in 24 hours" do
      create_products_in_bulk(non_compliant_user, 9)

      product_10 = build(:product, user: non_compliant_user)
      expect(product_10).to be_valid
      product_10.save!

      product_11 = build(:product, user: non_compliant_user)
      expect(product_11).not_to be_valid
      expect(product_11.errors.full_messages).to include("Sorry, you can only create 10 products per day.")

      travel_to 25.hours.from_now

      expect(product_11).to be_valid
    end
  end

  context "for compliant users" do
    it "allows creating up to 100 products in 24 hours" do
      create_products_in_bulk(compliant_user, 99)

      product_100 = build(:product, user: compliant_user)
      expect(product_100).to be_valid
      product_100.save!

      product_101 = build(:product, user: compliant_user)
      expect(product_101).not_to be_valid
      expect(product_101.errors.full_messages).to include("Sorry, you can only create 100 products per day.")

      travel_to 25.hours.from_now

      expect(product_101).to be_valid
    end
  end

  context "when user is a team member" do
    it "skips the daily product creation limit" do
      admin = create(:user, is_team_member: true)
      create_products_in_bulk(admin, 100)

      product_101 = build(:product, user: admin)
      expect(product_101).to be_valid
    end
  end

  context "with custom daily_product_creation_limit" do
    it "uses the user's custom limit when set" do
      user_with_custom_limit = create(:user, user_risk_state: "not_reviewed", daily_product_creation_limit: 5)
      create_products_in_bulk(user_with_custom_limit, 4)

      product_5 = build(:product, user: user_with_custom_limit)
      expect(product_5).to be_valid
      product_5.save!

      product_6 = build(:product, user: user_with_custom_limit)
      expect(product_6).not_to be_valid
      expect(product_6.errors.full_messages).to include("Sorry, you can only create 5 products per day.")
    end

    it "allows increasing the limit beyond the default for compliant users" do
      user_with_higher_limit = create(:user, user_risk_state: "compliant", daily_product_creation_limit: 150)
      create_products_in_bulk(user_with_higher_limit, 100)

      product_101 = build(:product, user: user_with_higher_limit)
      expect(product_101).to be_valid
      product_101.save!

      create_products_in_bulk(user_with_higher_limit, 49)

      product_151 = build(:product, user: user_with_higher_limit)
      expect(product_151).not_to be_valid
      expect(product_151.errors.full_messages).to include("Sorry, you can only create 150 products per day.")
    end

    it "falls back to default limit when custom limit is not set" do
      user_without_custom_limit = create(:user, user_risk_state: "not_reviewed", daily_product_creation_limit: nil)
      create_products_in_bulk(user_without_custom_limit, 10)

      product_11 = build(:product, user: user_without_custom_limit)
      expect(product_11).not_to be_valid
      expect(product_11.errors.full_messages).to include("Sorry, you can only create 10 products per day.")
    end
  end

  describe ".bypass_product_creation_limit" do
    it "bypasses the limit within the block and restores it afterwards" do
      create_products_in_bulk(non_compliant_user, 10)

      Link.bypass_product_creation_limit do
        bypassed_product = build(:product, user: non_compliant_user)
        expect(bypassed_product).to be_valid
      end

      blocked_product = build(:product, user: non_compliant_user)
      expect(blocked_product).not_to be_valid
      expect(blocked_product.errors.full_messages).to include("Sorry, you can only create 10 products per day.")
    end
  end

  private
    def create_products_in_bulk(user, count)
      unique_permalink_chars = ("a".."z").to_a
      rows = Array.new(count) do
        FactoryBot.build(
          :product,
          user: user,
          created_at: Time.current,
          updated_at: Time.current,
          unique_permalink: SecureRandom.alphanumeric(10, chars: unique_permalink_chars),
        ).attributes
      end

      Link.insert_all(rows)
    end
end
