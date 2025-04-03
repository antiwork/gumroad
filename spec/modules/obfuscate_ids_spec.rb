# frozen_string_literal: true

require "spec_helper"

describe "ObfuscateIds" do
  before do
    @purchase = create(:purchase)
  end

  it "decrypts the id correctly" do
    encrypted_id = ObfuscateIds.encrypt(@purchase.id)
    expect(encrypted_id).to_not eq @purchase.id.to_s
    expect(ObfuscateIds.decrypt(encrypted_id)).to eq @purchase.id
  end

  describe "numeric encryption of id" do
    before do
      @purchase = create(:purchase)
    end

    it "decrypts the id correctly" do
      encrypted_id = ObfuscateIds.encrypt_numeric(@purchase.id)
      expect(encrypted_id).to_not eq @purchase.id.to_s
      expect(ObfuscateIds.decrypt_numeric(encrypted_id)).to eq @purchase.id
    end
  end
end
