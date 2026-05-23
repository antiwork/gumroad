# frozen_string_literal: true

require "test_helper"

class InfosHelperTest < ActionView::TestCase
  test "pagelength_displayable returns sections when filetype is epub" do
    define_singleton_method(:pagelength) { 100 }
    define_singleton_method(:epub?) { true }

    assert_equal "100 sections", pagelength_displayable
  end

  test "pagelength_displayable returns pages when filetype is not epub" do
    define_singleton_method(:pagelength) { 100 }
    define_singleton_method(:epub?) { false }

    assert_equal "100 pages", pagelength_displayable
  end
end
