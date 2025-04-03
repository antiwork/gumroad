# frozen_string_literal: true

require "spec_helper"

describe ButtonHelper do
  describe "#navigation_helper" do
    it "renders button without options" do
      output = navigation_button("New product", new_product_path)
      expect(output).to eq('<a class="button accent" href="/products/new">New product</a>')
    end

    it "renders button with options" do
      output = navigation_button("New product", new_product_path, class: "one two", title: "Give me a title", disabled: true, color: "success")
      expect(output).to eq('<a title="Give me a title" class="one two button success" inert="inert" href="/products/new">New product</a>')
    end
  end
end
