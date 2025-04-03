# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "creator dashboard page" do |title|
  it "marks the correct navigation link as active" do
    visit path
    within "nav", aria: { label: "Main" } do
      expect(page).to have_link(title, aria: { current: "page" })
    end

    visit "#{path}/"
    within "nav", aria: { label: "Main" } do
      expect(page).to have_link(title, aria: { current: "page" })
    end
  end
end
