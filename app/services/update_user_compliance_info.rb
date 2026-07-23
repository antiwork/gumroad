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
  # The fields that make up a Japanese address, including the city pair and the prefecture
  # (state) / postal code — changing only the prefecture or postal code still re-syncs the
  # address to Stripe, so it must count as an address change. A submission is treated
  # as (re)entering the Japanese address only when one of these fields actually CHANGES compared
  # to the stored record — the Payments settings form echoes back every stored field on save, so
  # a value merely being present does not mean the seller touched their address. Older records
  # can still update unrelated fields (phone, payout frequency, ...) without a city — many legacy
  # Japanese records were created before the form collected one, and blocking every save until
  # they re-enter their address would strand them.
  JAPAN_INDIVIDUAL_ADDRESS_FIELDS = %i[building_number building_number_kana street_address_kanji street_address_kana city city_kana state zip_code].freeze
  JAPAN_BUSINESS_ADDRESS_FIELDS = %i[business_building_number business_building_number_kana business_street_address_kanji business_street_address_kana business_city business_city_kana business_state business_zip_code].freeze

  attr_reader :compliance_params, :user

  def initialize(compliance_params:, user:)
    @compliance_params = compliance_params
    @user = user
  end

  MAX_ENCRYPTED_FIELD_LENGTH = 200
  MASKED_TAX_ID_PATTERN = /[\u2022*]/
  PERU_DNI_DIGIT_COUNT = 9
  # A Singapore NRIC/FIN is a leading letter (S/T for citizens and permanent residents,
  # F/G/M for foreigners), seven digits, and a trailing checksum letter — e.g. S1234567A.
  # Stripe verifies the full string, so a value missing the leading letter (only digits +
  # checksum) saves fine on our side but fails Stripe verification forever with a generic
  # "id_number mismatch" the seller cannot see or fix. Validate the shape up front so the
  # seller gets an actionable error at save time instead. Case-insensitive: Stripe accepts
  # lowercase, so we don't reject it.
  SINGAPORE_NRIC_FIN_PATTERN = /\A[STFGM]\d{7}[A-Z]\z/i
  ENCRYPTED_FIELD_LABELS = {
    individual_tax_id: "Individual tax id",
    ssn_last_four: "Individual tax id",
    business_tax_id: "Business tax id",
  }.freeze
  SIMPLE_COMPLIANCE_INFO_FIELDS = %i[
    first_name
    last_name
    first_name_kanji
    last_name_kanji
    first_name_kana
    last_name_kana
    street_address
    building_number
    building_number_kana
    street_address_kanji
    street_address_kana
    city
    city_kana
    state
    zip_code
    business_name
    business_name_kanji
    business_name_kana
    business_street_address
    business_building_number
    business_building_number_kana
    business_street_address_kanji
    business_street_address_kana
    business_city
    business_city_kana
    business_state
    business_zip_code
    business_type
    phone
    business_phone
    job_title
    nationality
    business_vat_id_number
  ].freeze
  ENCRYPTED_COMPLIANCE_INFO_FIELDS = %i[individual_tax_id business_tax_id].freeze

  def process
    if compliance_params.present?
      po_box_error = po_box_error_message
      return { success: false, error_message: po_box_error } if po_box_error.present?

      japan_city_error = japan_city_error_message
      return { success: false, error_message: japan_city_error } if japan_city_error.present?

      ENCRYPTED_FIELD_LABELS.each do |field, label|
        value = compliance_params[field]
        next if value.blank?
        if value.to_s.length > MAX_ENCRYPTED_FIELD_LENGTH
          return { success: false, error_message: "#{label} is too long" }
        end
      end

      old_compliance_info = current_compliance_info
      compliance_info_changed = compliance_info_changed?(old_compliance_info)
      old_compliance_info.reload if old_compliance_info.persisted? && encrypted_compliance_info_params_present?
      unless compliance_info_changed
        UserComplianceInfoRequest.handle_new_user_compliance_info(old_compliance_info)
        return { success: true }
      end

      peru_dni_error = peru_individual_dni_error(old_compliance_info)
      return { success: false, error_message: peru_dni_error } if peru_dni_error

      singapore_nric_error = singapore_individual_nric_error(old_compliance_info)
      return { success: false, error_message: singapore_nric_error } if singapore_nric_error

      saved, new_compliance_info = if encrypted_compliance_info_params_present?
        dup_and_save_compliance_info(old_compliance_info)
      else
        old_compliance_info.dup_and_save do |new_compliance_info|
          assign_compliance_params(new_compliance_info)
        end
      end

      return { success: false, error_message: new_compliance_info.errors.full_messages.to_sentence } unless saved

      if new_compliance_info.is_business && new_compliance_info.legal_entity_country_code == "US" &&
          submitted_tax_id_for(:business_tax_id).present? && new_compliance_info.business_tax_id.length != 9
        return { success: false, error_message: "US business tax IDs (EIN) must have 9 digits." }
      end

      begin
        StripeMerchantAccountManager.handle_new_user_compliance_info(new_compliance_info)
      rescue Stripe::InvalidRequestError => e
        if e.code == "postal_code_invalid"
          country = new_compliance_info.legal_entity_country
          weeks = RetryStripeRejectedPayoutSetupsJob::RETRY_WINDOW_WEEKS
          return { success: false, error_message: "We couldn't verify the postal code you entered for #{country}. Please double-check it — but if you're sure it's correct (for example, a newly built address), you don't need to do anything. New postal codes can take a few days to a few weeks to reach our payment partner's records, so we'll automatically re-check yours once a week for up to #{weeks} weeks, and only reach out if we still can't verify it." }
        end
        return { success: false, error_message: e.message.split("Please contact us").first.strip }
      end
    end

    { success: true }
  end

  private
    def assign_compliance_params(new_compliance_info)
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
      new_compliance_info.city_kana =               compliance_params[:city_kana]               if compliance_params[:city_kana].present?
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
      new_compliance_info.business_city_kana =      compliance_params[:business_city_kana]      if compliance_params[:business_city_kana].present?
      new_compliance_info.business_state =          compliance_params[:business_state]          if compliance_params[:business_state].present?
      new_compliance_info.business_country =        Compliance::Countries.mapping[compliance_params[:business_country]] if compliance_params[:business_country].present? && compliance_params[:is_business]
      new_compliance_info.business_zip_code =       compliance_params[:business_zip_code]       if compliance_params[:business_zip_code].present?
      new_compliance_info.business_type =           compliance_params[:business_type]           if compliance_params[:business_type].present?
      new_compliance_info.is_business =             compliance_params[:is_business]             unless compliance_params[:is_business].nil?
      new_compliance_info.individual_tax_id =       normalize_individual_tax_id(submitted_tax_id_for(:ssn_last_four))     if submitted_tax_id_for(:ssn_last_four).present?
      new_compliance_info.individual_tax_id =       normalize_individual_tax_id(submitted_tax_id_for(:individual_tax_id)) if submitted_tax_id_for(:individual_tax_id).present?
      if submitted_tax_id_for(:business_tax_id).present?
        new_compliance_info.business_tax_id = normalize_business_tax_id(
          submitted_tax_id_for(:business_tax_id),
          country_code: new_compliance_info.legal_entity_country_code,
        )
      end
      new_compliance_info.birthday = Date.new(compliance_params[:dob_year].to_i, compliance_params[:dob_month].to_i, compliance_params[:dob_day].to_i) if compliance_params[:dob_year].present? && compliance_params[:dob_year].to_i > 0
      new_compliance_info.skip_stripe_job_on_create = true
      new_compliance_info.phone =                   compliance_params[:phone]                   if compliance_params[:phone].present?
      new_compliance_info.business_phone =          compliance_params[:business_phone]          if compliance_params[:business_phone].present?
      new_compliance_info.job_title =               compliance_params[:job_title]               if compliance_params[:job_title].present?
      new_compliance_info.nationality =             compliance_params[:nationality]             if compliance_params[:nationality].present?
      new_compliance_info.business_vat_id_number =  compliance_params[:business_vat_id_number]  if compliance_params[:business_vat_id_number].present?
    end

    def dup_and_save_compliance_info(old_compliance_info)
      new_compliance_info = build_compliance_info_copy(old_compliance_info)
      saved = nil

      ActiveRecord::Base.transaction do
        assign_compliance_params(new_compliance_info)
        saved = old_compliance_info.mark_deleted(validate: false)
        raise ActiveRecord::Rollback unless saved
        saved = new_compliance_info.save
        raise ActiveRecord::Rollback unless saved
      end

      [saved, new_compliance_info]
    end

    def build_compliance_info_copy(old_compliance_info)
      new_compliance_info = old_compliance_info.class.new(
        old_compliance_info.attributes.except("id", "created_at", "updated_at", "deleted_at", *ENCRYPTED_COMPLIANCE_INFO_FIELDS.map(&:to_s))
      )
      ENCRYPTED_COMPLIANCE_INFO_FIELDS.each do |field|
        value = encrypted_compliance_info_value(old_compliance_info, field)
        new_compliance_info.public_send("#{field}=", value) if value.present?
      end
      new_compliance_info
    end

    def compliance_info_changed?(old_compliance_info)
      simple_compliance_info_changed?(old_compliance_info) ||
        country_changed?(old_compliance_info, :country) ||
        country_changed?(old_compliance_info, :business_country) ||
        business_mode_param_changed?(old_compliance_info) ||
        birthday_changed?(old_compliance_info) ||
        encrypted_compliance_info_changed?(old_compliance_info)
    end

    def simple_compliance_info_changed?(old_compliance_info)
      SIMPLE_COMPLIANCE_INFO_FIELDS.any? do |field|
        compliance_params[field].present? && compliance_info_value(old_compliance_info, field) != compliance_params[field]
      end
    end

    def country_changed?(old_compliance_info, field)
      compliance_params[field].present? &&
        country_param_will_be_persisted? &&
        compliance_info_value(old_compliance_info, field) != Compliance::Countries.mapping[compliance_params[field]]
    end

    def country_param_will_be_persisted?
      !compliance_params[:is_business].nil? && ActiveModel::Type::Boolean.new.cast(compliance_params[:is_business])
    end

    def business_mode_param_changed?(old_compliance_info)
      !compliance_params[:is_business].nil? &&
        old_compliance_info.is_business != ActiveModel::Type::Boolean.new.cast(compliance_params[:is_business])
    end

    def birthday_changed?(old_compliance_info)
      compliance_params[:dob_year].present? &&
        compliance_params[:dob_year].to_i > 0 &&
        old_compliance_info.birthday != Date.new(compliance_params[:dob_year].to_i, compliance_params[:dob_month].to_i, compliance_params[:dob_day].to_i)
    end

    def compliance_info_value(compliance_info, field)
      compliance_info.public_send(field)
    end

    def encrypted_compliance_info_changed?(old_compliance_info)
      submitted_individual_tax_id = normalize_individual_tax_id(
        submitted_tax_id_for(:individual_tax_id).presence || submitted_tax_id_for(:ssn_last_four).presence
      )
      return true if submitted_individual_tax_id.present? && encrypted_compliance_info_value(old_compliance_info, :individual_tax_id) != submitted_individual_tax_id

      submitted_business_tax_id = normalize_business_tax_id(
        submitted_tax_id_for(:business_tax_id),
        country_code: old_compliance_info.legal_entity_country_code,
      )
      return true if submitted_business_tax_id.present? && encrypted_compliance_info_value(old_compliance_info, :business_tax_id) != submitted_business_tax_id

      false
    end

    def submitted_tax_id_for(field)
      value = compliance_params[field]
      return nil if value.blank?
      return nil if value.to_s.match?(MASKED_TAX_ID_PATTERN)
      value
    end

    def normalize_business_tax_id(value, country_code:)
      return nil if value.blank?
      return value.gsub(/\D/, "") if country_code == "US"
      # Sellers paste locale-formatted tax IDs that can contain Unicode whitespace — for
      # example U+202F (narrow no-break space), which macOS inserts as a thousands
      # separator in French locale, so a SIREN copied from a document arrives as
      # "912 904 331" with U+202F between the groups. Ruby's \s only matches ASCII
      # whitespace, so use the Unicode-aware [[:space:]] class; otherwise the invisible
      # character survives into the stored value and later breaks byte-based slicing
      # (see SettingsPresenter#tax_id_last_four).
      value.gsub(/[[:space:]-]+/, "")
    end

    def normalize_individual_tax_id(value)
      return nil if value.blank?
      # Same Unicode-whitespace hazard as normalize_business_tax_id above. Only strip
      # whitespace here — dashes can be a meaningful part of individual IDs (for example
      # Peru DNIs are entered with the verification digit as "12345678-9").
      value.gsub(/[[:space:]]+/, "")
    end

    def peru_individual_dni_error(old_compliance_info)
      submitted = submitted_tax_id_for(:individual_tax_id)
      return if submitted.blank?
      return unless effective_legal_entity_country_code(old_compliance_info) == Compliance::Countries::PER.alpha2
      return if submitted.gsub(/\D/, "").length == PERU_DNI_DIGIT_COUNT
      "Your Peru DNI must include the verification digit (for example, 12345678-9)."
    end

    def singapore_individual_nric_error(old_compliance_info)
      submitted = submitted_tax_id_for(:individual_tax_id)
      return if submitted.blank?
      return unless effective_legal_entity_country_code(old_compliance_info) == Compliance::Countries::SGP.alpha2
      # Sellers sometimes paste the NRIC with spaces or dashes; those are harmless, so ignore
      # them when checking the shape (the submitted value is still stored as entered).
      # [[:space:]] instead of \s so Unicode spaces (like the non-breaking space that
      # often comes along when copying from a PDF or website) are also tolerated,
      # matching what the browser-side check accepts.
      return if submitted.gsub(/[[:space:]-]/, "").match?(SINGAPORE_NRIC_FIN_PATTERN)
      "Your NRIC/FIN must start with S, T, F, G or M and end with a letter (for example, S1234567A). Please enter it exactly as it appears on your ID."
    end

    def effective_legal_entity_country_code(old_compliance_info)
      submitting_as_business = compliance_params[:is_business].nil? ? old_compliance_info.is_business? : ActiveModel::Type::Boolean.new.cast(compliance_params[:is_business])
      if submitting_as_business
        compliance_params[:business_country].presence || old_compliance_info.business_country_code
      else
        old_compliance_info.country_code
      end
    end

    def encrypted_compliance_info_params_present?
      submitted_tax_id_for(:individual_tax_id).present? || submitted_tax_id_for(:ssn_last_four).present? || submitted_tax_id_for(:business_tax_id).present?
    end

    def encrypted_compliance_info_value(compliance_info, field)
      value = compliance_info.public_send(field)
      return value.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")) if ENCRYPTED_COMPLIANCE_INFO_FIELDS.include?(field) && value.is_a?(Strongbox::Lock)

      value
    end

    # A Japanese address is only valid for our payment partner when it includes the city/ward as
    # its own field. The onboarding form collects it, but a page loaded before the form gained the
    # city fields (or any client that skips the form) can still submit a Japanese address without
    # one — and that address shows the city duplicated inside the street line on Stripe's side.
    # So when a submission actually changes the Japanese address (see
    # japan_address_change_detected?), require the matching city fields too. Saves that don't
    # touch the address are left alone so legacy records without a city can still update
    # unrelated fields.
    def japan_city_error_message
      if japan_address_submitted_for?(:individual)
        city = compliance_params[:city].presence || current_compliance_info.city.presence
        city_kana = compliance_params[:city_kana].presence || current_compliance_info.city_kana.presence
        return "City/Ward is required for Japanese addresses. Please re-enter your address including the city/ward." if city.blank? || city_kana.blank?
      end

      if japan_address_submitted_for?(:business)
        business_city = compliance_params[:business_city].presence || current_compliance_info.business_city.presence
        business_city_kana = compliance_params[:business_city_kana].presence || current_compliance_info.business_city_kana.presence
        return "Business city/Ward is required for Japanese addresses. Please re-enter your business address including the city/ward." if business_city.blank? || business_city_kana.blank?
      end

      nil
    end

    def japan_address_submitted_for?(entity)
      if entity == :individual
        return false unless effective_country_code_for(:street_address) == Compliance::Countries::JPN.alpha2
        japan_address_change_detected?(JAPAN_INDIVIDUAL_ADDRESS_FIELDS, :street_address)
      else
        return false unless effective_is_business?
        return false unless effective_country_code_for(:business_street_address) == Compliance::Countries::JPN.alpha2
        japan_address_change_detected?(JAPAN_BUSINESS_ADDRESS_FIELDS, :business_street_address)
      end
    end

    # The Payments settings form loads every stored compliance field and submits them all back on
    # save, so a Japanese address field merely being present in the params does not mean the
    # seller touched their address. Treat the address as (re)submitted only when a submitted field
    # actually differs from what's stored, or when the validation context changed (the country
    # switched to Japan, or the account switched between individual and business) while a Japanese
    # address is on the record — in both cases the address is about to be synced to Stripe under
    # rules it wasn't checked against before.
    def japan_address_change_detected?(fields, address_field)
      return true if fields.any? { |field| address_changed?(field) }

      validation_context_changed_for?(address_field) &&
        fields.any? { |field| compliance_params[field].present? || current_compliance_info.public_send(field).present? }
    end

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
