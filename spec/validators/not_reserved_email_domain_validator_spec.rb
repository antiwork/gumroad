# frozen_string_literal: true

require "spec_helper"

RSpec.describe NotReservedEmailDomainValidator do
  let(:model_class) do
    Class.new do
      include ActiveModel::Model
      attr_accessor :email
    end
  end

  let(:model) { model_class.new }

  before { model_class.clear_validators! }

  it "validates the email domain in case-insensitive manner" do
    model_class.validates :email, not_reserved_email_domain: true

    model.email = "user@GumRoad.com"
    expect(model).not_to be_valid

    model.email = "user@GumRoad.org"
    expect(model).not_to be_valid

    model.email = "user@GumRoad.dev"
    expect(model).not_to be_valid

    model.email = "user@gmail.com"
    expect(model).to be_valid
  end

  describe ".domain_reserved?" do
    it "validates the email domain in case-insensitive manner" do
      expect(described_class.domain_reserved?("user@gumroad.com")).to be true
      expect(described_class.domain_reserved?("user@GumRoad.com")).to be true
      expect(described_class.domain_reserved?("user@GumRoad.org")).to be true
      expect(described_class.domain_reserved?("user@GumRoad.dev")).to be true

      expect(described_class.domain_reserved?("user@gmail.com")).to be false
      expect(described_class.domain_reserved?(nil)).to be false
      expect(described_class.domain_reserved?("")).to be false
    end
  end
end
