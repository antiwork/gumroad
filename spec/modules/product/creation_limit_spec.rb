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
