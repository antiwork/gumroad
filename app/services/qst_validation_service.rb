# frozen_string_literal: true

class QstValidationService
  attr_reader :qst_id

  def initialize(qst_id)
    @qst_id = qst_id
  end

  def process
    return false if qst_id.blank?

    Rails.cache.fetch("revenu_quebec_validation_#{qst_id}", expires_in: 10.minutes) do
      valid_qst?
    end
  end

  private
    QST_VALIDATION_ENDPOINT_TEMPLATE = Addressable::Template.new(
      "https://svcnab2b.revenuquebec.ca/2019/02/ValidationTVQ/{qst_id}"
    )

    def valid_qst?
      response = HTTParty.get(QST_VALIDATION_ENDPOINT_TEMPLATE.expand(qst_id:).to_s, timeout: 5)
      response.code == 200 && response.parsed_response.dig("Resultat", "StatutSousDossierUsager") == "R"
    end
end
