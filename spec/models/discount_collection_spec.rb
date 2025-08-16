# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscountCollection, type: :model do
  let(:user) { create(:user) }
  let(:discount_collection) { build(:discount_collection, user: user) }

  describe "validations" do
    it "is valid with valid attributes" do
      expect(discount_collection).to be_valid
    end

    it "requires a name" do
      discount_collection.name = nil
      expect(discount_collection).not_to be_valid
      expect(discount_collection.errors[:name]).to include("can't be blank")
    end

    it "limits name length to 255 characters" do
      discount_collection.name = "a" * 256
      expect(discount_collection).not_to be_valid
      expect(discount_collection.errors[:name]).to include("is too long (maximum is 255 characters)")
    end

    it "limits description length to 1000 characters" do
      discount_collection.description = "a" * 1001
      expect(discount_collection).not_to be_valid
      expect(discount_collection.errors[:description]).to include("is too long (maximum is 1000 characters)")
    end
  end

  describe "associations" do
    it "belongs to a user" do
      expect(discount_collection).to belong_to(:user)
    end

    it "has many offer codes" do
      expect(discount_collection).to have_many(:offer_codes).dependent(:nullify)
    end
  end

  describe "scopes" do
    it "includes alive scope" do
      expect(DiscountCollection).to respond_to(:alive)
    end
  end

  describe "methods" do
    let(:collection) { create(:discount_collection, user: user) }
    let!(:offer_code1) { create(:offer_code, user: user, discount_collection: collection) }
    let!(:offer_code2) { create(:offer_code, user: user, discount_collection: collection) }
    let!(:deleted_offer_code) { create(:offer_code, user: user, discount_collection: collection, deleted_at: Time.current) }

    it "counts offer codes correctly" do
      expect(collection.offer_codes_count).to eq(2)
    end

    it "calculates total uses correctly" do
      create(:purchase, offer_code: offer_code1, quantity: 3)
      create(:purchase, offer_code: offer_code2, quantity: 2)

      expect(collection.total_uses).to eq(5)
    end

    it "calculates total revenue correctly" do
      create(:purchase, offer_code: offer_code1, price_cents: 1000)
      create(:purchase, offer_code: offer_code2, price_cents: 2000)

      expect(collection.total_revenue_cents).to eq(3000)
    end
  end
end
