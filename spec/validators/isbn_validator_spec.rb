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

    it "rejects invalid isbns" do
      model_class.validates :isbn, isbn: true

      model.isbn = invalid_value

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
