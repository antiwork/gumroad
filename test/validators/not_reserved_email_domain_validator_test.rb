# frozen_string_literal: true

require "test_helper"

class NotReservedEmailDomainValidatorTest < ActiveSupport::TestCase
  def model_class
    @model_class ||= Class.new do
      include ActiveModel::Model
      attr_accessor :email
    end
  end

  setup { model_class.clear_validators! }

  test "validates the email domain case-insensitively" do
    model_class.validates :email, not_reserved_email_domain: true

    %w[user@GumRoad.com user@GumRoad.org user@GumRoad.dev].each do |email|
      assert_not model_class.new(email: email).valid?, "Expected #{email} to be reserved"
    end

    assert model_class.new(email: "user@gmail.com").valid?
  end

  test ".domain_reserved? matches reserved domains case-insensitively" do
    assert_equal true, NotReservedEmailDomainValidator.domain_reserved?("user@gumroad.com")
    assert_equal true, NotReservedEmailDomainValidator.domain_reserved?("user@GumRoad.com")
    assert_equal true, NotReservedEmailDomainValidator.domain_reserved?("user@GumRoad.org")
    assert_equal true, NotReservedEmailDomainValidator.domain_reserved?("user@GumRoad.dev")

    assert_equal false, NotReservedEmailDomainValidator.domain_reserved?("user@gmail.com")
    assert_equal false, NotReservedEmailDomainValidator.domain_reserved?(nil)
    assert_equal false, NotReservedEmailDomainValidator.domain_reserved?("")
  end
end
