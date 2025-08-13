# frozen_string_literal: true

class AffiliateRequestMailer < ApplicationMailer
  layout "layouts/email"

  default from: "noreply@#{CUSTOMERS_MAIL_DOMAIN}"


  def notify_requester_of_request_submission(affiliate_request_id)
    @affiliate_request = AffiliateRequest.find(affiliate_request_id)

    @subject = "Your application request to #{@affiliate_request.seller.display_name} was submitted!"
    @requester_has_existing_account = User.exists?(email: @affiliate_request.email)
    mail to: @affiliate_request.email,
         subject: @subject,
         delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @affiliate_request.seller)
  end

  def notify_requester_of_request_approval(affiliate_request_id)
    @affiliate_request = AffiliateRequest.find(affiliate_request_id)
    requester = User.find_by!(email: @affiliate_request.email)

    @affiliated_products = requester
      .directly_affiliated_products
      .select("name, custom_permalink, unique_permalink, affiliates.id AS affiliate_id, COALESCE(affiliates_links.affiliate_basis_points, affiliates.affiliate_basis_points) AS basis_points")
      .where(affiliates: { seller_id: @affiliate_request.seller.id })
      .map do |affiliated_product|
        direct_affiliate = DirectAffiliate.new(id: affiliated_product.affiliate_id, affiliate_basis_points: affiliated_product.basis_points)

        {
          name: affiliated_product.name,
          url: direct_affiliate.referral_url_for_product(affiliated_product),
          commission: "#{direct_affiliate.affiliate_percentage}%"
        }
      end

    @subject = "Your affiliate request to #{@affiliate_request.seller.display_name} was approved!"

    mail to: @affiliate_request.email,
         subject: @subject,
         delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @affiliate_request.seller)
  end

  def notify_requester_of_ignored_request(affiliate_request_id)
    @affiliate_request = AffiliateRequest.find(affiliate_request_id)

    @subject = "Your affiliate request to #{@affiliate_request.seller.display_name} was not approved"
    mail to: @affiliate_request.email,
         subject: @subject,
         delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @affiliate_request.seller)
  end

  def notify_unregistered_requester_of_request_approval(affiliate_request_id)
    @affiliate_request = AffiliateRequest.find(affiliate_request_id)

    @subject = "Your affiliate request to #{@affiliate_request.seller.display_name} was approved!"

    mail to: @affiliate_request.email,
         subject: @subject,
         delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @affiliate_request.seller)
  end

  def notify_seller_of_new_request(affiliate_request_id)
    @affiliate_request = AffiliateRequest.find(affiliate_request_id)

    @subject = "#{@affiliate_request.name} has applied to be an affiliate"

    mail to: @affiliate_request.seller.email,
         subject: @subject,
         delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @affiliate_request.seller)
  end
end
