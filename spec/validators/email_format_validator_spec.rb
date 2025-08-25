# frozen_string_literal: true

require "spec_helper"

RSpec.describe EmailFormatValidator do
  let(:model_class) do
    Class.new do
      include ActiveModel::Model
      attr_accessor :email
    end
  end

  let(:model) { model_class.new }

  let(:valid_value) { "user@example.com" }
  let(:invalid_value) { "invalid" }

  before { model_class.clear_validators! }

  it "does not accept blank or nil values by default" do
    model_class.validates :email, email_format: true

    model.email = nil
    expect(model).not_to be_valid

    model.email = ""
    expect(model).not_to be_valid
  end

  it "accepts valid emails" do
    model_class.validates :email, email_format: true

    model.email = valid_value
    expect(model).to be_valid

    model.email = "user@example.com"
    expect(model).to be_valid
  end

  it "accepts nil with allow_nil option" do
    model_class.validates :email, email_format: true, allow_nil: true

    model.email = nil
    expect(model).to be_valid

    model.email = ""
    expect(model).not_to be_valid
  end

  it "accepts blank values with allow_blank option" do
    model_class.validates :email, email_format: true, allow_blank: true

    model.email = ""
    expect(model).to be_valid

    model.email = "   "
    expect(model).to be_valid

    model.email = nil
    expect(model).to be_valid
  end

  describe ".valid?" do
    it "returns true for valid emails" do
      expect(EmailFormatValidator.valid?(valid_value)).to be true
    end

    it "returns false for invalid emails and blank values" do
      expect(EmailFormatValidator.valid?(invalid_value)).to be false
      expect(EmailFormatValidator.valid?(nil)).to be false
      expect(EmailFormatValidator.valid?("")).to be false
    end
  end
end
