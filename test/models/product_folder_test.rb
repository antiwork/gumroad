# frozen_string_literal: true

require "test_helper"

class ProductFolderTest < ActiveSupport::TestCase
  self.described_class = ProductFolder



  context_ ProductFolder do
  test "validates presence of attributes" do
      product_folder = build(:product_folder, name: "")

      expect(product_folder.valid?).to eq(false)
      expect(product_folder.errors.messages).to eq(
        name: ["can't be blank"]
      )
    end
  end
end
