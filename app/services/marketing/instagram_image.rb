# frozen_string_literal: true

# The image an Instagram post of a product carries. Instagram has no text-only posts and
# takes JPEG only, from a URL Meta can download.
class Marketing::InstagramImage
  include CdnUrlHelper

  # Instagram's own display width is 1080; more than this only slows Meta's download.
  MAX_DIMENSION = 1440

  def initialize(product)
    @preview = product.display_asset_previews.find(&:image_url?)
  end

  def available? = @preview.present?

  # Converting generates a variant, so call this where the post is made, never on a page render.
  def url
    return unless available?
    return @preview.unsplash_url if @preview.unsplash_url.present?

    variant = @preview.file.variant(convert: "jpg", resize_to_limit: [MAX_DIMENSION, MAX_DIMENSION])
    cdn_url_for(variant.processed.url)
  end
end
