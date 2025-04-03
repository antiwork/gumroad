# frozen_string_literal: true

require "spec_helper"

describe "ExternalId" do
  before do
    @purchase = create(:purchase)
  end

  describe "#find_by_external_id!" do
    it "finds the correct object if it exists" do
      encrypted_id = ObfuscateIds.encrypt(@purchase.id)
      expect(Purchase.find_by_external_id!(encrypted_id).id).to eq @purchase.id
    end

    it "raises an exception if the object does not exist" do
      encrypted_id = ObfuscateIds.encrypt(@purchase.id)
      @purchase.delete
      expect { Purchase.find_by_external_id!(encrypted_id) }.to raise_exception(ActiveRecord::RecordNotFound)
    end
  end

  describe "#find_by_external_id_numeric!" do
    it "finds the correct object if it exists" do
      expect(Purchase.find_by_external_id_numeric!(@purchase.external_id_numeric).id).to eq @purchase.id
    end

    it "raises an exception if the object does not exist" do
      @purchase.delete
      expect { Purchase.find_by_external_id_numeric!(@purchase.external_id_numeric) }.to raise_exception(ActiveRecord::RecordNotFound)
    end
  end

  describe "by_external_ids" do
    it "returns array of correct objects" do
      purchase2 = create(:purchase)
      encrypted_id = ObfuscateIds.encrypt(@purchase.id)
      encrypted_id2 = ObfuscateIds.encrypt(purchase2.id)
      expect(Purchase.by_external_ids([encrypted_id, encrypted_id2])).to eq [@purchase, purchase2]
    end
  end
end
