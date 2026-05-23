# frozen_string_literal: true

require "test_helper"

class EmailRedactorServiceTest < ActiveSupport::TestCase
  test "redacts short emails" do
    assert_equal "f*o@b**.baz", EmailRedactorService.redact("foo@bar.baz")
  end

  test "preserves 1-char local parts" do
    assert_equal "a@b.co", EmailRedactorService.redact("a@b.co")
  end

  test "redacts emails with symbols" do
    assert_equal "a*****************s@v***********.com", EmailRedactorService.redact("a-test+with_symbols@valid-domain.com")
  end

  test "only keeps the TLD on multi-part TLDs" do
    assert_equal "j**n@e*********.uk", EmailRedactorService.redact("john@example.co.uk")
  end
end
