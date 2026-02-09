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
        new_compliance_info.business_tax_id =         compliance_params[:business_tax_id]         if compliance_params[:business_tax_id].present?
        new_compliance_info.birthday = Date.new(compliance_params[:dob_year].to_i, compliance_params[:dob_month].to_i, compliance_params[:dob_day].to_i) if compliance_params[:dob_year].present? && compliance_params[:dob_year].to_i > 0
        new_compliance_info.skip_stripe_job_on_create = true
        new_compliance_info.phone =                   compliance_params[:phone]                   if compliance_params[:phone].present?
        new_compliance_info.business_phone =          compliance_params[:business_phone]          if compliance_params[:business_phone].present?
        new_compliance_info.job_title =               compliance_params[:job_title]               if compliance_params[:job_title].present?
        new_compliance_info.nationality =             compliance_params[:nationality]             if compliance_params[:nationality].present?
        new_compliance_info.business_vat_id_number =  compliance_params[:business_vat_id_number]  if compliance_params[:business_vat_id_number].present?
      end

      return { success: false, error_message: new_compliance_info.errors.full_messages.to_sentence } unless saved

      begin
        StripeMerchantAccountManager.handle_new_user_compliance_info(new_compliance_info)
      rescue Stripe::InvalidRequestError => e
        if e.code == "postal_code_invalid"
          country = new_compliance_info.legal_entity_country
          return { success: false, error_message: "The postal code you entered is not valid for #{country}." }
        end
        return { success: false, error_message: e.message.split("Please contact us").first.strip, error_code: "stripe_error" }
      end
    end

    { success: true }
  end
end
