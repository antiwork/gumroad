# frozen_string_literal: true

# Produces a placeholder HTML "v1" baseline for a freshly created Page so the
# AI editor opens on a real starting point rather than a blank chat. Calling
# the production product/profile renderer server-side is too coupled to the
# full controller env (request, theme, asset pipeline) to be safe here — see
# the v1-seeding section of the pages PR. Instead we render a minimal,
# semantically correct snapshot using just the model data and let the first
# AI iteration replace it.
module Ai
  module InitialPageSnapshot
    PRODUCT_INITIAL_PROMPT = "Initial version captured from your product page."
    PROFILE_INITIAL_PROMPT = "Initial version captured from your profile page."

    def self.create_for!(page)
      html = if page.link.present?
        product_html(page.link)
      elsif page.is_profile?
        profile_html(page.user)
      end
      return nil if html.blank?

      sanitized = Ai::PageSanitizer.sanitize(html)
      prompt = page.link.present? ? PRODUCT_INITIAL_PROMPT : PROFILE_INITIAL_PROMPT
      version = page.page_versions.create!(html: sanitized, prompt: prompt, parent: nil)
      page.update!(html_content: sanitized)
      version
    end

    def self.product_html(product)
      seller = product.user
      name = ERB::Util.html_escape(product.name.to_s)
      description = ERB::Util.html_escape(product.description.to_s.strip)
      price = ERB::Util.html_escape(product.display_price.to_s)
      buy_url = ERB::Util.html_escape("#{product.long_url}?wanted=true")
      permalink = ERB::Util.html_escape(product.unique_permalink.to_s)
      seller_name = ERB::Util.html_escape(seller.display_name.to_s)

      <<~HTML
        <section class="py-16">
          <div class="max-w-3xl mx-auto px-6 text-center">
            <p class="text-sm uppercase tracking-widest text-zinc-500 mb-4">#{seller_name}</p>
            <h1 class="text-4xl md:text-5xl font-bold mb-6">#{name}</h1>
            <p class="text-lg text-zinc-700 mb-8">#{description}</p>
            <a href="#{buy_url}" class="inline-block bg-black text-white px-8 py-3 rounded-md font-medium">
              Buy now — <span data-gumroad-ref="product:#{permalink}" data-gumroad-field="price">#{price}</span>
            </a>
          </div>
        </section>
        <section class="py-12 border-t border-zinc-200">
          <div class="max-w-3xl mx-auto px-6 text-center">
            <p class="text-sm text-zinc-500">Initial version captured from your product page. Iterate in chat to make it yours.</p>
          </div>
        </section>
      HTML
    end

    def self.profile_html(seller)
      name = ERB::Util.html_escape(seller.display_name.to_s)
      bio = ERB::Util.html_escape(seller.bio.to_s.strip)
      products = seller.products.alive.not_archived.limit(6)

      product_cards = products.map do |product|
        product_name = ERB::Util.html_escape(product.name.to_s)
        product_url = ERB::Util.html_escape(product.long_url.to_s)
        product_price = ERB::Util.html_escape(product.display_price.to_s)
        permalink = ERB::Util.html_escape(product.unique_permalink.to_s)
        <<~CARD
          <a href="#{product_url}" class="block p-6 rounded-lg border border-zinc-200 hover:border-zinc-400">
            <h3 class="font-semibold mb-2">#{product_name}</h3>
            <p class="text-sm text-zinc-600">
              <span data-gumroad-ref="product:#{permalink}" data-gumroad-field="price">#{product_price}</span>
            </p>
          </a>
        CARD
      end.join

      <<~HTML
        <section class="py-16">
          <div class="max-w-4xl mx-auto px-6 text-center">
            <h1 class="text-4xl md:text-5xl font-bold mb-4">#{name}</h1>
            <p class="text-lg text-zinc-700">#{bio}</p>
          </div>
        </section>
        <section class="py-12">
          <div class="max-w-4xl mx-auto px-6">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
              #{product_cards}
            </div>
          </div>
        </section>
        <section class="py-12 border-t border-zinc-200">
          <div class="max-w-4xl mx-auto px-6 text-center">
            <p class="text-sm text-zinc-500">Initial version captured from your profile page. Iterate in chat to make it yours.</p>
          </div>
        </section>
      HTML
    end
  end
end
