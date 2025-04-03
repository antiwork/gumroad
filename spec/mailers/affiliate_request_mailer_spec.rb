# frozen_string_literal: true

require "spec_helper"

describe AffiliateRequestMailer do
  let(:requester_email) { "requester@example.com" }
  let(:creator) { create(:named_user) }
  let(:affiliate_request) { create(:affiliate_request, email: requester_email, seller: creator) }

  describe "notify_requester_of_request_submission" do
    subject(:mail) { described_class.notify_requester_of_request_submission(affiliate_request.id) }

    it "sends email to requester" do
      expect(mail.to).to eq([requester_email])
      expect(mail.subject).to eq("Your application request to #{creator.display_name} was submitted!")
      expect(mail.body.encoded).to include("#{creator.display_name} is now reviewing your application and once they approve you, you will receive a confirmation email, along with some helpful tips to get started as an affiliate.")
      expect(mail.body.encoded).to include("<strong>Name:</strong> #{affiliate_request.name}")
      expect(mail.body.encoded).to include("<strong>Email:</strong> #{requester_email}")
      expect(mail.body.encoded).to include("In the meantime, <a href=\"#{signup_url(email: requester_email)}\">create your Gumroad account</a> using email #{requester_email} and confirm it. You'll receive your affiliate links once your Gumroad account is active.")
    end

    context "when requester already has an account" do
      let!(:requester) { create(:user, email: requester_email) }

      it "does not ask to create an account" do
        expect(mail.body.encoded).to_not include("In the meantime, <a href=\"#{signup_url(email: requester_email)}\">create your Gumroad account</a> using email #{requester_email} and confirm it. You'll receive your affiliate links once your Gumroad account is active.")
      end
    end
  end

  describe "notify_requester_of_request_approval" do
    let(:affiliate_request) { create(:affiliate_request, email: requester_email, seller: creator) }
    let!(:requester) { create(:user, email: requester_email) }
    let(:published_product_one) { create(:product, user: creator) }
    let(:published_product_two) { create(:product, user: creator) }
    let(:published_product_three) { create(:product, user: creator) }
    let!(:enabled_self_service_affiliate_product_for_published_product_one) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_one) }
    let!(:enabled_self_service_affiliate_product_for_published_product_two) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_two) }
    let!(:enabled_self_service_affiliate_product_for_published_product_three) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_three, affiliate_basis_points: 1000) }
    subject(:mail) { described_class.notify_requester_of_request_approval(affiliate_request.id) }

    before(:each) do
      affiliate_request.approve!
    end

    it "sends email to requester" do
      expect(mail.to).to eq([requester_email])
      expect(mail.subject).to eq("Your affiliate request to #{creator.display_name} was approved!")
      expect(mail.body.encoded).to include("Congratulations, you are now an official affiliate for #{creator.display_name}!")
      expect(mail.body.encoded).to include("You can now promote these products using these unique URLs:")
      requester.directly_affiliated_products.where(affiliates: { seller_id: creator.id }).each do |product|
        affiliate = product.direct_affiliates.first
        affiliate_percentage = affiliate.basis_points(product_id: product.id) / 100
        affiliate_product_url = affiliate.referral_url_for_product(product)

        expect(mail.body.encoded.squish).to include(%Q(<strong>#{product.name}</strong> (#{affiliate_percentage}% commission) <br> <a clicktracking="off" href="#{affiliate_product_url}">#{affiliate_product_url}</a>))
      end
      expect(mail.body.encoded.squish).to include(%Q(<a class="button primary" href="#{products_affiliated_index_url}">View all affiliated products</a>))
    end
  end

  describe "notify_requester_of_ignored_request" do
    subject(:mail) { described_class.notify_requester_of_ignored_request(affiliate_request.id) }

    before do
      affiliate_request.ignore!
    end

    it "sends email to requester" do
      expect(mail.to).to eq([requester_email])
      expect(mail.subject).to eq("Your affiliate request to #{creator.display_name} was not approved")
      expect(mail.body.encoded).to include("We are sorry, but your request to become an affiliate for #{creator.display_name} was not approved.")
      expect(mail.body.encoded).to include("<strong>Name:</strong> #{affiliate_request.name}")
      expect(mail.body.encoded).to include("<strong>Email:</strong> #{requester_email}")
    end
  end

  describe "notify_unregistered_requester_of_request_approval" do
    let(:affiliate_request) { create(:affiliate_request, email: requester_email, seller: creator) }
    let(:published_product) { create(:product, user: creator) }
    let!(:enabled_self_service_affiliate_product_for_published_product) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product) }
    subject(:mail) { described_class.notify_unregistered_requester_of_request_approval(affiliate_request.id) }

    before(:each) do
      affiliate_request.approve!
    end

    it "sends email to requester" do
      expect(mail.to).to eq([requester_email])
      expect(mail.subject).to eq("Your affiliate request to #{creator.display_name} was approved!")
      expect(mail.body.encoded).to include("Congratulations, #{creator.display_name} has approved your request to become an affiliate. In order to receive your affiliate links, you must first")
      expect(mail.body.encoded).to include(%Q(<a href="#{signup_url(email: requester_email)}">create your Gumroad account</a> using email #{requester_email} and confirm it.))
    end
  end

  describe "notify_seller_of_new_request" do
    subject(:mail) { described_class.notify_seller_of_new_request(affiliate_request.id) }

    it "sends email to creator" do
      expect(mail.to).to eq([creator.email])
      expect(mail.subject).to eq("#{affiliate_request.name} has applied to be an affiliate")
      expect(mail.body.encoded).to include("<strong>Name:</strong> #{affiliate_request.name}")
      expect(mail.body.encoded).to include("<strong>Email:</strong> #{requester_email}")
      expect(mail.body.encoded).to include(%Q("#{affiliate_request.promotion_text}"))
      expect(mail.body.encoded).to include(%Q(<a class="button primary" href="#{approve_affiliate_request_url(affiliate_request)}">Approve</a>))
      expect(mail.body.encoded).to include(%Q(<a class="button" href="#{ignore_affiliate_request_url(affiliate_request)}">Ignore</a>))
    end
  end
end
