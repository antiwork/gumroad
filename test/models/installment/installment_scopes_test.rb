# frozen_string_literal: true

require "test_helper"

class ModelsInstallmentInstallmentScopesTest < ActiveSupport::TestCase



  context_ "InstallmentScopes"  do
    before do
      @creator = create(:named_user, :with_avatar)
      @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
    end

  context_ ".shown_on_profile" do
      before do
        @installment1 = create(:installment, shown_on_profile: true, send_emails: false)
        @installment2 = create(:installment, shown_on_profile: true, send_emails: true)
        create(:installment)
      end

  test "returns installments shown on profile" do
        Installment.shown_on_profile.tap do |installments|
          expect(installments.count).to eq(2)
          expect(installments).to contain_exactly(@installment1, @installment2)
        end
      end
    end

  context_ ".profile_only" do
      before do
        @installment = create(:installment, shown_on_profile: true, send_emails: false)
        create(:installment, shown_on_profile: false, send_emails: true)
      end

  test "returns installments shown only on profile" do
        Installment.profile_only.tap do |installments|
          expect(installments.count).to eq(1)
          expect(installments).to contain_exactly(@installment)
        end
      end
    end

  context_ ".published" do
      let!(:published_installement) { create(:published_installment) }
      let!(:not_published_installement) { create(:installment) }

  test "returns published installments" do
        result = Installment.published
        expect(result).to include(published_installement)
        expect(result).not_to include(not_published_installement)
      end
    end

  context_ ".not_published" do
      let!(:published_installement) { create(:published_installment) }
      let!(:not_published_installement) { create(:installment) }

  test "returns unpublished installments" do
        result = Installment.not_published
        expect(result).to include(not_published_installement)
        expect(result).not_to include(published_installement)
      end
    end

  context_ ".scheduled" do
      let!(:published_installment) { create(:published_installment) }
      let!(:scheduled_installment) { create(:scheduled_installment) }
      let!(:drafts_installment) { create(:installment) }

  test "returns scheduled installments" do
        result = Installment.scheduled
        expect(result).to include(scheduled_installment)
        expect(result).not_to include(published_installment, drafts_installment)
      end
    end

  context_ ".draft" do
      let!(:published_installment) { create(:published_installment) }
      let!(:scheduled_installment) { create(:scheduled_installment) }
      let!(:drafts_installment) { create(:installment) }

  test "returns draft installments" do
        result = Installment.draft
        expect(result).to include(drafts_installment)
        expect(result).not_to include(published_installment, scheduled_installment)
      end
    end
  end
end
