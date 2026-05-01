# frozen_string_literal: true

class UpdateUserComplianceInfo
  COUNTRIES_REQUIRING_PHYSICAL_ADDRESS = {
    "US" => "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.",
    "GH" => "We require a valid physical address in Ghana. We cannot accept a P.O. Box as a valid address.",
  }.freeze
  ADDRESS_FIELDS_AND_COUNTRY_FALLBACKS = {
    street_address: [:country],
    business_street_address: [:business_country, :country],
  }.freeze

  attr_reader :compliance_params, :user

  def initialize(compliance_params:, user:)
    @compliance_params = compliance_params
    @user = user
  end

  MAX_ENCRYPTED_FIELD_LENGTH = 200
  ENCRYPTED_FIELD_LABELS = {
    individual_tax_id: "Individual tax id",
    ssn_last_four: "Individual tax id",
    business_tax_id: "Business tax id",
  }.freeze

  def process
    if compliance_params.present?
      po_box_error = po_box_error_message
      return { success: false, error_message: po_box_error } if po_box_error.present?

      ENCRYPTED_FIELD_LABELS.each do |field, label|
        value = compliance_params[field]
        next if value.blank?
        if value.to_s.length > MAX_ENCRYPTED_FIELD_LENGTH
          return { success: false, error_message: "#{label} is too long" }
        end
      end

      old_compliance_info = current_compliance_info
      saved, new_compliance_info = old_compliance_info.dup_and_save do |new_compliance_info|
        # if the following fields are submitted and are blank, we don't clear the field for the user
        new_compliance_info.first_name =              compliance_params[:first_name]              if compliance_params[:first_name].present?
        new_compliance_info.last_name =               compliance_params[:last_name]               if compliance_params[:last_name].present?
        new_compliance_info.first_name_kanji =        compliance_params[:first_name_kanji]        if compliance_params[:first_name_kanji].present?
        new_compliance_info.last_name_kanji =         compliance_params[:last_name_kanji]         if compliance_params[:last_name_kanji].present?
        new_compliance_info.first_name_kana =         compliance_params[:first_name_kana]         if compliance_params[:first_name_kana].present?
        new_compliance_info.last_name_kana =          compliance_params[:last_name_kana]          if compliance_params[:last_name_kana].present?
        new_compliance_info.street_address =          compliance_params[:street_address]          if compliance_params[:street_address].present?
        new_compliance_info.building_number =         compliance_params[:building_number]         if compliance_params[:building_number].present?
        new_compliance_info.building_number_kana =    compliance_params[:building_number_kana]    if compliance_params[:building_number_kana].present?
        new_compliance_info.street_address_kanji =    compliance_params[:street_address_kanji]    if compliance_params[:street_address_kanji].present?
        new_compliance_info.street_address_kana =     compliance_params[:street_address_kana]     if compliance_params[:street_address_kana].present?
        new_compliance_info.city =                    compliance_params[:city]                    if compliance_params[:city].present?
        new_compliance_info.state =                   compliance_params[:state]                   if compliance_params[:state].present?
        new_compliance_info.country =                 Compliance::Countries.mapping[compliance_params[:country]] if compliance_params[:country].present? && compliance_params[:is_business]
        new_compliance_info.zip_code =                compliance_params[:zip_code]                if compliance_params[:zip_code].present?
        new_compliance_info.business_name =           compliance_params[:business_name]           if compliance_params[:business_name].present?
        new_compliance_info.business_name_kanji =     compliance_params[:business_name_kanji]     if compliance_params[:business_name_kanji].present?
        new_compliance_info.business_name_kana =      compliance_params[:business_name_kana]      if compliance_params[:business_name_kana].present?
        new_compliance_info.business_street_address = compliance_params[:business_street_address] if compliance_params[:business_street_address].present?
        new_compliance_info.business_building_number =      compliance_params[:business_building_number]      if compliance_params[:business_building_number].present?
        new_compliance_info.business_building_number_kana = compliance_params[:business_building_number_kana] if compliance_params[:business_building_number_kana].present?
        new_compliance_info.business_street_address_kanji = compliance_params[:business_street_address_kanji] if compliance_params[:business_street_address_kanji].present?
        new_compliance_info.business_street_address_kana =  compliance_params[:business_street_address_kana]  if compliance_params[:business_street_address_kana].present?
        new_compliance_info.business_city =           compliance_params[:business_city]           if compliance_params[:business_city].present?
        new_compliance_info.business_state =          compliance_params[:business_state]          if compliance_params[:business_state].present?
        new_compliance_info.business_country =        Compliance::Countries.mapping[compliance_params[:business_country]] if compliance_params[:business_country].present? && compliance_params[:is_business]
        new_compliance_info.business_zip_code =       compliance_params[:business_zip_code]       if compliance_params[:business_zip_code].present?
        new_compliance_info.business_type =           compliance_params[:business_type]           if compliance_params[:business_type].present?
        new_compliance_info.is_business =             compliance_params[:is_business]             unless compliance_params[:is_business].nil?
        new_compliance_info.individual_tax_id =       compliance_params[:ssn_last_four]           if compliance_params[:ssn_last_four].present?
        new_compliance_info.individual_tax_id =       compliance_params[:individual_tax_id]       if compliance_params[:individual_tax_id].present?
        if compliance_params[:business_tax_id].present?
          new_compliance_info.business_tax_id = compliance_params[:business_tax_id].gsub(/\D/, "")
        end
        new_compliance_info.birthday = Date.new(compliance_params[:dob_year].to_i, compliance_params[:dob_month].to_i, compliance_params[:dob_day].to_i) if compliance_params[:dob_year].present? && compliance_params[:dob_year].to_i > 0
        new_compliance_info.skip_stripe_job_on_create = true
        new_compliance_info.phone =                   compliance_params[:phone]                   if compliance_params[:phone].present?
        new_compliance_info.business_phone =          compliance_params[:business_phone]          if compliance_params[:business_phone].present?
        new_compliance_info.job_title =               compliance_params[:job_title]               if compliance_params[:job_title].present?
        new_compliance_info.nationality =             compliance_params[:nationality]             if compliance_params[:nationality].present?
        new_compliance_info.business_vat_id_number =  compliance_params[:business_vat_id_number]  if compliance_params[:business_vat_id_number].present?
      end

      return { success: false, error_message: new_compliance_info.errors.full_messages.to_sentence } unless saved

      if new_compliance_info.is_business && new_compliance_info.legal_entity_country_code == "US" &&
          compliance_params[:business_tax_id].present? && new_compliance_info.business_tax_id.length != 9
        return { success: false, error_message: "US business tax IDs (EIN) must have 9 digits." }
      end

      begin
        StripeMerchantAccountManager.handle_new_user_compliance_info(new_compliance_info)
      rescue Stripe::InvalidRequestError => e
        if e.code == "postal_code_invalid"
          country = new_compliance_info.legal_entity_country
          return { success: false, error_message: "The postal code you entered is not valid for #{country}." }
        end
        return { success: false, error_message: e.message.split("Please contact us").first.strip }
      end
    end

    { success: true }
  end

  private
    def po_box_error_message
      ADDRESS_FIELDS_AND_COUNTRY_FALLBACKS.each_key do |address_field|
        next unless should_validate_po_box_for?(address_field)

        address = address_for_validation(address_field)
        next unless po_box_address?(address)

        country_code = effective_country_code_for(address_field)
        next if country_code.blank?
        next unless COUNTRIES_REQUIRING_PHYSICAL_ADDRESS.key?(country_code)

        return COUNTRIES_REQUIRING_PHYSICAL_ADDRESS.fetch(country_code)
      end

      nil
    end

    def should_validate_po_box_for?(address_field)
      address = address_for_validation(address_field)
      return false if address.blank?

      address_changed?(address_field) || validation_context_changed_for?(address_field)
    end

    def address_for_validation(address_field)
      compliance_params[address_field].presence || stored_address_for_validation(address_field)
    end

    def address_changed?(address_field)
      compliance_params[address_field].present? &&
        compliance_params[address_field].to_s != current_compliance_info.public_send(address_field).to_s
    end

    def stored_address_for_validation(address_field)
      return unless validation_context_changed_for?(address_field)

      current_compliance_info.public_send(address_field).presence
    end

    def validation_context_changed_for?(address_field)
      country_changed_for?(address_field) || business_mode_changed_for?(address_field)
    end

    def business_mode_changed_for?(address_field)
      return business_mode_changed? if address_field == :street_address

      business_mode_activating? if address_field == :business_street_address
    end

    def country_changed_for?(address_field)
      effective_country_code_for(address_field) != current_country_code_for(address_field)
    end

    def effective_country_code_for(address_field)
      country_code_for(
        ADDRESS_FIELDS_AND_COUNTRY_FALLBACKS.fetch(address_field).filter_map { |field| effective_country_value_for(field) }.first
      )
    end

    def current_country_code_for(address_field)
      country_code_for(
        ADDRESS_FIELDS_AND_COUNTRY_FALLBACKS.fetch(address_field).filter_map { |field| current_compliance_info.public_send(field) }.first
      )
    end

    def country_code_for(country)
      return if country.blank?

      Compliance::Countries.find_by_name(country)&.alpha2 || country
    end

    def effective_country_value_for(field)
      current_country = current_compliance_info.public_send(field)
      return current_country unless submitted_country_will_be_persisted?(field)

      Compliance::Countries.mapping[compliance_params[field]].presence || current_country
    end

    def po_box_address?(address)
      address.gsub(/[^\w]/, "").downcase.include?("pobox")
    end

    def business_mode_changed?
      effective_is_business? != current_compliance_info.is_business?
    end

    def business_mode_activating?
      !current_compliance_info.is_business? && effective_is_business?
    end

    def effective_is_business?
      return current_compliance_info.is_business? if compliance_params[:is_business].nil?

      ActiveModel::Type::Boolean.new.cast(compliance_params[:is_business])
    end

    def current_compliance_info
      @current_compliance_info ||= user.fetch_or_build_user_compliance_info
    end

    def submitted_country_will_be_persisted?(field)
      compliance_params[field].present? && compliance_params[:is_business]
    end
end
