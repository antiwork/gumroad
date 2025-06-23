# frozen_string_literal: true

class UpdateUserComplianceInfo
  attr_reader :compliance_params, :user

  def initialize(compliance_params:, user:)
    @compliance_params = compliance_params
    @user = user
  end

  def process
    if compliance_params.present?
      old_compliance_info = user.fetch_or_build_user_compliance_info
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
        new_compliance_info.business_tax_id =         compliance_params[:business_tax_id]         if compliance_params[:business_tax_id].present?
        new_compliance_info.guardian_first_name =         compliance_params[:guardian_first_name]         if compliance_params[:guardian_first_name].present?
        new_compliance_info.guardian_last_name =          compliance_params[:guardian_last_name]          if compliance_params[:guardian_last_name].present?
        new_compliance_info.guardian_email =              compliance_params[:guardian_email]              if compliance_params[:guardian_email].present?
        new_compliance_info.guardian_phone =              compliance_params[:guardian_phone]              if compliance_params[:guardian_phone].present?
        new_compliance_info.guardian_street_address =     compliance_params[:guardian_street_address]     if compliance_params[:guardian_street_address].present?
        new_compliance_info.guardian_city =               compliance_params[:guardian_city]               if compliance_params[:guardian_city].present?
        new_compliance_info.guardian_state =              compliance_params[:guardian_state]              if compliance_params[:guardian_state].present?
        new_compliance_info.guardian_country =            Compliance::Countries.mapping[compliance_params[:guardian_country]] if compliance_params[:guardian_country].present?
        new_compliance_info.guardian_zip_code =           compliance_params[:guardian_zip_code]           if compliance_params[:guardian_zip_code].present?
        new_compliance_info.guardian_dob_year =           compliance_params[:guardian_dob_year]           if compliance_params[:guardian_dob_year].present?
        new_compliance_info.guardian_dob_month =          compliance_params[:guardian_dob_month]          if compliance_params[:guardian_dob_month].present?
        new_compliance_info.guardian_dob_day =            compliance_params[:guardian_dob_day]            if compliance_params[:guardian_dob_day].present?
        new_compliance_info.guardian_country_code =       compliance_params[:guardian_country_code]       if compliance_params[:guardian_country_code].present?
        new_compliance_info.guardian_individual_tax_id =  compliance_params[:guardian_ssn_last_four]         if compliance_params[:guardian_ssn_last_four].present?
        new_compliance_info.guardian_individual_tax_id =  compliance_params[:guardian_individual_tax_id]  if compliance_params[:guardian_individual_tax_id].present?
        new_compliance_info.guardian_stripe_tos_accepted = compliance_params[:guardian_stripe_tos_accepted] if compliance_params[:guardian_stripe_tos_accepted].present?
        new_compliance_info.guardian_stripe_processing_tos_accepted = compliance_params[:guardian_stripe_processing_tos_accepted] if compliance_params[:guardian_stripe_processing_tos_accepted].present?
        new_compliance_info.birthday = Date.new(compliance_params[:dob_year].to_i, compliance_params[:dob_month].to_i, compliance_params[:dob_day].to_i) if compliance_params[:dob_year].present? && compliance_params[:dob_year].to_i > 0
        new_compliance_info.skip_stripe_job_on_create = true
        new_compliance_info.phone =                   compliance_params[:phone]                   if compliance_params[:phone].present?
        new_compliance_info.business_phone =          compliance_params[:business_phone]          if compliance_params[:business_phone].present?
        new_compliance_info.job_title =               compliance_params[:job_title]               if compliance_params[:job_title].present?
        new_compliance_info.nationality =             compliance_params[:nationality]             if compliance_params[:nationality].present?
        new_compliance_info.business_vat_id_number =  compliance_params[:business_vat_id_number]  if compliance_params[:business_vat_id_number].present?
      end

      return { success: false, error_message: new_compliance_info.errors.full_messages.to_sentence } unless saved

      StripeMerchantAccountManager.handle_new_user_compliance_info(new_compliance_info)
    end

    { success: true }
  end

  private

  def filter_sensitive_params(params)
    filtered = params.dup
    sensitive_keys = [:individual_tax_id, :business_tax_id, :guardian_individual_tax_id, :ssn_last_four, :guardian_ssn_last_four]

    sensitive_keys.each do |key|
      filtered[key] = "[FILTERED]" if filtered[key].present?
    end

    filtered
  end

  def user_under_18?(user_compliance_info)
    return false unless user_compliance_info&.birthday

    user_compliance_info.birthday > 18.years.ago
  end
end
