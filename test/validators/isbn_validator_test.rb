# frozen_string_literal: true

require "test_helper"

class IsbnValidatorTest < ActiveSupport::TestCase
  def model_class
    @model_class ||= Class.new do
      include ActiveModel::Model
      attr_accessor :isbn
    end
  end

  setup { model_class.clear_validators! }

  test "accepts valid ISBN-13 values" do
    model_class.validates :isbn, isbn: true
    assert model_class.new(isbn: Faker::Code.isbn(base: 13)).valid?
  end

  test "rejects ISBN-13 with em dashes" do
    model_class.validates :isbn, isbn: true
    valid_value_digits = Faker::Code.isbn(base: 13).gsub(/[^0-9]/, "")
    isbn_with_em_dashes = valid_value_digits.chars.each_slice(4).map { |s| s.join("—") }.join("—")
    assert_not model_class.new(isbn: isbn_with_em_dashes).valid?
  end

  test "rejects ISBN-13 with en dashes" do
    model_class.validates :isbn, isbn: true
    valid_value_digits = Faker::Code.isbn(base: 13).gsub(/[^0-9]/, "")
    isbn_with_en_dashes = valid_value_digits.chars.each_slice(4).map { |s| s.join("–") }.join("–")
    assert_not model_class.new(isbn: isbn_with_en_dashes).valid?
  end

  test "accepts valid ISBN-10 values" do
    model_class.validates :isbn, isbn: true
    assert model_class.new(isbn: Faker::Code.isbn).valid?
  end

  test "rejects invalid ISBN-10 values" do
    model_class.validates :isbn, isbn: true
    assert_not model_class.new(isbn: "0-306-40615-X").valid?
  end

  test "accepts nil with allow_nil option" do
    model_class.validates :isbn, isbn: true, allow_nil: true

    assert model_class.new(isbn: nil).valid?
    assert_not model_class.new(isbn: "").valid?
  end

  test "accepts blank values with allow_blank option" do
    model_class.validates :isbn, isbn: true, allow_blank: true

    assert model_class.new(isbn: "").valid?
    assert model_class.new(isbn: "   ").valid?
    assert model_class.new(isbn: nil).valid?
  end
end
