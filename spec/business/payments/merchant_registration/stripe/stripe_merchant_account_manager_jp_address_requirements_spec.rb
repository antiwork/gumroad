# frozen_string_literal: true

require "spec_helper"

# Stripe can hold a JP account disabled on a kanji/kana town it never accepted while our record
# still has that town unchanged, so a diff-only update never sends it again.
describe StripeMerchantAccountManager, "JP address fields Stripe still requires" do
  include_context "with Stripe API stubs"

  let(:passphrase) { GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD") }
  let(:user) { create(:user) }
  let!(:tos_agreement) { create(:tos_agreement, user:) }
  let(:jp_attributes) do
    {
      country: "Japan", state: "大阪府", zip_code: "530-0001", phone: "+81987654321",
      first_name_kanji: "日本語", last_name_kanji: "創造者", first_name_kana: "ニホンゴ", last_name_kana: "ソウゾウシャ",
      building_number: "1-1", building_number_kana: "1-1",
      street_address_kanji: "梅田", street_address_kana: "ウメダ"
    }
  end

  # Reads the account the shared stub created, so the metadata still names the record synced at creation.
  def stub_live_requirements(requirements, live_country = nil)
    merchant_id = user.stripe_account.charge_processor_merchant_id
    live = Stripe::Account.retrieve(merchant_id).to_hash.except(:requirements)
    live[:requirements] = requirements unless requirements == :absent
    live[:country] = live_country if live_country
    allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(Stripe::Account.construct_from(live))
  end

  def sent_entity(entity_key)
    sent = []
    allow(Stripe::Account).to receive(:update) do |account_id, params|
      sent << params
      Stripe::Account.construct_from(id: account_id, object: "account", metadata: {}, external_accounts: { object: "list", data: [] })
    end
    yield
    sent.filter_map { |params| params[entity_key] if params.is_a?(Hash) }.sole
  end

  context "with a JP individual" do
    let!(:bank_account) { create(:japan_bank_account, user:) }
    let!(:original_compliance_info) { create(:user_compliance_info, user:, **jp_attributes, city: "大阪市", city_kana: nil) }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
    end

    context "when the seller corrects only the city" do
      let!(:corrected_compliance_info) { create(:user_compliance_info, user:, **jp_attributes, city: "大阪市北区", city_kana: "オオサカシキタク") }

      it "re-sends the unchanged towns Stripe lists as past due alongside the changed city" do
        stub_live_requirements(
          "disabled_reason" => "requirements.past_due",
          "currently_due" => %w[individual.address_kana.town individual.address_kanji.town],
          "past_due" => %w[individual.address_kana.town individual.address_kanji.town]
        )

        individual = sent_entity(:individual) do
          described_class.handle_new_user_compliance_info(corrected_compliance_info)
        end

        expect(individual.except(:email, :phone)).to eq(
          address_kanji: { city: "大阪市北区", town: "梅田" },
          address_kana: { city: "オオサカシキタク", town: "ウメダ" }
        )
      end

      it "sends only the changed city when Stripe requires no address field" do
        stub_live_requirements("currently_due" => ["individual.verification.document"], "past_due" => ["individual.verification.document"])

        individual = sent_entity(:individual) do
          described_class.handle_new_user_compliance_info(corrected_compliance_info)
        end

        expect(individual.except(:email, :phone)).to eq(
          address_kanji: { city: "大阪市北区" },
          address_kana: { city: "オオサカシキタク" }
        )
      end

      it "still saves the city when Stripe rejects the re-sent town itself" do
        stub_live_requirements("past_due" => %w[individual.address_kana.town individual.address_kanji.town])
        sent = []
        allow(Stripe::Account).to receive(:update) do |account_id, params|
          sent << params
          if params.dig(:individual, :address_kanji, :town)
            raise Stripe::InvalidRequestError.new("Invalid address for Japan. We cannot find an address with town of 梅田 for postal_code 530-0001.", nil)
          end
          Stripe::Account.construct_from(id: account_id, object: "account", metadata: {}, external_accounts: { object: "list", data: [] })
        end

        expect { described_class.handle_new_user_compliance_info(corrected_compliance_info) }.not_to raise_error

        expect(sent.size).to eq(2)
        expect(sent.last[:individual].except(:email, :phone)).to eq(
          address_kanji: { city: "大阪市北区" },
          address_kana: { city: "オオサカシキタク" }
        )
        expect(sent.last.dig(:metadata, :user_compliance_info_id)).to eq(corrected_compliance_info.external_id)

        notes = user.comments.alive.with_type_payout_note
        expect(notes.where("content LIKE ?", "#{StripeMerchantAccountManager::ACCOUNT_REJECTION_NOTE_PREFIX}%").sole.content).to include("Invalid address for Japan")
        seller_notes = notes.select { |note| note.json_data[StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG] == true }
        expect(seller_notes.sole.content).to include("couldn't accept the address you entered")
      end

      it "keeps a forced identity re-send on the retry after Stripe rejects the re-sent town" do
        identity_note = user.add_payout_note(content: "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX} (individual): id_number")
        stub_live_requirements(
          "currently_due" => %w[individual.address_kana.town individual.address_kanji.town],
          "past_due" => %w[individual.address_kana.town individual.address_kanji.town]
        )
        sent = []
        allow(Stripe::Account).to receive(:update) do |account_id, params|
          sent << params
          if params.dig(:individual, :address_kanji, :town)
            raise Stripe::InvalidRequestError.new("Invalid address for Japan. We cannot find an address with town of 梅田 for postal_code 530-0001.", nil)
          end
          Stripe::Account.construct_from(id: account_id, object: "account", metadata: {}, external_accounts: { object: "list", data: [] })
        end

        described_class.handle_new_user_compliance_info(corrected_compliance_info)

        expect(sent.size).to eq(2)
        expect(sent.last[:individual].except(:email, :phone)).to eq(
          id_number: corrected_compliance_info.individual_tax_id.decrypt(passphrase),
          address_kanji: { city: "大阪市北区" },
          address_kana: { city: "オオサカシキタク" }
        )
        expect(identity_note.reload).not_to be_alive
      end
    end

    it "retries without the address when Stripe rejects a town that is the only field re-sent" do
      stub_live_requirements("currently_due" => ["individual.address_kanji.town"], "past_due" => ["individual.address_kanji.town"])
      sent = []
      allow(Stripe::Account).to receive(:update) do |account_id, params|
        sent << params
        if params.dig(:individual, :address_kanji, :town)
          raise Stripe::InvalidRequestError.new("Invalid address for Japan. We cannot find an address with town of 梅田 for postal_code 530-0001.", nil)
        end
        Stripe::Account.construct_from(id: account_id, object: "account", metadata: {}, external_accounts: { object: "list", data: [] })
      end

      described_class.handle_new_user_compliance_info(original_compliance_info)

      expect(sent.size).to eq(2)
      expect(sent.last[:individual].except(:email, :phone)).to be_empty
    end

    it "surfaces Stripe's rejection of a town the seller changed, without a retry" do
      changed_town = create(:user_compliance_info, user:, **jp_attributes, city: "大阪市", city_kana: nil, street_address_kanji: "茶屋町")
      stub_live_requirements("past_due" => ["individual.address_kanji.town"])
      sent = []
      allow(Stripe::Account).to receive(:update) do |_account_id, params|
        sent << params
        raise Stripe::InvalidRequestError.new("Invalid address for Japan. We cannot find an address with town of 茶屋町 for postal_code 530-0001.", nil)
      end

      expect { described_class.handle_new_user_compliance_info(changed_town) }.to raise_error(Stripe::InvalidRequestError, /Invalid address for Japan/)
      expect(sent.size).to eq(1)
    end

    it "does not re-send kanji or kana fields to an account Stripe does not hold as Japanese" do
      stub_live_requirements({ "past_due" => %w[individual.address_kana.town individual.address_kanji.town] }, "US")

      individual = sent_entity(:individual) do
        described_class.handle_new_user_compliance_info(original_compliance_info)
      end

      expect(individual.except(:email, :phone)).to be_empty
    end

    it "re-sends a currently due town on a save that changes no address field" do
      stub_live_requirements("currently_due" => ["individual.address_kanji.town"], "past_due" => [])

      individual = sent_entity(:individual) do
        described_class.handle_new_user_compliance_info(original_compliance_info)
      end

      expect(individual.except(:email, :phone)).to eq(address_kanji: { town: "梅田" })
    end

    it "does not send a blank for a due field the record does not hold" do
      stub_live_requirements("past_due" => %w[individual.address_kana.city individual.address_kanji.town])

      individual = sent_entity(:individual) do
        described_class.handle_new_user_compliance_info(original_compliance_info)
      end

      expect(individual.except(:email, :phone)).to eq(address_kanji: { town: "梅田" })
    end

    it "leaves a town alone while a postal-code rejection is outstanding" do
      note = user.add_payout_note(
        content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — The postal code you entered is not valid."
      )
      stub_live_requirements("past_due" => %w[individual.address_kana.town individual.address_kanji.town])

      individual = sent_entity(:individual) do
        described_class.handle_new_user_compliance_info(original_compliance_info)
      end

      expect(individual.except(:email, :phone)).to be_empty
      expect(note.reload).to be_alive
    end

    [
      [:absent, "requirements are absent"],
      [nil, "requirements are null"],
      [{ "currently_due" => nil, "past_due" => nil }, "the due lists are null"],
      [
        {
          "past_due" => [nil, 7, "individual.address_kanji", "individual.address_kanji.town.extra",
                         "company.address_kanji.town", "individual.address.line1"]
        },
        "the due lists hold no individual kanji or kana field"
      ],
    ].each do |requirements, description|
      it "sends no address field when #{description}" do
        stub_live_requirements(requirements)

        individual = sent_entity(:individual) do
          described_class.handle_new_user_compliance_info(original_compliance_info)
        end

        expect(individual.except(:email, :phone)).to be_empty
      end
    end
  end

  context "with a non-JP individual" do
    let!(:bank_account) { create(:ach_account, user:) }
    let!(:compliance_info) { create(:user_compliance_info, user:) }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
    end

    it "keeps an unchanged address out of the diff even when Stripe lists it as past due" do
      stub_live_requirements("past_due" => %w[individual.address.line1 individual.address.city])

      individual = sent_entity(:individual) do
        described_class.handle_new_user_compliance_info(compliance_info)
      end

      expect(individual).not_to have_key(:address)
    end
  end

  context "with a JP company" do
    let!(:bank_account) { create(:japan_bank_account, user:) }
    let!(:compliance_info) do
      create(:user_compliance_info_business, user:, **jp_attributes, city: "大阪市",
                                             business_country: "Japan", business_state: "大阪府", business_zip_code: "530-0001",
                                             business_city: "大阪市北区", business_building_number: "1-1",
                                             business_street_address_kanji: "梅田", business_name_kanji: "株式会社買う")
    end

    before do
      described_class.create_account(user, passphrase:)
      user.reload
    end

    it "re-sends the company town Stripe lists as past due" do
      stub_live_requirements("past_due" => ["company.address_kanji.town"])

      company = sent_entity(:company) do
        described_class.handle_new_user_compliance_info(compliance_info)
      end

      expect(company[:address_kanji]).to eq(town: "梅田")
      expect(company).not_to have_key(:address_kana)
    end
  end
end
