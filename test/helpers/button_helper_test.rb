# frozen_string_literal: true

require "test_helper"

class ButtonHelperTest < ActionView::TestCase
  test "navigation_button renders without options" do
    output = navigation_button("New product", new_product_path)
    assert_equal '<a class="button accent" href="/products/new">New product</a>', output
  end

  test "navigation_button renders with options" do
    output = navigation_button(
      "New product",
      new_product_path,
      class: "one two",
      title: "Give me a title",
      disabled: true,
      color: "success",
    )
    assert_equal '<a title="Give me a title" class="one two button success" inert="inert" href="/products/new">New product</a>', output
  end
end
