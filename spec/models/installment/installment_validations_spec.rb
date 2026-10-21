# frozen_string_literal: true

require "spec_helper"

describe "InstallmentValidations" do
  describe "#validate_sending_limit_for_sellers" do
    before do
      stub_const("Installment::SENDING_LIMIT", 2)
      @seller = create(:user)
      @installment = build(:installment, seller: @seller)
    end

    context "when seller is sending less than 100 emails" do
      it "returns true" do
        expect(@installment.valid?).to eq true
        expect(@installment.errors.full_messages).to eq []
      end
    end

    context "when seller has less than $100 revenue" do
      it "allows to delete the post that was sent to more than 100 email addresses" do
        @installment.save!
        allow(@installment).to receive(:audience_members_count).and_return(Installment::SENDING_LIMIT + 1)

        expect do
          @installment.mark_deleted!
        end.to change { Installment.alive.count }.by(-1)
      end
    end

    context "when seller is sending more than 100 emails" do
      context "when seller has less than $100 sales" do
        it "returns minimum sales error" do
          allow(@installment).to receive(:audience_members_count).and_return(Installment::SENDING_LIMIT + 1)

          expect(@installment.valid?).to eq false
          expect(@installment.errors.full_messages.to_sentence).to eq("<a href='/help/article/269-balance-page' target='_blank' rel='noreferrer'>Sorry, you cannot send out more than 2 emails until you have $100 in total earnings.</a>")
        end

        context "for an abandoned cart workflow installment" do
          it "returns true with no errors" do
            @installment.installment_type = Installment::ABANDONED_CART_TYPE
            allow(@installment).to receive(:audience_members_count).and_return(Installment::SENDING_LIMIT + 1)

            expect(@installment).to be_valid
            expect(@installment.errors.size).to eq(0)
          end
        end
      end

      context "when seller has $100 sales" do
        it "returns true with no errors" do
          allow(@seller).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
          allow(@installment).to receive(:audience_members_count).and_return(Installment::SENDING_LIMIT + 1)

          expect(@installment.valid?).to eq true
          expect(@installment.errors.full_messages).to eq []
        end
      end

      context "when seller has an email sending override" do
        before do
          parent = create(:user, verified: true)
          create(:payment_completed, user: parent)
          create(:team_membership, user: parent, seller: @seller, role: TeamMembership::ROLE_ADMIN)
          @seller.grant_email_sending_override!(parent:, author: create(:admin_user))
        end

        it "returns true with no errors despite having less than $100 sales" do
          installment = build(:installment, seller: @seller)
          allow(installment).to receive(:audience_members_count).and_return(Installment::SENDING_LIMIT + 1)

          expect(installment).to be_valid
          expect(installment.errors.full_messages).to eq []
        end

        it "returns minimum sales error when the seller is flagged" do
          @seller.flag_for_fraud(author_id: create(:admin_user).id)
          installment = build(:installment, seller: @seller)
          allow(installment).to receive(:audience_members_count).and_return(Installment::SENDING_LIMIT + 1)

          expect(installment.valid?).to eq false
          expect(installment.errors.full_messages.to_sentence).to include("you cannot send out more than 2 emails")
        end
      end
    end

    context "with an email sending override and a real audience over the limit" do
      let(:brand) { create(:user) }
      let(:parent) { create(:user, verified: true) }
      let(:admin_user) { create(:admin_user) }
      let(:sending_limit_error) { "Sorry, you cannot send out more than #{Installment::SENDING_LIMIT} emails" }

      before do
        stub_const("Installment::SENDING_LIMIT", 100)
        create(:team_membership, user: parent, seller: brand, role: TeamMembership::ROLE_ADMIN)
        create(:payment_completed, user: parent)
        create_list(:audience_member, Installment::SENDING_LIMIT + 1, seller: brand, follower: {})
        index_model_records(AudienceMember)
      end

      it "saves a post from a brand whose override is active" do
        brand.grant_email_sending_override!(parent:, author: admin_user)
        post = build(:audience_installment, seller: brand)

        expect(post.audience_members_count(Installment::SENDING_LIMIT + 1)).to eq(Installment::SENDING_LIMIT + 1)
        expect(post.save).to eq(true)
      end

      it "skips the audience and sales searches for a brand whose override is active" do
        brand.grant_email_sending_override!(parent:, author: admin_user)
        post = build(:audience_installment, seller: brand)
        allow(AudienceMember).to receive(:filter_count).and_call_original
        allow(post.user).to receive(:sales_cents_total).and_call_original

        expect(post).to be_valid
        expect(AudienceMember).not_to have_received(:filter_count)
        expect(post.user).not_to have_received(:sales_cents_total)
      end

      it "still runs the audience and sales searches for a raw override without a qualifying parent" do
        brand.update!(email_sending_override: true)
        post = build(:audience_installment, seller: brand)
        allow(AudienceMember).to receive(:filter_count).and_call_original
        allow(post.user).to receive(:sales_cents_total).and_call_original

        expect(post).not_to be_valid
        expect(AudienceMember).to have_received(:filter_count)
        expect(post.user).to have_received(:sales_cents_total)
      end

      it "keeps the limit for a raw override without a qualifying parent" do
        brand.update!(email_sending_override: true)
        post = build(:audience_installment, seller: brand)

        expect(post.save).to eq(false)
        expect(post.errors.full_messages.to_sentence).to include(sending_limit_error)
      end

      it "keeps the limit once the override is revoked" do
        brand.grant_email_sending_override!(parent:, author: admin_user)
        brand.revoke_email_sending_override!(author: admin_user)
        post = build(:audience_installment, seller: brand.reload)

        expect(post.save).to eq(false)
        expect(post.errors.full_messages.to_sentence).to include(sending_limit_error)
      end

      it "keeps the limit for a seller without an override" do
        post = build(:audience_installment, seller: brand)

        expect(post.save).to eq(false)
        expect(post.errors.full_messages.to_sentence).to include(sending_limit_error)
      end
    end
  end

  describe "field validations" do
    it "when name is longer than 255 characters" do
      installment = build(:installment, name: "a" * 256)
      expect(installment.valid?).to eq false
      expect(installment.errors.messages).to eq(
        name: ["is too long (maximum is 255 characters)"]
                                             )
    end

    it "disallows records with no message" do
      installment = build(:installment, name: "installment1", message: nil, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/myfile.jpeg", link: create(:product))
      expect(installment).to_not be_valid
    end

    it "disallows records with empty HTML-only message content" do
      installment = build(
        :installment,
        name: "installment1",
        message: "<p><br></p>",
        link: create(:product),
        send_emails: true
      )

      expect(installment).not_to be_valid
      expect(installment.errors.full_messages).to include("Please include a message as part of the update.")
    end
  end

  describe "#shown_on_profile_only_for_confirmed_users" do
    it "allows creating, updating, and deleting non-profile posts belonging to unconfirmed users" do
      product = create(:product, user: create(:unconfirmed_user))
      post = create(:installment, link: product)
      expect(post).to be_valid

      post = create(:installment, shown_on_profile: true)
      post.seller.update!(confirmed_at: nil)
      post.update!(shown_on_profile: false)
      expect(post).to be_valid

      expect { post.destroy! }.not_to(raise_error)
    end

    it "disallows creating profile posts by unconfirmed users" do
      product = create(:product, user: create(:unconfirmed_user))
      post = build(:installment, link: product, shown_on_profile: true)

      expect(post).not_to be_valid
      expect(post.errors.full_messages).to include "Please confirm your email before creating a public post."
    end

    it "disallows updating a post to be a profile post belonging to an unconfirmed user" do
      product = create(:product, user: create(:unconfirmed_user))
      post = create(:installment, link: product)
      expect(post).to be_valid

      post.update(shown_on_profile: true)
      expect(post).not_to be_valid
      expect(post.errors.full_messages).to include "Please confirm your email before creating a public post."
    end

    it "allows soft-deleting a profile post belonging to an unconfirmed user" do
      post = create(:installment, shown_on_profile: true)
      post.seller.update!(confirmed_at: nil)

      expect { post.mark_deleted! }.not_to(raise_error)
    end

    it "allows deleting a profile post belonging to an unconfirmed user" do
      post = create(:installment, shown_on_profile: true)
      post.seller.update!(confirmed_at: nil)

      expect { post.destroy! }.not_to(raise_error)
    end

    it "allows creating, updating, and deleting profile posts belonging to confirmed users" do
      post = create(:installment, shown_on_profile: true)
      expect(post).to be_valid

      post = create(:installment)
      post.update!(shown_on_profile: true)
      expect(post).to be_valid

      expect { post.destroy! }.not_to(raise_error)
    end
  end

  describe "#published_at_cannot_be_in_the_future" do
    before do
      @post = build(:installment, name: "sample name", message: "sample message")
    end

    it "allows published_at to be nil" do
      expect(@post.published_at).to be_nil
      expect(@post).to be_valid
    end

    it "allows published_at to be in the past" do
      @post.published_at = Time.current
      expect(@post).to be_valid
    end

    it "disallows published_at to be in the future" do
      @post.published_at = 1.minute.from_now
      expect(@post).not_to be_valid
      expect(@post.errors.full_messages).to include("Please enter a publish date in the past.")
    end
  end
end
