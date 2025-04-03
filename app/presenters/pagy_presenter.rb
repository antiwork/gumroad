# frozen_string_literal: true

class PagyPresenter
  attr_reader :pagy

  def initialize(pagy)
    @pagy = pagy
  end

  def props
    { pages: pagy.last, page: pagy.page }
  end

  def metadata
    {
      count: pagy.count,
      items: pagy.limit,
      page: pagy.page,
      pages: pagy.pages,
      prev: pagy.prev,
      next: pagy.next,
      last: pagy.last
    }
  end
end
