# frozen_string_literal: true

require "spec_helper"

describe PurchaseReassignmentLock do
  describe "associations" do
    it "belongs to a purchase" do
      lock = build(:purchase_reassignment_lock)
      expect(lock.purchase).to be_present
    end
  end

  describe "validations" do
    it "requires a purchase" do
      lock = build(:purchase_reassignment_lock, purchase: nil)
      expect(lock).not_to be_valid
      expect(lock.errors).to include(:purchase)
    end

    it "allows only one lock per purchase" do
      purchase = create(:free_purchase)
      create(:purchase_reassignment_lock, purchase:)

      duplicate = build(:purchase_reassignment_lock, purchase:)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors).to include(:purchase)
    end
  end
end
