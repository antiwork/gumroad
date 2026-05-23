# frozen_string_literal: true

require "test_helper"

class QstValidationServiceTest < ActiveSupport::TestCase
  self.described_class = QstValidationService
  self.rspec_metadata = { vcr: true }



  context_ QstValidationService, :vcr do
    let(:qst_id) { "1002092821TQ0001" }

  test "returns true when a valid qst id is provided" do
      expect(described_class.new(qst_id).process).to be(true)
    end

  test "returns false when the qst id is nil" do
      expect(described_class.new(nil).process).to be(false)
    end

  test "returns false when the qst id is empty" do
      expect(described_class.new("").process).to be(false)
    end

  test "returns false when the format of the qst id is invalid" do
      expect(described_class.new("NR00005576").process).to be(false)
    end

  test "returns false when the qst id is not a registration number" do
      expect(described_class.new(qst_id.gsub("0001", "0002")).process).to be(false)
    end

  test "returns false when the qst id registration has been revoked or cancelled" do
      revoked_result = {
        "Resultat" => {
          "StatutSousDossierUsager" => "A", # This would be "R" if the QST ID represents a valid registration
          "DescriptionStatut" => "Regulier",
          "DateStatut" => "1992-07-01T00:00:00",
          "NomEntreprise" => "APPLE CANADA INC.",
          "RaisonSociale" => nil },
        "OperationReussie" => true,
        "MessagesFonctionnels" => [],
        "MessagesInformatifs" => []
      }
      revoked_response = instance_double(HTTParty::Response, code: 200, parsed_response: revoked_result)

      expect(HTTParty).to receive(:get).with("https://svcnab2b.revenuquebec.ca/2019/02/ValidationTVQ/#{qst_id}", timeout: 5).and_return(revoked_response)

      expect(described_class.new(qst_id).process).to be(false)
    end

  test "handles QST IDs that need encoding" do
      expect(described_class.new("needs encoding").process).to be(false)
    end
  end
end
