# frozen_string_literal: true

module StripeBeneficialOwnersManager
  DEFAULT_TITLE = "Director"
  PERSON_LIST_LIMIT = 100

  class NotEligibleError < GumroadRuntimeError; end
  class RepresentativeNotEditableError < GumroadRuntimeError; end
  class MissingRequiredFieldError < GumroadRuntimeError; end

  REQUIRED_FIELDS_FOR_BENEFICIAL_OWNER = {
    first_name: "First name",
    last_name: "Last name",
    email: "Email",
    phone: "Phone",
  }.freeze

  REQUIRED_ADDRESS_FIELDS = {
    line1: "Street address",
    city: "City",
    state: "State or region",
    postal_code: "Postal code",
    country: "Country",
  }.freeze

  COUNTRIES_WITHOUT_POSTAL_CODE = ["BW"].freeze
  COUNTRIES_WITH_STATE_LIST = %w[US CA AU MX AE IE BR JP].freeze
  COUNTRIES_REQUIRING_NATIONALITY = [
    Compliance::Countries::ARE.alpha2,
    Compliance::Countries::SGP.alpha2,
    Compliance::Countries::BGD.alpha2,
    Compliance::Countries::PAK.alpha2,
  ].freeze

  REQUIRED_CREATE_ONLY_FIELDS = {
    id_number: "Personal tax ID number",
  }.freeze

  REQUIRED_JP_NAME_FIELDS = {
    first_name_kanji: "First name (Kanji)",
    last_name_kanji: "Last name (Kanji)",
    first_name_kana: "First name (Kana)",
    last_name_kana: "Last name (Kana)",
  }.freeze

  REQUIRED_JP_ADDRESS_FIELDS = {
    building_number: "Block / Building number (Kanji)",
    street_address_kanji: "Street address (Kanji)",
    building_number_kana: "Block / Building number (Kana)",
    street_address_kana: "Street address (Kana)",
    state: "Prefecture",
    postal_code: "Postal code",
  }.freeze

  def self.list(user)
    stripe_account = ensure_eligible!(user)
    persons = Stripe::Account.list_persons(stripe_account.charge_processor_merchant_id, limit: PERSON_LIST_LIMIT)["data"]
    persons.map { |person| serialize(person) }
  end

  def self.create(user, params)
    stripe_account = ensure_eligible!(user)
    validate_required_fields!(params, action: :create, user: user)
    person_params = build_person_params(params, user, action: :create)
    person = Stripe::Account.create_person(stripe_account.charge_processor_merchant_id, person_params)
    serialize(person)
  end

  def self.update(user, stripe_person_id, params)
    stripe_account = ensure_eligible!(user)
    existing = Stripe::Account.retrieve_person(stripe_account.charge_processor_merchant_id, stripe_person_id)

    if representative?(existing)
      person_params = build_representative_update_params(params)
    else
      validate_required_fields!(params, action: :update, user: user)
      person_params = build_person_params(params, user, action: :update)
    end

    person = Stripe::Account.update_person(stripe_account.charge_processor_merchant_id, stripe_person_id, person_params)
    serialize(person)
  end

  def self.destroy(user, stripe_person_id)
    stripe_account = ensure_eligible!(user)
    existing = Stripe::Account.retrieve_person(stripe_account.charge_processor_merchant_id, stripe_person_id)
    raise RepresentativeNotEditableError if representative?(existing)

    Stripe::Account.delete_person(stripe_account.charge_processor_merchant_id, stripe_person_id)
    { deleted: true, id: stripe_person_id }
  end

  def self.eligible?(user)
    return false if user.stripe_account.blank?
    return false if user.stripe_account.is_a_stripe_connect_account?
    user.alive_user_compliance_info&.is_business? == true
  end

  def self.ensure_eligible!(user)
    raise NotEligibleError, "User #{user.id} does not have a Gumroad-managed business Stripe account" unless eligible?(user)
    user.stripe_account
  end
  private_class_method :ensure_eligible!

  def self.validate_required_fields!(params, action:, user:)
    seller_country = user.alive_user_compliance_info&.legal_entity_country_code
    is_jp_seller = seller_country == Compliance::Countries::JPN.alpha2

    missing = REQUIRED_FIELDS_FOR_BENEFICIAL_OWNER.filter_map do |key, label|
      label if params[key].to_s.strip.empty?
    end
    if is_jp_seller
      missing += REQUIRED_JP_NAME_FIELDS.filter_map do |key, label|
        label if params[key].to_s.strip.empty?
      end
    end
    dob = params[:dob]
    dob_submitted = dob.is_a?(Hash) || dob.is_a?(ActionController::Parameters)
    if !dob_submitted || %i[day month year].any? { |k| dob[k].to_s.strip.empty? }
      missing << "Date of birth"
    end
    address = params[:address]
    address_submitted = address.is_a?(Hash) || address.is_a?(ActionController::Parameters)
    if address_submitted
      address_country = address[:country].to_s.strip
      if address_country == Compliance::Countries::JPN.alpha2
        missing += REQUIRED_JP_ADDRESS_FIELDS.filter_map do |key, label|
          label if address[key].to_s.strip.empty?
        end
      else
        required = required_address_fields_for(address_country)
        missing += required.filter_map do |key, label|
          label if address[key].to_s.strip.empty?
        end
      end
    elsif action == :create
      missing += is_jp_seller ? REQUIRED_JP_ADDRESS_FIELDS.values : REQUIRED_ADDRESS_FIELDS.values
    end
    if action == :create
      missing += REQUIRED_CREATE_ONLY_FIELDS.filter_map do |key, label|
        label if params[key].to_s.strip.empty?
      end
    end
    if action == :create && COUNTRIES_REQUIRING_NATIONALITY.include?(seller_country) && params[:nationality].to_s.strip.empty?
      missing << "Nationality"
    end
    if truthy?(params[:owner]) && params[:percent_ownership].to_s.strip.empty?
      missing << "Ownership percentage"
    end
    return if missing.empty?
    raise MissingRequiredFieldError, "#{missing.to_sentence} #{missing.length == 1 ? "is" : "are"} required for beneficial owners — Stripe needs them to verify the person."
  end
  private_class_method :validate_required_fields!

  def self.required_address_fields_for(country_code)
    fields = REQUIRED_ADDRESS_FIELDS
    fields = fields.except(:postal_code) if COUNTRIES_WITHOUT_POSTAL_CODE.include?(country_code)
    fields = fields.except(:state) unless COUNTRIES_WITH_STATE_LIST.include?(country_code)
    fields
  end
  private_class_method :required_address_fields_for

  def self.representative?(person)
    relationship = person.is_a?(Hash) ? person[:relationship] || person["relationship"] : person[:relationship]
    !!(relationship && (relationship[:representative] || relationship["representative"]))
  end
  private_class_method :representative?

  def self.symbolize(value)
    case value
    when Hash then value.deep_symbolize_keys
    when Stripe::StripeObject then value.to_hash.deep_symbolize_keys
    else value
    end
  end
  private_class_method :symbolize

  def self.serialize(person)
    data = symbolize(person.is_a?(Stripe::StripeObject) ? person.to_hash : person)
    relationship = data[:relationship] || {}
    dob = data[:dob]

    {
      id: data[:id],
      first_name: data[:first_name],
      last_name: data[:last_name],
      email: data[:email],
      phone: data[:phone],
      dob: dob ? { day: dob[:day], month: dob[:month], year: dob[:year] } : nil,
      address: data[:address] || {},
      relationship: {
        owner: !!relationship[:owner],
        director: !!relationship[:director],
        executive: !!relationship[:executive],
        representative: !!relationship[:representative],
        title: relationship[:title],
        percent_ownership: relationship[:percent_ownership],
      },
      id_number_provided: !!data[:id_number_provided],
      ssn_last_4_provided: !!data[:ssn_last_4_provided],
      nationality: data[:nationality],
      first_name_kanji: data[:first_name_kanji],
      last_name_kanji: data[:last_name_kanji],
      first_name_kana: data[:first_name_kana],
      last_name_kana: data[:last_name_kana],
      address_kanji: data[:address_kanji] || {},
      address_kana: data[:address_kana] || {},
      verification_status: data.dig(:verification, :status),
      requirements_currently_due: data.dig(:requirements, :currently_due) || [],
    }
  end
  private_class_method :serialize

  def self.build_representative_update_params(params)
    relationship = { representative: true }
    relationship[:owner] = truthy?(params[:owner]) if params.key?(:owner)
    relationship[:director] = truthy?(params[:director]) if params.key?(:director)
    relationship[:executive] = truthy?(params[:executive]) if params.key?(:executive)
    relationship[:title] = params[:title] if params[:title].present?
    relationship[:percent_ownership] = params[:percent_ownership].to_f if params[:percent_ownership].present?
    { relationship: relationship }
  end
  private_class_method :build_representative_update_params

  def self.build_person_params(params, user, action:)
    compliance_info = user.alive_user_compliance_info
    country_code = compliance_info&.legal_entity_country_code

    relationship = {
      owner: truthy?(params[:owner]),
      director: truthy?(params[:director]),
      executive: truthy?(params[:executive]),
      representative: false,
    }
    if params[:title].present?
      relationship[:title] = params[:title]
    elsif action == :create
      relationship[:title] = DEFAULT_TITLE
    end
    if params[:percent_ownership].present?
      relationship[:percent_ownership] = params[:percent_ownership].to_f
    end

    hash = {
      first_name: params[:first_name],
      last_name: params[:last_name],
      email: params[:email].presence,
      phone: params[:phone].presence,
      relationship:,
    }

    if country_code == Compliance::Countries::JPN.alpha2
      hash[:first_name_kanji] = params[:first_name_kanji] if params[:first_name_kanji].present?
      hash[:last_name_kanji] = params[:last_name_kanji] if params[:last_name_kanji].present?
      hash[:first_name_kana] = params[:first_name_kana] if params[:first_name_kana].present?
      hash[:last_name_kana] = params[:last_name_kana] if params[:last_name_kana].present?
    end

    if params[:dob].is_a?(Hash) || params[:dob].is_a?(ActionController::Parameters)
      hash[:dob] = {
        day: params[:dob][:day].presence && params[:dob][:day].to_i,
        month: params[:dob][:month].presence && params[:dob][:month].to_i,
        year: params[:dob][:year].presence && params[:dob][:year].to_i,
      }.compact
      hash.delete(:dob) if hash[:dob].empty?
    end

    if params[:address].is_a?(Hash) || params[:address].is_a?(ActionController::Parameters)
      address_country = params[:address][:country].to_s.strip.presence || country_code
      if address_country == Compliance::Countries::JPN.alpha2
        address_kanji = {
          line1: params[:address][:building_number].presence,
          town: params[:address][:street_address_kanji].presence,
          state: params[:address][:state].presence,
          country: "JP",
          postal_code: params[:address][:postal_code].presence,
        }.compact
        hash[:address_kanji] = address_kanji if address_kanji.any?
        kana_state = params[:address][:state_kana].presence ||
                     (params[:address][:state].presence && Compliance::Countries.japan_prefecture_kana(params[:address][:state]))
        address_kana = {
          line1: params[:address][:building_number_kana].presence,
          town: params[:address][:street_address_kana].presence,
          state: kana_state,
          country: "JP",
          postal_code: params[:address][:postal_code].presence,
        }.compact
        hash[:address_kana] = address_kana if address_kana.any?
      else
        address = {
          line1: params[:address][:line1].presence,
          line2: params[:address][:line2].presence,
          city: params[:address][:city].presence,
          state: params[:address][:state].presence,
          postal_code: params[:address][:postal_code].presence,
          country: address_country,
        }.compact
        hash[:address] = address if address.any?
      end
    end

    id_number = params[:id_number].to_s.strip
    if id_number.present?
      if country_code == Compliance::Countries::USA.alpha2 && id_number.length == 4
        hash[:ssn_last_4] = id_number
      else
        hash[:id_number] = id_number
      end
    end

    if COUNTRIES_REQUIRING_NATIONALITY.include?(country_code) && params[:nationality].present?
      hash[:nationality] = params[:nationality]
    end

    if country_code == Compliance::Countries::SGP.alpha2 && action == :create
      hash[:full_name_aliases] = [""]
    end

    hash.compact
  end
  private_class_method :build_person_params

  def self.truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end
  private_class_method :truthy?
end
