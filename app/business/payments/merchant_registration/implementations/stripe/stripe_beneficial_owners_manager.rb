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
  COUNTRIES_REQUIRING_NATIONALITY = [
    Compliance::Countries::ARE.alpha2,
    Compliance::Countries::SGP.alpha2,
    Compliance::Countries::BGD.alpha2,
    Compliance::Countries::PAK.alpha2,
  ].freeze

  REQUIRED_CREATE_ONLY_FIELDS = {
    id_number: "Personal tax ID number",
  }.freeze

  def self.list(user)
    stripe_account = ensure_eligible!(user)
    persons = Stripe::Account.list_persons(stripe_account.charge_processor_merchant_id, limit: PERSON_LIST_LIMIT)["data"]
    persons.map { |person| serialize(person) }
  end

  def self.create(user, params)
    stripe_account = ensure_eligible!(user)
    validate_required_fields!(params, action: :create, user: user)
    person_params = build_person_params(params, user)
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
      person_params = build_person_params(params, user)
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
    missing = REQUIRED_FIELDS_FOR_BENEFICIAL_OWNER.filter_map do |key, label|
      label if params[key].to_s.strip.empty?
    end
    address = params[:address]
    address_submitted = address.is_a?(Hash) || address.is_a?(ActionController::Parameters)
    if address_submitted
      address_country = address[:country].to_s.strip
      required = required_address_fields_for(address_country)
      missing += required.filter_map do |key, label|
        label if address[key].to_s.strip.empty?
      end
    elsif action == :create
      missing += REQUIRED_ADDRESS_FIELDS.values
    end
    if action == :create
      missing += REQUIRED_CREATE_ONLY_FIELDS.filter_map do |key, label|
        label if params[key].to_s.strip.empty?
      end
    end
    seller_country = user.alive_user_compliance_info&.legal_entity_country_code
    if action == :create && COUNTRIES_REQUIRING_NATIONALITY.include?(seller_country) && params[:nationality].to_s.strip.empty?
      missing << "Nationality"
    end
    return if missing.empty?
    raise MissingRequiredFieldError, "#{missing.to_sentence} #{missing.length == 1 ? "is" : "are"} required for beneficial owners — Stripe needs them to verify the person."
  end
  private_class_method :validate_required_fields!

  def self.required_address_fields_for(country_code)
    return REQUIRED_ADDRESS_FIELDS.except(:postal_code) if COUNTRIES_WITHOUT_POSTAL_CODE.include?(country_code)
    REQUIRED_ADDRESS_FIELDS
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

  def self.build_person_params(params, user)
    compliance_info = user.alive_user_compliance_info
    country_code = compliance_info&.legal_entity_country_code

    relationship = {
      owner: truthy?(params[:owner]),
      director: truthy?(params[:director]),
      executive: truthy?(params[:executive]),
      representative: false,
      title: params[:title].presence || DEFAULT_TITLE,
    }
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

    if params[:dob].is_a?(Hash) || params[:dob].is_a?(ActionController::Parameters)
      hash[:dob] = {
        day: params[:dob][:day].presence && params[:dob][:day].to_i,
        month: params[:dob][:month].presence && params[:dob][:month].to_i,
        year: params[:dob][:year].presence && params[:dob][:year].to_i,
      }.compact
      hash.delete(:dob) if hash[:dob].empty?
    end

    if params[:address].is_a?(Hash) || params[:address].is_a?(ActionController::Parameters)
      address = {
        line1: params[:address][:line1].presence,
        line2: params[:address][:line2].presence,
        city: params[:address][:city].presence,
        state: params[:address][:state].presence,
        postal_code: params[:address][:postal_code].presence,
        country: params[:address][:country].presence || country_code,
      }.compact
      hash[:address] = address if address.any?
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

    hash.compact
  end
  private_class_method :build_person_params

  def self.truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end
  private_class_method :truthy?
end
