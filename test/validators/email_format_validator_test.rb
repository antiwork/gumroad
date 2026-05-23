# frozen_string_literal: true

require "test_helper"

class EmailFormatValidatorTest < ActiveSupport::TestCase
  def model_class
    @model_class ||= Class.new do
      include ActiveModel::Model
      attr_accessor :email
    end
  end

  setup { model_class.clear_validators! }

  test "does not accept blank or nil values by default" do
    model_class.validates :email, email_format: true

    model = model_class.new(email: nil)
    assert_not model.valid?

    model.email = ""
    assert_not model.valid?
  end

  test "accepts valid emails" do
    model_class.validates :email, email_format: true

    model = model_class.new(email: "user@example.com")
    assert model.valid?
  end

  test "accepts nil with allow_nil option" do
    model_class.validates :email, email_format: true, allow_nil: true

    model = model_class.new(email: nil)
    assert model.valid?

    model.email = ""
    assert_not model.valid?
  end

  test "accepts blank values with allow_blank option" do
    model_class.validates :email, email_format: true, allow_blank: true

    model = model_class.new(email: "")
    assert model.valid?

    model.email = "   "
    assert model.valid?

    model.email = nil
    assert model.valid?
  end

  test ".valid? returns true for valid emails" do
    assert_equal true, EmailFormatValidator.valid?("user@example.com")
  end

  test ".valid? returns false for invalid emails and blank values" do
    assert_equal false, EmailFormatValidator.valid?("invalid")
    assert_equal false, EmailFormatValidator.valid?(nil)
    assert_equal false, EmailFormatValidator.valid?("")
  end
end
