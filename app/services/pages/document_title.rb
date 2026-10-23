# frozen_string_literal: true

# The <title> of a slugged page's standalone document. The store name is appended
# for browser-tab and search-result context; a seller who already ends their page
# title with their store name would otherwise see it twice. A seller-set SEO
# title is used as written.
module Pages
  module DocumentTitle
    module_function

    def for(page_title:, seller_name:, seo_title: nil)
      return seo_title if seo_title.present?

      title = page_title.to_s
      seller = seller_name.to_s.strip
      # A blank store name (or no name at all) leaves the page title alone.
      return title if seller.empty? || title.strip.downcase.end_with?(seller.downcase)
      return seller if title.strip.empty?

      "#{title} — #{seller}"
    end
  end
end
