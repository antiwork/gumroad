# frozen_string_literal: true

require "test_helper"

class PublicFileTest < ActiveSupport::TestCase
  # A real id that tripped the check: its letter runs are "tkk kink oc z t".
  ADULT_PUBLIC_ID = "tkk3kink1oc02z6t"

  test "generate_public_id skips a candidate that the adult keyword check reads as an adult word" do
    SecureRandom.stubs(:alphanumeric).returns(ADULT_PUBLIC_ID, "helloworld123456")

    assert_equal "helloworld123456", PublicFile.generate_public_id
  end

  test "a product description that embeds a generated public_id passes the adult keyword check" do
    product = create_product
    SecureRandom.stubs(:alphanumeric).returns(ADULT_PUBLIC_ID, "helloworld123456")

    product.description = %(<p>Listen</p><public-file-embed id="#{PublicFile.generate_public_id}"></public-file-embed>)

    assert product.valid?, product.errors.full_messages.to_sentence
  end
end
