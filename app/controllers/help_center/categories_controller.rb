# frozen_string_literal: true

class HelpCenter::CategoriesController < HelpCenter::BaseController
  def show
    category = HelpCenter::Category.find_by!(slug: params[:slug])
    render inertia: "HelpCenter/Category/Show", props: help_center_presenter.category_props(category)
  end
end
