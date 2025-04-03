# frozen_string_literal: true

require "spec_helper"

describe ProductFolder do
  it "validates presence of attributes" do
    product_folder = build(:product_folder, name: "")

    expect(product_folder.valid?).to eq(false)
    expect(product_folder.errors.messages).to eq(
      name: ["can't be blank"]
    )
  end
end
