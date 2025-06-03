# frozen_string_literal: true

module AdminHelper
  include IconHelper

  def user_name(user)
    user.name.presence || "User " + user.id.to_s
  end

  def link_to_processor(charge_processor_id, charge_id, charged_using_gumroad_account, opts = {})
    return nil unless charge_id

    url = ChargeProcessor.transaction_url_for_admin(charge_processor_id, charge_id, charged_using_gumroad_account)
    link_to_if(url.present?, charge_id, url, opts)
  end

  def link_to_stripe_fingerprint_search(fingerprint, opts)
    url = StripeChargeProcessor.fingerprint_search_url(fingerprint)
    link_to fingerprint, url, opts
  end

  def markdown(text)
    renderer = Redcarpet::Render::HTML.new(filter_html: true, safe_links_only: true)
    md = Redcarpet::Markdown.new(renderer, no_intra_emphasis: true)
    md.render(text).html_safe
  end

  def product_type_label(product)
    return "Product" unless product.is_recurring_billing?
    product.is_tiered_membership? ? "Membership" : "Subscription"
  end

  def format_datetime_with_relative_tooltip(value, placeholder: nil)
    return placeholder if value.nil?

    suffix = Time.current > value ? " ago" : " from now"
    relative_time = time_ago_in_words(value) + suffix
    tag.span(value.strftime("%b %d, %Y at %l:%M %p").strip, title: relative_time)
  end

  def card_types_for_react
    CreditCardUtility::CARD_TYPE_NAMES.map { |name, id| { id:, name: } }
  end

  def with_tooltip(tip:, position: nil, &block)
    return capture(&block) if tip.blank?

    uuid = SecureRandom.uuid
    css_classes = ["has-tooltip", position]
    tag.span(
      safe_join(
        [
          tag.span(aria: { describedby: uuid }, &block),
          tag.span(tip, role: "tooltip", id: uuid)
        ]
      ),
      class: css_classes.compact.join(" ")
    )
  end

  def blocked_email_tooltip(email)
    email_blocked_object = BlockedObject.email.find_active_object(email)
    email_domain = Mail::Address.new(email).domain
    email_domain_blocked_object = BlockedObject.email_domain.find_active_object(email_domain)
    return unless email_blocked_object || email_domain_blocked_object

    email_blocked_content = email_blocked_object&.blocked? && "Email blocked #{email_blocked_object.blocked_at.to_formatted_s(:long)} (block created #{email_blocked_object.created_at.to_formatted_s(:long)})"
    email_domain_blocked_content = email_domain_blocked_object&.blocked? && "#{email_domain} blocked #{email_domain_blocked_object.blocked_at.to_formatted_s(:long)} (block created #{email_domain_blocked_object.created_at.to_formatted_s(:long)})"
    content = tag.div(class: "paragraphs") do
      concat tag.span(email_blocked_content) if email_blocked_content
      concat tag.span(email_domain_blocked_content) if email_domain_blocked_content
    end.html_safe
    with_tooltip(tip: content) { icon("solid-shield-exclamation", style: "color: rgb(var(--warning))") }
  end

  def admin_action(props)
    react_component("AdminActionButton", props:, prerender: true)
  end
end
