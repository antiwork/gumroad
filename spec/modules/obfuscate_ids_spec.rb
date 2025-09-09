# frozen_string_literal: true

require "spec_helper"

describe "ObfuscateIds" do
  let(:raw_id) { Faker::Number.number(digits: 10) }

  it "decrypts the id correctly" do
    encrypted_id = ObfuscateIds.encrypt(raw_id)
    expect(encrypted_id).to_not eq raw_id.to_s

    encrypted_id_without_padding = ObfuscateIds.encrypt(raw_id, padding: false)
    expect(encrypted_id_without_padding).to_not eq raw_id.to_s

    expect(ObfuscateIds.decrypt(encrypted_id)).to eq raw_id
    expect(ObfuscateIds.decrypt(encrypted_id_without_padding)).to eq raw_id
  end

  describe "numeric encryption of id" do
    # Numeric encryption is limited to binary representations of 30 bits
    # meaning the max value for which we can encrypt is 2^30 - 1 = 1,073,741,823
    let(:raw_id) { rand(1..2**30) }

    it "decrypts the id correctly" do
      encrypted_id = ObfuscateIds.encrypt_numeric(raw_id)
      expect(encrypted_id).to_not eq raw_id.to_s
      expect(ObfuscateIds.decrypt_numeric(encrypted_id)).to eq raw_id
    end

    it "raises an error if the id is greater than the max value" do
      expect { ObfuscateIds.encrypt_numeric(2**30) }.to raise_error(ArgumentError)
    end
  end
end
