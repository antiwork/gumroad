# frozen_string_literal: true

require "spec_helper"

RSpec.describe IsbnValidator do
  let(:model_class) do
    Class.new do
      include ActiveModel::Model
      attr_accessor :isbn
    end
  end

  let(:model) { model_class.new }

  before { model_class.clear_validators! }

  context "when ISBN-13" do
    let(:valid_value) { Faker::Code.isbn(base: 13) }
    let(:valid_value_digits) { valid_value.gsub(/[^0-9]/, "") }
    let(:invalid_value) { "978-3-16-148410-X" }

    it "accepts valid isbns" do
      model_class.validates :isbn, isbn: true

      model.isbn = valid_value

      expect(model).to be_valid
    end

    it "rejects ISBN-13 with em dashes" do
      model_class.validates :isbn, isbn: true

      isbn_with_em_dashes = valid_value_digits.chars.each_slice(4).map { |s| s.join("—") }.join("—")
      model.isbn = isbn_with_em_dashes

      expect(model).not_to be_valid
    end

    it "rejects ISBN-13 with en dashes" do
      model_class.validates :isbn, isbn: true

      isbn_with_en_dashes = valid_value_digits.chars.each_slice(4).map { |s| s.join("–") }.join("–")
      model.isbn = isbn_with_en_dashes

      expect(model).not_to be_valid
    end
  end

  context "when ISBN-10" do
    let(:valid_value) { Faker::Code.isbn }
    let(:invalid_value) { "0-306-40615-X" }

    it "accepts valid isbns" do
      model_class.validates :isbn, isbn: true

      model.isbn = valid_value

      expect(model).to be_valid
    end

    it "accepts a valid isbn with an X check digit" do
      model_class.validates :isbn, isbn: true

      model.isbn = "097522980X"

      expect(model).to be_valid
    end

    it "rejects invalid isbns" do
      model_class.validates :isbn, isbn: true

      model.isbn = invalid_value

      expect(model).not_to be_valid
    end
  end

  context "when the value contains non-digit characters" do
    # Regression tests: String#to_i coerces non-digits to 0, so before the
    # character-grammar guard these all passed the checksum (sum of zeros).
    before { model_class.validates :isbn, isbn: true }

    it "rejects a 10-character all-letter string" do
      model.isbn = "helloworld"

      expect(model).not_to be_valid
    end

    it "rejects a 13-character all-letter string" do
      model.isbn = "AAAAAAAAAAAAA"

      expect(model).not_to be_valid
    end

    it "rejects a 10-character punctuation string" do
      model.isbn = "!!!!!!!!!!"

      expect(model).not_to be_valid
    end

    it "rejects letters mixed into an otherwise valid isbn" do
      model.isbn = "03064O6152" # letter O in place of a zero

      expect(model).not_to be_valid
    end

    it "rejects an ISBN-13 with an X check character" do
      model.isbn = "978316148410X"

      expect(model).not_to be_valid
    end
  end

  it "accepts nil with allow_nil option" do
    model_class.validates :isbn, isbn: true, allow_nil: true

    model.isbn = nil
    expect(model).to be_valid

    model.isbn = ""
    expect(model).not_to be_valid
  end

  it "accepts blank values with allow_blank option" do
    model_class.validates :isbn, isbn: true, allow_blank: true

    model.isbn = ""
    expect(model).to be_valid

    model.isbn = "   "
    expect(model).to be_valid

    model.isbn = nil
    expect(model).to be_valid
  end
end
