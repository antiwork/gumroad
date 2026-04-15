# frozen_string_literal: true

class Api::Internal::ReceiptPreviewsController < Api::Internal::BaseController
  include FetchProductByUniquePermalink

  before_action :authenticate_user!
  before_action :fetch_product_by_unique_permalink

  def show
    e404 if @product.nil? || @product.user != current_seller

    @product.custom_receipt_text = params[:custom_receipt_text]
    @product.custom_view_content_button_text = params[:custom_view_content_button_text]
    purchase_preview = build_purchase_preview

    unless purchase_preview.valid?
      error_message = purchase_preview.errors.full_messages.join(", ")
      return render html: "Error: #{error_message}", status: :unprocessable_entity
    end

    rendered_html = ApplicationController.renderer.render(
      template: "customer_mailer/receipt",
      layout: "email",
      assigns: {
        chargeable: purchase_preview,
        receipt_presenter: ReceiptPresenter.new(purchase_preview, for_email: false)
      }
    )

    premailer = Premailer::Rails::CustomizedPremailer.new(rendered_html)

    render html: premailer.to_inline_css.html_safe, layout: false
  end

  private
    def build_purchase_preview
      price_cents = @product.price_cents || 0

      purchase_preview = PurchasePreview.new(
        link: @product,
        seller: @product.user,
        created_at: Time.current,
        quantity: 1,
        custom_fields: [],
        formatted_total_display_price_per_unit: MoneyFormatter.format(price_cents, @product.price_currency_type.to_sym, no_cents_if_whole: true, symbol: true),
        shipping_cents: 0,
        displayed_price_currency_type: @product.price_currency_type,
        url_redirect: OpenStruct.new(
          token: "preview_token"
        ),
        displayed_price_cents: price_cents,
        support_email: @product.user.support_or_form_email,
        charged_amount_cents: price_cents,
        external_id_for_invoice: "preview_order_id"
      )

      purchase_preview.unbundled_purchases = [purchase_preview]
      purchase_preview.successful_purchases = [purchase_preview]
      purchase_preview.orderable = purchase_preview

      purchase_preview
    end
end
