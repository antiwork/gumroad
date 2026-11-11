# frozen_string_literal: true

class HelpCenter::CategoriesController < HelpCenter::BaseController
  def show
    category = HelpCenter::Category.find_by!(slug: params[:slug])
    props = help_center_presenter.category_props(category)

    title = "#{category.title} - Gumroad Help Center"
    description = category_description(props[:category])
    canonical_url = help_center_category_url(category)

    set_meta_tag(title:)
    set_meta_tag(tag_name: "link", rel: "canonical", href: canonical_url, head_key: "canonical")
    set_meta_tag(name: "description", content: description)

    set_meta_tag(property: "og:title", content: title)
    set_meta_tag(property: "og:description", content: description)
    set_meta_tag(property: "og:url", content: canonical_url)

    set_meta_tag(name: "twitter:title", content: title)
    set_meta_tag(name: "twitter:description", content: description)

    @seo_links_fallback = {
      heading: category.title,
      description:,
      sections: [
        {
          links: props[:category][:articles].map { |article| { label: article[:title], href: article[:url] } },
        },
        {
          heading: "More help topics",
          links: props[:sidebar_categories].map { |sibling| { label: sibling[:title], href: sibling[:url] } },
        },
      ],
    }

    render inertia: "HelpCenter/Categories/Show", props:
  end

  private
    DESCRIPTION_MAX_LENGTH = 160

    # Categories carry no description of their own, and without one every category page
    # served the same head. Naming the articles gives each page distinct text.
    def category_description(category_props)
      article_titles = category_props[:articles].map { |article| article[:title] }
      return "#{category_props[:title]}: Gumroad Help Center articles." if article_titles.empty?

      "#{category_props[:title]}: #{article_titles.to_sentence}".truncate(DESCRIPTION_MAX_LENGTH, separator: " ")
    end
end
