# frozen_string_literal: true

# The footer sentence telling a recipient why they received a post email. Both PostSendgridApi and
# PostResendApi render it, so it lives here rather than in either: as separate copies they drifted
# (one said "post", the other "email") and both fell back to the purchase wording for a recipient
# whose record carries no purchase, telling a follower who never bought anything that they had.
#
# A recipient carries at most one of :purchase, :follower, :affiliate — the senders reject a mixed
# record — so whichever is present decides the sentence. A recipient carrying none (a preview sent
# straight through the API) gets no sentence, because no purchase can be claimed for it.
module PostEmailFooterReason
  module_function

  def build(post:, recipient:, cache:)
    return nil if recipient.slice(:purchase, :follower, :affiliate).compact_blank.empty?

    seller_name = post.seller.name.presence || post.seller.email || "Gumroad"
    return "You've received this email because you follow #{seller_name}." if recipient[:follower]
    return "You've received this email because you're an affiliate of #{seller_name}." if recipient[:affiliate]

    if post.seller_type?
      recipient[:purchase].free_purchase? ?
        "You've received this email because you got a product from #{seller_name}." :
        "You've received this email because you've purchased a product from #{seller_name}."
    elsif post.product_or_variant_type?
      product_name = recipient[:product_name] || cache[post][:sanitized_product_name]
      product_url = recipient[:url_redirect]&.download_page_url || post.link.long_url
      if post.member_cancellation_trigger?
        "You've received this email because you cancelled your membership to <a href=\"#{product_url}\">#{product_name}</a>."
      elsif post.link.is_recurring_billing
        "You've received this email because you subscribed to <a href=\"#{product_url}\">#{product_name}</a>."
      elsif recipient[:purchase].free_purchase?
        "You've received this email because you got <a href=\"#{product_url}\">#{product_name}</a>."
      else
        "You've received this email because you've purchased <a href=\"#{product_url}\">#{product_name}</a>."
      end
    end
  end
end
