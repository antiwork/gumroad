# frozen_string_literal: true

class PostSendgridApiPreview < ActionMailer::Preview
  def post_with_attachment
    post = Installment.joins(:product_files).find_each(order: :desc).find(&:has_files?)
    post ||= begin
      record = create_generic_post
      record.product_files.create!(url: "#{AWS_S3_ENDPOINT}/gumroad_dev/test", filetype: "pdf", filegroup: "document")
      record
    end
    build_mail(post:, recipient: { url_redirect: UrlRedirect.find_or_create_by!(installment: post, purchase: nil) })
  end

  def post_not_shown_on_profile
    post = Installment.not_shown_on_profile.left_joins(:product_files).where(product_files: { id: nil }).last
    post ||= create_generic_post(shown_on_profile: false)
    build_mail(post:)
  end

  def commentable_post
    post = Installment.shown_on_profile.allow_comments.left_joins(:product_files).where(product_files: { id: nil }).last
    post ||= create_generic_post(shown_on_profile: true, allow_comments: true)
    build_mail(post:)
  end

  def product_post
    post = Installment.joins(seller: { sales: :url_redirect }).where(installment_type: Installment::PRODUCT_TYPE).last
    post ||= begin
      user = User.first!
      product = user.products.create!(name: "some product", price_cents: 0)
      purchase = Purchase.new(email: "foo@example.com", link: product, seller: user)
      purchase.prepare_for_charge!
      purchase.save!
      purchase.create_url_redirect!
      create_generic_post(installment_type: Installment::PRODUCT_TYPE, link: product, bought_products: [product.unique_permalink])
    end
    purchase = post.seller&.sales&.last
    url_redirect = purchase&.url_redirect
    build_mail(post:, recipient: { purchase:, url_redirect: })
  end

  def for_customer
    post = Installment.joins(seller: { sales: :url_redirect }).where(installment_type: Installment::SELLER_TYPE).last
    post ||= begin
      user = User.first!
      product = user.products.create!(name: "some product", price_cents: 0)
      purchase = Purchase.new(email: "foo@example.com", link: product, seller: user)
      purchase.prepare_for_charge!
      purchase.save!
      purchase.create_url_redirect!
      create_generic_post(installment_type: Installment::SELLER_TYPE)
    end
    purchase = post.seller&.sales&.last
    url_redirect = purchase&.url_redirect
    build_mail(post:, recipient: { purchase:, url_redirect: })
  end

  def for_follower
    post = Installment.where(installment_type: Installment::FOLLOWER_TYPE).left_joins(:product_files).where(product_files: { id: nil }).joins(seller: :followers).last
    post ||= begin
      user = User.first!
      user.followers.active.last || user.followers.create!(email: "foo@example.com", confirmed_at: Time.current)
      create_generic_post(installment_type: Installment::FOLLOWER_TYPE)
    end
    follower = post.seller&.followers&.last
    build_mail(post:, recipient: { follower: })
  end

  def for_affiliate
    post = Installment.where(installment_type: Installment::AFFILIATE_TYPE).left_joins(:product_files).where(product_files: { id: nil }).joins(seller: :direct_affiliates).last
    post ||= begin
      user = User.first!
      user.direct_affiliates.last || user.direct_affiliates.create!(affiliate_user: User.second!, affiliate_basis_points: 1000)
      create_generic_post(installment_type: Installment::AFFILIATE_TYPE)
    end
    affiliate = post.seller&.direct_affiliates&.last
    build_mail(post:, recipient: { affiliate: })
  end

  private
    def build_mail(post:, recipient: {})
      recipients = [{ email: "foo@example.com" }.merge(recipient)]
      PostSendgridApi.new(post:, recipients:, preview: true).build_mail
      email_address = recipients.first[:email]
      details = PostSendgridApi.mails.fetch(email_address) # Tip: if this fails, you may have POST_SENDGRID_API_SKIP_DEBUG=1
      mail = Mail.new
      mail.subject = details[:subject]
      mail.from = details[:from]
      mail.reply_to = details[:reply_to]
      mail.to = email_address
      mail.headers({ skip_premailer: true })
      mail.part content_type: "multipart/alternative", content_disposition: "inline" do |multipart|
        multipart.part content_type: "text/html", body: details[:content]
      end
      mail
    end

    def create_generic_post(extra_attributes = {})
      Installment.create!({
        seller: User.first!,
        name: "Generic post",
        message: "Some post content<br>Some <i>more</i> content",
        installment_type: Installment::AUDIENCE_TYPE,
        send_emails: true,
        shown_on_profile: true,
      }.merge(extra_attributes))
    end
end
