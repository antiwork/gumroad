# frozen_string_literal: true

class HelpCenter::CategoriesController < HelpCenter::BaseController
  layout "help_center"

  def show
    @category = HelpCenter::Category.find_by!(slug: params[:slug])
  end
end
