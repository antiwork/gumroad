# frozen_string_literal: true

require "spec_helper"

describe PagyPresenter do
  it "formats a Pagy instance for the frontend" do
    pagy = Pagy.new(page: 2, count: 100, limit: 40)
    expect(PagyPresenter.new(pagy).props).to eq({ pages: 3, page: 2 })
  end
end
