# frozen_string_literal: true

require "spec_helper"

describe UtmLink do
  describe "associations" do
    it { is_expected.to belong_to(:seller).class_name("User").optional(false) }
    it { is_expected.to belong_to(:target_resource).optional(true) }
    it { is_expected.to have_many(:utm_link_visits).dependent(:destroy) }
    it { is_expected.to have_many(:utm_link_driven_sales).dependent(:destroy) }
    it { is_expected.to have_many(:purchases).through(:utm_link_driven_sales) }
    it { is_expected.to have_many(:successful_purchases).through(:utm_link_driven_sales) }

    describe "successful_purchases" do
      let(:seller) { create(:user) }
      subject(:utm_link) { create(:utm_link, seller:) }
      let(:product) { create(:product, user: seller) }
      let(:purchase1) { create(:purchase, price_cents: 1000, seller:, link: product) }
      let(:purchase2) { create(:purchase, price_cents: 2000, seller:, link: product) }
      let(:test_purchase) { create(:test_purchase, price_cents: 3000, seller:, link: product) }
      let(:failed_purchase) { create(:failed_purchase, price_cents: 1000, seller:, link: product) }
      let!(:utm_link_driven_sale1) { create(:utm_link_driven_sale, utm_link: subject, purchase: purchase1) }
      let!(:utm_link_driven_sale2) { create(:utm_link_driven_sale, utm_link: subject, purchase: purchase2) }
      let!(:utm_link_driven_sale3) { create(:utm_link_driven_sale, utm_link: subject, purchase: test_purchase) }
      let!(:utm_link_driven_sale4) { create(:utm_link_driven_sale, utm_link: subject, purchase: failed_purchase) }

      it "returns successful purchases" do
        expect(subject.successful_purchases).to eq([purchase1, purchase2])
      end
    end
  end

  describe "validations" do
    it { is_expected.to be_versioned }

    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to define_enum_for(:target_resource_type)
                          .with_values(profile_page: "profile_page",
                                       subscribe_page: "subscribe_page",
                                       product_page: "product_page",
                                       post_page: "post_page")
                          .backed_by_column_of_type(:string)
                          .with_prefix(:target) }

    describe "target_resource_id" do
      context "when target_resource_type is product_page" do
        subject(:utm_link) { build(:utm_link, target_resource_type: :product_page) }

        it "is invalid when absent" do
          expect(subject).to be_invalid
          expect(subject.errors[:target_resource_id]).to include("can't be blank")
        end

        it "is valid when present" do
          subject.target_resource_id = create(:product).id
          expect(subject).to be_valid
        end
      end

      context "when target_resource_type is post_page" do
        subject(:utm_link) { build(:utm_link, target_resource_type: :post_page) }

        it "is invalid when absent" do
          expect(subject).to be_invalid
          expect(subject.errors[:target_resource_id]).to include("can't be blank")
        end

        it "is valid when present" do
          subject.target_resource_id = create(:post).id
          expect(subject).to be_valid
        end
      end
      context "when target_resource_type is profile_page" do
        subject(:utm_link) { build(:utm_link, target_resource_type: :profile_page) }

        it "is valid" do
          expect(subject).to be_valid
        end
      end
      context "when target_resource_type is subscribe_page" do
        subject(:utm_link) { build(:utm_link, target_resource_type: :subscribe_page) }

        it "is valid when absent" do
          expect(subject).to be_valid
        end
      end
    end

    context "permalink" do
      subject(:utm_link) { build(:utm_link, permalink: "existing") }

      it { is_expected.to validate_uniqueness_of(:permalink).case_insensitive }
      it { is_expected.to allow_value("existin1").for(:permalink) }
      it { is_expected.not_to allow_value("long-val-with-$ymbols").for(:permalink) }
    end

    it { is_expected.to validate_presence_of(:utm_campaign) }
    it { is_expected.to validate_length_of(:utm_campaign).is_at_most(UtmLink::MAX_UTM_PARAM_LENGTH) }
    it { is_expected.to validate_presence_of(:utm_medium) }
    it { is_expected.to validate_length_of(:utm_medium).is_at_most(UtmLink::MAX_UTM_PARAM_LENGTH) }
    it { is_expected.to validate_presence_of(:utm_source) }
    it { is_expected.to validate_length_of(:utm_source).is_at_most(UtmLink::MAX_UTM_PARAM_LENGTH) }
    it { is_expected.to validate_length_of(:utm_term).is_at_most(UtmLink::MAX_UTM_PARAM_LENGTH) }
    it { is_expected.to validate_length_of(:utm_content).is_at_most(UtmLink::MAX_UTM_PARAM_LENGTH) }

    describe "last_click_at_is_same_or_after_first_click_at" do
      context "when last_click_at is not present" do
        it "is valid" do
          utm_link = build(:utm_link, last_click_at: nil)

          expect(utm_link).to be_valid
        end
      end
      context "when last_click_at is present" do
        it "is invalid if first_click_at is nil" do
          utm_link = build(:utm_link, first_click_at: nil, last_click_at: 3.days.ago)

          expect(utm_link).to be_invalid
          expect(utm_link.errors[:last_click_at]).to include("must be same or after the first click at")
        end

        it "is invalid if last_click_at is before first_click_at" do
          utm_link = build(:utm_link, first_click_at: 2.days.ago, last_click_at: 3.days.ago)

          expect(utm_link).to be_invalid
          expect(utm_link.errors[:last_click_at]).to include("must be same or after the first click at")
        end

        it "is valid if last_click_at is same as first_click_at" do
          first_click_at = 2.days.ago
          utm_link = build(:utm_link, first_click_at:, last_click_at: first_click_at)

          expect(utm_link).to be_valid
        end

        it "is valid if last_click_at is after first_click_at" do
          utm_link = build(:utm_link, first_click_at: 2.days.ago, last_click_at: 1.day.ago)

          expect(utm_link).to be_valid
        end
      end
    end

    describe "utm_fields_are_unique" do
      let(:seller) { create(:user) }
      let!(:product) { create(:product, user: seller) }

      it "prevents duplicate UTM parameters for the same target resource and seller" do
        create(:utm_link,
               seller:,
               target_resource_type: "product_page",
               target_resource_id: product.id,
               utm_source: "facebook",
               utm_medium: "social",
               utm_campaign: "spring",
               utm_term: "sale",
               utm_content: "banner",
        )

        duplicate = build(:utm_link,
                          seller:,
                          utm_source: "facebook",
                          utm_medium: "social",
                          utm_campaign: "spring",
                          utm_term: "sale",
                          utm_content: "banner",
                          target_resource_type: "product_page",
                          target_resource_id: product.id
        )

        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:target_resource_id]).to include("A link with similar UTM parameters already exists for this destination!")
      end

      it "allows same UTM parameters for different target resources of the same seller" do
        create(:utm_link,
               seller:,
               target_resource_type: "product_page",
               target_resource_id: product.id,
               utm_source: "facebook",
               utm_medium: "social",
               utm_campaign: "spring",
               utm_term: "sale",
               utm_content: "banner"
        )

        duplicate_with_different_target_resource = build(:utm_link,
                                                         seller:,
                                                         target_resource_type: "profile_page",
                                                         target_resource_id: nil,
                                                         utm_source: "facebook",
                                                         utm_medium: "social",
                                                         utm_campaign: "spring",
                                                         utm_term: "sale",
                                                         utm_content: "banner"
        )

        expect(duplicate_with_different_target_resource).to be_valid
      end

      it "allows duplicate UTM parameters for the same target resource for different sellers" do
        create(:utm_link,
               seller:,
               target_resource_type: "product_page",
               target_resource_id: product.id,
               utm_source: "facebook",
               utm_medium: "social",
               utm_campaign: "spring",
               utm_term: "sale",
               utm_content: "banner"
        )

        duplicate_for_other_seller = build(:utm_link,
                                           seller: create(:user),
                                           target_resource_type: "product_page",
                                           target_resource_id: product.id,
                                           utm_source: "facebook",
                                           utm_medium: "social",
                                           utm_campaign: "spring",
                                           utm_term: "sale",
                                           utm_content: "banner"
        )

        expect(duplicate_for_other_seller).to be_valid
      end

      it "allows duplicate UTM parameters if original is deleted" do
        create(:utm_link,
               seller:,
               target_resource_type: "product_page",
               target_resource_id: product.id,
               utm_source: "facebook",
               utm_medium: "social",
               utm_campaign: "spring",
               utm_term: "sale",
               utm_content: "banner",
               deleted_at: Time.current
        )

        duplicate = build(:utm_link,
                          seller:,
                          target_resource_type: "product_page",
                          target_resource_id: product.id,
                          utm_source: "facebook",
                          utm_medium: "social",
                          utm_campaign: "spring",
                          utm_term: "sale",
                          utm_content: "banner"
        )

        expect(duplicate).to be_valid
      end

      it "allows updating a UTM link without triggering UTM parameters' uniqueness validation" do
        utm_link = create(:utm_link,
                          seller:,
                          target_resource_type: "product_page",
                          target_resource_id: product.id,
                          utm_source: "facebook",
                          utm_medium: "social",
                          utm_campaign: "spring"
        )

        utm_link.title = "Updated Title"
        expect(utm_link).to be_valid
        expect(utm_link.save).to be(true)
      end
    end
  end

  describe "scopes" do
    describe "enabled" do
      it "returns only enabled utm links" do
        enabled_link = create(:utm_link)
        create(:utm_link, disabled_at: Time.current)

        expect(described_class.enabled).to eq([enabled_link])
      end
    end

    describe "active" do
      it "returns only alive and enabled utm links" do
        active_link = create(:utm_link)
        create(:utm_link, disabled_at: Time.current)
        create(:utm_link, deleted_at: Time.current)

        expect(described_class.active).to eq([active_link])
      end
    end
  end

  describe "callbacks" do
    describe "#set_permalink" do
      it "sets the permalink before validation" do
        utm_link = build(:utm_link)
        utm_link.valid?
        expect(utm_link.permalink).to be_present
      end

      it "does not set the permalink if it is already set" do
        utm_link = create(:utm_link)
        utm_link.permalink = "existing-permalink"
        utm_link.valid?
        expect(utm_link.permalink).to eq("existing-permalink")
      end
    end
  end

  describe "#enabled?" do
    it "returns true when utm link is not disabled" do
      expect(create(:utm_link)).to be_enabled
    end

    it "returns false when utm link is disabled" do
      expect(create(:utm_link, disabled_at: Time.current)).not_to be_enabled
    end
  end

  describe "#active?" do
    it "returns true when utm link is enabled and not deleted" do
      expect(create(:utm_link)).to be_active
    end

    it "returns false when utm link is disabled" do
      expect(create(:utm_link, disabled_at: Time.current)).not_to be_active
    end

    it "returns false when utm link is deleted" do
      expect(create(:utm_link, deleted_at: Time.current)).not_to be_active
    end
  end

  describe "#mark_disabled!" do
    it "marks the utm link as disabled" do
      utm_link = create(:utm_link)

      utm_link.mark_disabled!

      expect(utm_link.disabled_at).to be_within(2.second).of(Time.current)
      expect(utm_link).not_to be_enabled
    end
  end

  describe "#mark_enabled!" do
    it "marks the utm link as enabled" do
      utm_link = create(:utm_link, disabled_at: Time.current)

      utm_link.mark_enabled!

      expect(utm_link).to be_enabled
    end
  end

  describe "#short_url" do
    it "returns the short URL" do
      utm_link = create(:utm_link)
      expect(utm_link.short_url).to eq("#{UrlService.short_domain_with_protocol}/u/#{utm_link.permalink}")
    end
  end

  describe "#utm_url" do
    context "when target_resource_type is profile_page" do
      it "returns the seller's profile URL with UTM parameters" do
        utm_link = create(:utm_link, target_resource_type: :profile_page, utm_term: "hello", utm_content: "world")

        expect(utm_link.utm_url).to eq("#{utm_link.seller.profile_url}?utm_campaign=#{utm_link.utm_campaign}&utm_content=#{utm_link.utm_content}&utm_medium=#{utm_link.utm_medium}&utm_source=#{utm_link.utm_source}&utm_term=#{utm_link.utm_term}")
      end
    end

    context "when target_resource_type is subscribe_page" do
      it "returns the seller's profile URL with UTM parameters" do
        utm_link = create(:utm_link, target_resource_type: :subscribe_page)

        expect(utm_link.utm_url).to eq("#{Rails.application.routes.url_helpers.custom_domain_subscribe_url(host: utm_link.seller.subdomain_with_protocol)}?utm_campaign=#{utm_link.utm_campaign}&utm_medium=#{utm_link.utm_medium}&utm_source=#{utm_link.utm_source}")
      end
    end

    context "when target_resource_type is product_page" do
      it "returns the product's long URL with UTM parameters" do
        product = create(:product)
        utm_link = create(:utm_link, target_resource_type: :product_page, target_resource_id: product.id, seller: product.user)

        expect(utm_link.utm_url).to eq("#{product.long_url}?utm_campaign=#{utm_link.utm_campaign}&utm_medium=#{utm_link.utm_medium}&utm_source=#{utm_link.utm_source}")
      end
    end

    context "when target_resource_type is post_page" do
      it "returns the post's full URL with UTM parameters" do
        post = create(:audience_post)
        utm_link = create(:utm_link, target_resource_type: :post_page, target_resource_id: post.id, seller: post.seller)

        expect(utm_link.utm_url).to eq("#{post.full_url}?utm_campaign=#{utm_link.utm_campaign}&utm_medium=#{utm_link.utm_medium}&utm_source=#{utm_link.utm_source}")
      end
    end
  end

  describe "#target_resource" do
    it "returns correct target resource" do
      seller = create(:user)

      product = create(:product, user: seller)
      utm_link = create(:utm_link, target_resource_type: :product_page, target_resource_id: product.id, seller:)
      expect(utm_link.target_resource).to eq(product)

      post = create(:audience_post, seller:)
      utm_link = create(:utm_link, target_resource_type: :post_page, target_resource_id: post.id, seller:)
      expect(utm_link.target_resource).to eq(post)

      utm_link = create(:utm_link, target_resource_type: :profile_page, seller:)
      expect(utm_link.target_resource).to be_nil

      utm_link = create(:utm_link, target_resource_type: :subscribe_page, seller:)
      expect(utm_link.target_resource).to be_nil
    end
  end

  describe "#default_title" do
    context "when target is product page" do
      let(:product) { create(:product, name: "My Product") }
      let(:utm_link) { build(:utm_link, target_resource_type: :product_page, target_resource_id: product.id) }

      it "returns appropriate title" do
        expect(utm_link.default_title).to eq("Product — My Product (auto-generated)")
      end
    end

    context "when target is post page" do
      let(:post) { create(:installment, name: "My Post") }
      let(:utm_link) { build(:utm_link, target_resource_type: :post_page, target_resource_id: post.id) }

      it "returns appropriate title" do
        expect(utm_link.default_title).to eq("Post — My Post (auto-generated)")
      end
    end

    context "when target is profile page" do
      let(:utm_link) { build(:utm_link) }

      it "returns appropriate title" do
        expect(utm_link.default_title).to eq("Profile page (auto-generated)")
      end
    end

    context "when target is subscribe page" do
      let(:utm_link) { build(:utm_link, target_resource_type: :subscribe_page) }

      it "returns appropriate title" do
        expect(utm_link.default_title).to eq("Subscribe page (auto-generated)")
      end
    end
  end

  describe ".generate_permalink" do
    it "generates an 8-character alphanumeric permalink" do
      permalink = described_class.generate_permalink
      expect(permalink).to match(/^[a-z0-9]{8}$/)
    end

    it "generates unique permalinks" do
      existing_permalink = described_class.generate_permalink
      create(:utm_link, permalink: existing_permalink)

      new_permalink = described_class.generate_permalink
      expect(new_permalink).not_to eq(existing_permalink)
    end

    it "retries until finding a unique permalink" do
      # Force the first two attempts to generate existing permalinks
      allow(SecureRandom).to receive(:alphanumeric).and_return(
        "existin1",
        "existin2",
        "unique12"
      )
      create(:utm_link, permalink: "existin1")
      create(:utm_link, permalink: "existin2")

      expect(described_class.generate_permalink).to eq("unique12")
      expect(SecureRandom).to have_received(:alphanumeric).exactly(3).times
    end

    it "raises an error after max retries" do
      allow(SecureRandom).to receive(:alphanumeric).and_return("existing")
      create(:utm_link, permalink: "existing")

      expect do
        described_class.generate_permalink(max_retries: 3)
      end.to raise_error("Failed to generate unique permalink after 3 attempts")
      expect(SecureRandom).to have_received(:alphanumeric).exactly(3).times
    end
  end

  describe ".polymorphic_class_for" do
    context "when target_resource_type is product_page" do
      it "returns Link" do
        expect(described_class.polymorphic_class_for("product_page")).to eq(Link)
      end
    end

    context "when target_resource_type is post_page" do
      it "returns Installment" do
        expect(described_class.polymorphic_class_for(:post_page)).to eq(Installment)
      end
    end

    context "when target_resource_type is profile_page" do
      it "returns nil" do
        expect(described_class.polymorphic_class_for(:profile_page)).to be_nil
      end
    end

    context "when target_resource_type is subscribe_page" do
      it "returns nil" do
        expect(described_class.polymorphic_class_for(:subscribe_page)).to be_nil
      end
    end
  end
end
