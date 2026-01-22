# frozen_string_literal: true

class AffiliateMailer < ApplicationMailer
  include NotifyOfSaleHeaders
  include ActionView::Helpers::TextHelper
  include BasePrice::Recurrence

  layout "layouts/email"

  COLLABORATOR_MAX_PRODUCTS = 5

  def direct_affiliate_invitation(affiliate_id, prevent_sending_invitation_email_to_seller = false)
    @direct_affiliate = DirectAffiliate.find_by(id: affiliate_id)
    @seller = @direct_affiliate.seller
    @seller_name = @direct_affiliate.seller.name_or_username
    @products = @direct_affiliate.enabled_products
                                 .sort_by { -_1[:fee_percent] }
    product = @products.first
    @product_name = @products.one? ? product[:name] : pluralize(@direct_affiliate.products.count, "product")
    @affiliate_percentage_text = if @products.many? && @products.first[:fee_percent] != @products.last[:fee_percent]
      "#{@products.last[:fee_percent]} - #{product[:fee_percent]}%"
    else
      "#{product[:fee_percent]}%"
    end
    @affiliate_referral_url = affiliate_referral_url
    @final_destination_url = @products.one? ? product[:destination_url] : @direct_affiliate.final_destination_url

    @subject = "#{@seller_name} has added you as an affiliate."
    params = {
      to: @direct_affiliate.affiliate_user.form_email,
      subject: @subject
    }
    params[:cc] = @seller.form_email unless prevent_sending_invitation_email_to_seller

    mail params
  end

  def notify_affiliate_of_sale(purchase_id)
    @purchase = Purchase.find(purchase_id)
    @affiliate = @purchase.affiliate

    if @affiliate.collaborator?
      notify_collaborator_of_sale
    else
      @affiliate_percentage_text = "#{@affiliate.basis_points(product_id: @purchase.link_id) / 100}%"
      @purchase_price_formatted = MoneyFormatter.format(@purchase.price_cents, :usd, no_cents_if_whole: true, symbol: true)
      @affiliate_amount_formatted = MoneyFormatter.format(@purchase.affiliate_credit_cents, :usd, no_cents_if_whole: true, symbol: true)
      @free_trial_end_date = @purchase.link.is_tiered_membership? ? @purchase.subscription.free_trial_end_date_formatted : nil
      @recurring_commission_text = @purchase.is_original_subscription_purchase? ? "You'll continue to receive a commission once #{recurrence_long_indicator(@purchase.subscription.recurrence)} as long as the subscription is active." : nil

      if @affiliate.global?
        notify_global_affiliate_of_sale
      else
        notify_direct_affiliate_of_sale
      end
    end
  end

  def notify_direct_affiliate_of_updated_products(affiliate_id)
    @direct_affiliate = DirectAffiliate.find(affiliate_id)
    @products = @direct_affiliate.enabled_products
                                 .sort_by { -_1[:fee_percent] }
    seller_name = @direct_affiliate.seller.name_or_username

    @subject = "#{seller_name} just updated your affiliated products"
    mail to: @direct_affiliate.affiliate_user.form_email,
         subject: @subject
  end

  def notify_direct_affiliate_of_new_product(affiliate_id, product_id)
    @direct_affiliate = DirectAffiliate.find(affiliate_id)
    @seller_name = @direct_affiliate.seller.name_or_username
    product = Link.find(product_id)
    @product_name = product.name
    @affiliate_percentage_text = "#{@direct_affiliate.basis_points(product_id:) / 100}%"
    @affiliate_referral_url = @direct_affiliate.referral_url_for_product(product)

    @subject = "#{@seller_name} has added you as an affiliate to #{@product_name}."
    mail to: @direct_affiliate.affiliate_user.form_email,
         subject: @subject
  end

  def direct_affiliate_removal(affiliate_id)
    @direct_affiliate = DirectAffiliate.find_by(id: affiliate_id)
    @seller = @direct_affiliate.seller
    @seller_name = @direct_affiliate.seller.name_or_username

    @subject = "#{@seller_name} just updated your affiliate status"
    mail to: @direct_affiliate.affiliate_user.form_email,
         cc: @seller.form_email,
         subject: @subject
  end

  def collaborator_creation(collaborator_id)
    @collaborator = Collaborator.find(collaborator_id)
    @seller = @collaborator.seller
    @subject = "#{@collaborator.seller.name_or_username} has added you as a collaborator on Gumroad"
    @max_products = COLLABORATOR_MAX_PRODUCTS

    mail to: @collaborator.affiliate_user.form_email,
         cc: @seller.form_email,
         subject: @subject
  end

  def collaborator_update(collaborator_id)
    @collaborator = Collaborator.find(collaborator_id)
    @seller = @collaborator.seller
    @subject = "#{@collaborator.seller.name_or_username} has updated your collaborator status on Gumroad"
    @max_products = COLLABORATOR_MAX_PRODUCTS

    mail to: @collaborator.affiliate_user.form_email,
         cc: @seller.form_email,
         subject: @subject
  end

  def collaboration_ended_by_seller(collaborator_id)
    @collaborator = Collaborator.find(collaborator_id)
    @seller = @collaborator.seller
    @seller_name = @collaborator.seller.name_or_username

    @subject = "#{@seller_name} just updated your collaborator status"
    mail to: @collaborator.affiliate_user.form_email,
         cc: @seller.form_email,
         subject: @subject
  end
  alias_method :collaborator_removal, :collaboration_ended_by_seller

  def collaboration_ended_by_affiliate_user(collaborator_id)
    @collaborator = Collaborator.find(collaborator_id)
    @affiliate_user = @collaborator.affiliate_user
    @affiliate_user_name = @affiliate_user.name_or_username
    @seller = @collaborator.seller

    @subject = "#{@affiliate_user_name} has ended your collaboration"

    mail to: @seller.form_email,
         cc: @affiliate_user.form_email,
         subject: @subject
  end

  def collaborator_invited(collaborator_id)
    @collaborator = Collaborator.find(collaborator_id)
    @inviter = @collaborator.seller
    inviter_name = @inviter.name_or_username
    invitee = @collaborator.affiliate_user

    @max_products = COLLABORATOR_MAX_PRODUCTS

    @subject = "#{inviter_name} has invited you to collaborate on Gumroad"

    mail to: invitee.form_email,
         cc: @inviter.form_email,
         subject: @subject
  end

  def collaborator_invitation_accepted(collaborator_id)
    collaborator = Collaborator.find(collaborator_id)
    inviter = collaborator.seller
    @invitee = collaborator.affiliate_user
    invitee_name = @invitee.name_or_username

    @subject = "#{invitee_name} has accepted your invitation to collaborate on Gumroad"

    mail to: inviter.form_email,
         subject: @subject
  end

  def collaborator_invitation_declined(collaborator_id)
    collaborator = Collaborator.find(collaborator_id)
    inviter = collaborator.seller
    @invitee = collaborator.affiliate_user
    invitee_name = @invitee.name_or_username

    @subject = "#{invitee_name} has declined your invitation to collaborate on Gumroad"

    mail to: inviter.form_email,
         subject: @subject
  end

  private
    def notify_direct_affiliate_of_sale
      @seller = @purchase.seller
      @seller_name = @seller.name_or_username
      @product_name = @purchase.link.name
      @customer_email = @purchase.email

      @subject = "You helped #{@seller_name} make a sale."
      mail to: @affiliate.affiliate_user.form_email,
           subject: @subject,
           template_name: "notify_direct_affiliate_of_sale"
    end

    def notify_global_affiliate_of_sale
      @subject = "🎉 You earned a commission!"
      @seller_name = @purchase.seller.name_or_username
      @product_name = @purchase.link.name

      mail to: @affiliate.affiliate_user.form_email,
           subject: @subject,
           template_name: "notify_global_affiliate_of_sale"
    end

    def notify_collaborator_of_sale
      @product = @purchase.link
      @is_preorder = @purchase.is_preorder_authorization
      @quantity = @purchase.quantity
      @variants = @purchase.variants_list
      @variants_count = @purchase.variant_names&.count || 0
      @cut = MoneyFormatter.format(@purchase.affiliate_credit_cents + @purchase.affiliate_credit.fee_cents, :usd, no_cents_if_whole: true, symbol: true)

      @subject = "You made a sale!"
      set_notify_of_sale_headers(is_preorder: @is_preorder)

      mail to: @affiliate.affiliate_user.form_email,
           subject: @subject,
           template_name: "notify_collaborator_of_sale"
    end

    def affiliate_referral_url
      @direct_affiliate.products.count == 1 && @direct_affiliate.destination_url.blank? ? @direct_affiliate.referral_url_for_product(@direct_affiliate.products.first) : @direct_affiliate.referral_url
    end
end
