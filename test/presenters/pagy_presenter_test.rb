# frozen_string_literal: true

require "test_helper"

class PagyPresenterTest < ActiveSupport::TestCase
  test "formats a Pagy instance for the frontend" do
    pagy = Pagy.new(page: 2, count: 100, limit: 40)
    assert_equal({ pages: 3, page: 2 }, PagyPresenter.new(pagy).props)
  end
end
