# frozen_string_literal: true

class HelpCenter::CategoriesController < HelpCenter::BaseController
  def show
    category = HelpCenter::Category.find_by!(slug: params[:slug])

    set_meta_tag(title: "#{category.title} - Gumroad Help Center")
    set_meta_tag(tag_name: "link", rel: "canonical", href: help_center_category_url(category), head_key: "canonical")

    render inertia: "HelpCenter/Categories/Show", props: help_center_presenter.category_props(category)
  end
end
