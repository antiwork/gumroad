# frozen_string_literal: true

class HelpCenter::CategoriesController < HelpCenter::BaseController
  def show
    @category = HelpCenter::Category.find_by!(slug: params[:slug])
  end
end
