# frozen_string_literal: true

require "test_helper"

class ModulesExternalIdTest < ActiveSupport::TestCase



  context_ "ExternalId" do
    before do
      @purchase = create(:purchase)
    end

  context_ "#find_by_external_id!" do
  test "finds the correct object if it exists" do
        encrypted_id = ObfuscateIds.encrypt(@purchase.id)
        expect(Purchase.find_by_external_id!(encrypted_id).id).to eq @purchase.id
      end

  test "raises an exception if the object does not exist" do
        encrypted_id = ObfuscateIds.encrypt(@purchase.id)
        @purchase.delete
        expect { Purchase.find_by_external_id!(encrypted_id) }.to raise_exception(ActiveRecord::RecordNotFound)
      end
    end

  context_ "#find_by_external_id_numeric!" do
  test "finds the correct object if it exists" do
        expect(Purchase.find_by_external_id_numeric!(@purchase.external_id_numeric).id).to eq @purchase.id
      end

  test "raises an exception if the object does not exist" do
        @purchase.delete
        expect { Purchase.find_by_external_id_numeric!(@purchase.external_id_numeric) }.to raise_exception(ActiveRecord::RecordNotFound)
      end
    end

  context_ "by_external_ids" do
  test "returns array of correct objects" do
        purchase2 = create(:purchase)
        encrypted_id = ObfuscateIds.encrypt(@purchase.id)
        encrypted_id2 = ObfuscateIds.encrypt(purchase2.id)
        expect(Purchase.by_external_ids([encrypted_id, encrypted_id2])).to eq [@purchase, purchase2]
      end
    end
  end
end
