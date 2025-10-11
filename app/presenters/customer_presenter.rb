# frozen_string_literal: true

class CustomerPresenter
  attr_reader :purchase

  def initialize(purchase:)
    @purchase = purchase
  end

  def missed_posts
    posts = Installment.missed_for_purchase(purchase).order(published_at: :desc)
    posts.map do |post|
      {
        id: post.external_id,
        name: post.name,
        url: post.full_url,
        published_at: post.published_at,
      }
    end
  end

  def customer(pundit_user:)
    offer_code = purchase.original_offer_code
    variant = purchase.variant_attributes.first
    review = purchase.original_product_review
    product = purchase.link
    call = purchase.call
    commission = purchase.commission
    utm_link = purchase.utm_link
    {
      id: purchase.external_id,
      email: purchase.email,
      giftee_email: purchase.giftee_email,
      name: purchase.full_name || "",
      physical: purchase.sku.present? ?
        {
          sku: purchase.sku.custom_name_or_external_id,
          order_number: purchase.external_id_numeric.to_s,
        } : nil,
      shipping: purchase.link.require_shipping? ?
        {
          address: purchase.shipping_information,
          price: purchase.formatted_shipping_amount,
          tracking: purchase.shipment.present? ?
            {
              shipped: purchase.shipment.shipped?,
              url: purchase.shipment.tracking_url,
            } : { shipped: false },
        } : nil,
      is_bundle_purchase: purchase.is_bundle_purchase,
      is_existing_user: purchase.purchaser.present?,
      can_contact: purchase.can_contact?,
      product: {
        name: product.name,
        permalink: product.unique_permalink,
        native_type: product.native_type,
      },
      created_at: purchase.created_at.iso8601,
      price:
        {
          cents: purchase.subscription&.current_subscription_price_cents || purchase.displayed_price_cents,
          cents_before_offer_code: purchase.displayed_price_cents_before_offer_code(include_deleted: true) || purchase.displayed_price_cents,
          cents_refundable: purchase.amount_refundable_cents_in_currency,
          currency_type: purchase.displayed_price_currency_type.to_s,
          recurrence: (purchase.subscription || purchase.price)&.recurrence,
          tip_cents: purchase.tip&.value_cents,
        },
      quantity: purchase.quantity,
      discount: offer_code.present? ?
        offer_code.is_cents? ?
          { type: "fixed", cents: offer_code.amount_cents, code: offer_code.code } :
          { type: "percent", percents: offer_code.amount_percentage, code: offer_code.code }
        : nil,
      upsell: purchase.upsell_purchase&.upsell&.name,
      subscription: purchase.subscription.present? ?
        {
          id: purchase.subscription.external_id,
          status: purchase.subscription.status,
          is_installment_plan: purchase.subscription.is_installment_plan,
          remaining_charges: purchase.subscription.has_fixed_length? ? purchase.subscription.remaining_charges_count : nil,
        } : nil,
      is_multiseat_license: purchase.is_multiseat_license,
      referrer: purchase.display_referrer,
      is_additional_contribution: purchase.is_additional_contribution,
      ppp: purchase.ppp_info,
      is_preorder: purchase.preorder.present? && purchase.is_preorder_authorization,
      affiliate: purchase.affiliate.present? ?
        {
          email: purchase.affiliate.affiliate_user.form_email,
          amount: Money.new(purchase.affiliate_credit_cents).format(no_cents_if_whole: true, symbol: true),
          type: purchase.affiliate.type,
        } : nil,
      license: purchase.linked_license.present? ?
        {
          id: purchase.linked_license.external_id,
          key: purchase.linked_license.serial,
          enabled: !purchase.linked_license.disabled?,
        } : nil,
      review: review.present? ?
        {
          rating: review.rating,
          message: review.message.presence,
          response: review.response ? {
            message: review.response.message,
          } : nil,
          videos: review_videos_props(alive_videos: review.alive_videos, pundit_user:),
        } : nil,
      call: call.present? ?
        {
          id: call.external_id,
          call_url: call.call_url,
          start_time: call.start_time.iso8601,
          end_time: call.end_time.iso8601,
        } : nil,
      commission: commission.present? ? {
        id: commission.external_id,
        files: commission.files.map { file_details(_1) },
        status: commission.status,
      } : nil,
      custom_fields: purchase.purchase_custom_fields.map do |field|
        if field[:type] == CustomField::TYPE_FILE
          { attribute: field.name, type: "file", files: field.files.map { file_details(_1) } }
        else
          { attribute: field.name, type: "text", value: field.value.to_s }
        end
      end,
      transaction_url_for_seller: purchase.transaction_url_for_seller,
      is_access_revoked: purchase.is_access_revoked? ?
          (Pundit.policy!(pundit_user, [:audience, purchase]).undo_revoke_access? || nil) :
          (Pundit.policy!(pundit_user, [:audience, purchase]).revoke_access? ? false : nil),
      paypal_refund_expired: purchase.paypal_refund_expired?,
      refunded: purchase.stripe_refunded?,
      partially_refunded: purchase.stripe_partially_refunded?,
      chargedback: purchase.chargedback? && !purchase.chargeback_reversed?,
      has_options: variant.present? || purchase.link.alive_variants.any?,
      option: variant.present? ?
        (variant.is_a?(Sku) ? variant.to_option_for_product : variant.to_option) :
        nil,
      utm_link: utm_link.present? ? {
        title: utm_link.title,
        utm_url: utm_link.utm_url,
        source: utm_link.utm_source,
        medium: utm_link.utm_medium,
        campaign: utm_link.utm_campaign,
        term: utm_link.utm_term,
        content: utm_link.utm_content,
      } : nil,
      download_count: download_count
    }
  end

  def download_count
    return nil if purchase.is_bundle_purchase?
    product = purchase.link
    return nil if product.native_type == Link::NATIVE_TYPE_COFFEE

    purchase.url_redirect&.uses || 0
  end

  def charge
    {
      id: purchase.external_id,
      created_at: purchase.created_at.iso8601,
      partially_refunded: purchase.stripe_partially_refunded?,
      refunded: purchase.stripe_refunded?,
      amount_refundable: purchase.amount_refundable_cents_in_currency,
      currency_type: purchase.link.price_currency_type,
      transaction_url_for_seller: purchase.transaction_url_for_seller,
      is_upgrade_purchase: purchase.is_upgrade_purchase?,
      chargedback: purchase.chargedback? && !purchase.chargeback_reversed?,
      paypal_refund_expired: purchase.paypal_refund_expired?,
    }
  end

  private
    def file_details(file)
      {
        id: file.signed_id,
        name: File.basename(file.filename.to_s, ".*"),
        size: file.byte_size,
        extension: File.extname(file.filename.to_s).delete(".").upcase,
        key: file.key
      }
    end

    def review_videos_props(alive_videos:, pundit_user:)
      # alive_videos of different states are pre-loaded together to simplify
      # the query, and there is guaranteed to be at-most one pending and
      # at-most one approved video.
      pending = alive_videos.find(&:pending_review?)
      approved = alive_videos.find(&:approved?)

      [pending, approved]
        .compact
        .map { |video| ProductReviewVideoPresenter.new(video).props(pundit_user:) }
    end
end
