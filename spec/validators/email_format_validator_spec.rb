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

  # An address carrying a character the person cannot see reads as a perfectly ordinary address
  # to the format regex, because the local part of an address may contain almost anything. It is
  # not a usable address: the mail provider rejects it, so every message we send bounces while
  # the address looks correctly spelled to the person who typed it and to us.
  describe "invisible characters" do
    before { model_class.validates :email, email_format: true }

    it "rejects an address carrying a bidirectional mark" do
      expect(EmailFormatValidator.valid?("\u200Fbuyer@example.com")).to be false
      expect(EmailFormatValidator.valid?("buyer\u200E@example.com")).to be false
    end

    it "rejects an address carrying any of the other invisible characters" do
      ["buyer\u200Bx@example.com", "buyer\u2060x@example.com", "\uFEFFbuyer@example.com",
       "buyer\u00ADx@example.com", "buyer\u00A0@example.com", "bu\u3000yer@example.com"].each do |email|
        expect(EmailFormatValidator.valid?(email)).to be(false), "expected #{email.inspect} to be rejected"
      end
    end

    it "still accepts an ordinary address" do
      expect(EmailFormatValidator.valid?("buyer@example.com")).to be true
    end

    it "explains that the address contains a hidden character rather than just calling it invalid" do
      model.email = "\u200Fbuyer@example.com"

      expect(model).not_to be_valid
      expect(model.errors[:email]).to eq [EmailFormatValidator::INVISIBLE_CHARACTER_MESSAGE]
    end

    # A value that is broken in more ways than the invisible character keeps the caller's own
    # message, so we do not tell someone their address contains a hidden character when the real
    # problem is that it is not an address at all. (An explicit message is passed here because
    # the default :invalid symbol needs an i18n lookup, which the anonymous test class has no
    # name for.)
    it "falls back to the caller's message when the address is malformed for other reasons too" do
      model_class.clear_validators!
      model_class.validates :email, email_format: { message: "is invalid" }
      model.email = "\u200Fnot-an-address"

      expect(model).not_to be_valid
      expect(model.errors[:email]).to eq ["is invalid"]
    end

    it "does not reject the zero-width joiner or non-joiner, which carry meaning rather than formatting" do
      expect(EmailFormatValidator.valid?("mi\u200Cravam@example.com")).to be true
      expect(EmailFormatValidator.valid?("a\u200Db@example.com")).to be true
    end
  end
end
