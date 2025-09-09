# frozen_string_literal: true

class UpdatePayoutMethod
  attr_reader :params, :user

  BANK_ACCOUNT_TYPES = {
    AchAccount.name => { class: AchAccount, permitted_params: [:routing_number] },
    CanadianBankAccount.name => { class: CanadianBankAccount, permitted_params: %i[institution_number transit_number] },
    AustralianBankAccount.name => { class: AustralianBankAccount, permitted_params: [:bsb_number] },
    UkBankAccount.name => { class: UkBankAccount, permitted_params: [:sort_code] },
    EuropeanBankAccount.name => { class: EuropeanBankAccount, permitted_params: [] },
    HongKongBankAccount.name => { class: HongKongBankAccount, permitted_params: [:clearing_code, :branch_code] },
    NewZealandBankAccount.name => { class: NewZealandBankAccount, permitted_params: [] },
    SingaporeanBankAccount.name => { class: SingaporeanBankAccount, permitted_params: [:bank_code, :branch_code] },
    SwissBankAccount.name => { class: SwissBankAccount, permitted_params: [] },
    PolandBankAccount.name => { class: PolandBankAccount, permitted_params: [] },
    CzechRepublicBankAccount.name => { class: CzechRepublicBankAccount, permitted_params: [] },
    ThailandBankAccount.name => { class: ThailandBankAccount, permitted_params: [:bank_code] },
    BulgariaBankAccount.name => { class: BulgariaBankAccount, permitted_params: [] },
    DenmarkBankAccount.name => { class: DenmarkBankAccount, permitted_params: [] },
    HungaryBankAccount.name => { class: HungaryBankAccount, permitted_params: [] },
    KoreaBankAccount.name => { class: KoreaBankAccount, permitted_params: [:bank_code] },
    UaeBankAccount.name => { class: UaeBankAccount, permitted_params: [] },
    AntiguaAndBarbudaBankAccount.name => { class: AntiguaAndBarbudaBankAccount, permitted_params: [:bank_code] },
    TanzaniaBankAccount.name => { class: TanzaniaBankAccount, permitted_params: [:bank_code] },
    NamibiaBankAccount.name => { class: NamibiaBankAccount, permitted_params: [:bank_code] },
    IsraelBankAccount.name => { class: IsraelBankAccount, permitted_params: [] },
    TrinidadAndTobagoBankAccount.name => { class: TrinidadAndTobagoBankAccount, permitted_params: [:bank_code, :branch_code] },
    PhilippinesBankAccount.name => { class: PhilippinesBankAccount, permitted_params: [:bank_code] },
    RomaniaBankAccount.name => { class: RomaniaBankAccount, permitted_params: [] },
    SwedenBankAccount.name => { class: SwedenBankAccount, permitted_params: [] },
    MexicoBankAccount.name => { class: MexicoBankAccount, permitted_params: [] },
    ArgentinaBankAccount.name => { class: ArgentinaBankAccount, permitted_params: [] },
    LiechtensteinBankAccount.name => { class: LiechtensteinBankAccount, permitted_params: [] },
    PeruBankAccount.name => { class: PeruBankAccount, permitted_params: [] },
    NorwayBankAccount.name => { class: NorwayBankAccount, permitted_params: [] },
    IndianBankAccount.name => { class: IndianBankAccount, permitted_params: [:ifsc] },
    VietnamBankAccount.name => { class: VietnamBankAccount, permitted_params: [:bank_code] },
    TaiwanBankAccount.name => { class: TaiwanBankAccount, permitted_params: [:bank_code] },
    BosniaAndHerzegovinaBankAccount.name => { class: BosniaAndHerzegovinaBankAccount, permitted_params: [:bank_code] },
    IndonesiaBankAccount.name => { class: IndonesiaBankAccount, permitted_params: [:bank_code] },
    CostaRicaBankAccount.name => { class: CostaRicaBankAccount, permitted_params: [] },
    BotswanaBankAccount.name => { class: BotswanaBankAccount, permitted_params: [:bank_code] },
    ChileBankAccount.name => { class: ChileBankAccount, permitted_params: [:bank_code] },
    PakistanBankAccount.name => { class: PakistanBankAccount, permitted_params: [:bank_code] },
    TurkeyBankAccount.name => { class: TurkeyBankAccount, permitted_params: [:bank_code] },
    MoroccoBankAccount.name => { class: MoroccoBankAccount, permitted_params: [:bank_code] },
    AzerbaijanBankAccount.name => { class: AzerbaijanBankAccount, permitted_params: [:bank_code, :branch_code] },
    AlbaniaBankAccount.name => { class: AlbaniaBankAccount, permitted_params: [:bank_code] },
    BahrainBankAccount.name => { class: BahrainBankAccount, permitted_params: [:bank_code] },
    JordanBankAccount.name => { class: JordanBankAccount, permitted_params: [:bank_code] },
    EthiopiaBankAccount.name => { class: EthiopiaBankAccount, permitted_params: [:bank_code] },
    BruneiBankAccount.name => { class: BruneiBankAccount, permitted_params: [:bank_code] },
    GuyanaBankAccount.name => { class: GuyanaBankAccount, permitted_params: [:bank_code] },
    GuatemalaBankAccount.name => { class: GuatemalaBankAccount, permitted_params: [:bank_code] },
    NigeriaBankAccount.name => { class: NigeriaBankAccount, permitted_params: [:bank_code] },
    SerbiaBankAccount.name => { class: SerbiaBankAccount, permitted_params: [:bank_code] },
    SouthAfricaBankAccount.name => { class: SouthAfricaBankAccount, permitted_params: [:bank_code] },
    KenyaBankAccount.name => { class: KenyaBankAccount, permitted_params: [:bank_code] },
    RwandaBankAccount.name => { class: RwandaBankAccount, permitted_params: [:bank_code] },
    EgyptBankAccount.name => { class: EgyptBankAccount, permitted_params: [:bank_code] },
    ColombiaBankAccount.name => { class: ColombiaBankAccount, permitted_params: [:bank_code, :account_type] },
    SaudiArabiaBankAccount.name => { class: SaudiArabiaBankAccount, permitted_params: [:bank_code] },
    JapanBankAccount.name => { class: JapanBankAccount, permitted_params: [:bank_code, :branch_code] },
    KazakhstanBankAccount.name => { class: KazakhstanBankAccount, permitted_params: [:bank_code] },
    EcuadorBankAccount.name => { class: EcuadorBankAccount, permitted_params: [:bank_code] },
    MalaysiaBankAccount.name => { class: MalaysiaBankAccount, permitted_params: [:bank_code] },
    GibraltarBankAccount.name => { class: GibraltarBankAccount, permitted_params: [] },
    UruguayBankAccount.name => { class: UruguayBankAccount, permitted_params: [:bank_code] },
    MauritiusBankAccount.name => { class: MauritiusBankAccount, permitted_params: [:bank_code] },
    AngolaBankAccount.name => { class: AngolaBankAccount, permitted_params: [:bank_code] },
    NigerBankAccount.name => { class: NigerBankAccount, permitted_params: [] },
    SanMarinoBankAccount.name => { class: SanMarinoBankAccount, permitted_params: [:bank_code] },
    JamaicaBankAccount.name => { class: JamaicaBankAccount, permitted_params: [:bank_code, :branch_code] },
    BangladeshBankAccount.name => { class: BangladeshBankAccount, permitted_params: [:bank_code] },
    BhutanBankAccount.name => { class: BhutanBankAccount, permitted_params: [:bank_code] },
    LaosBankAccount.name => { class: LaosBankAccount, permitted_params: [:bank_code] },
    MozambiqueBankAccount.name => { class: MozambiqueBankAccount, permitted_params: [:bank_code] },
    OmanBankAccount.name => { class: OmanBankAccount, permitted_params: [:bank_code] },
    DominicanRepublicBankAccount.name => { class: DominicanRepublicBankAccount, permitted_params: [:bank_code, :branch_code] },
    UzbekistanBankAccount.name => { class: UzbekistanBankAccount, permitted_params: [:bank_code, :branch_code] },
    BoliviaBankAccount.name => { class: BoliviaBankAccount, permitted_params: [:bank_code] },
    TunisiaBankAccount.name => { class: TunisiaBankAccount, permitted_params: [] },
    MoldovaBankAccount.name => { class: MoldovaBankAccount, permitted_params: [:bank_code] },
    NorthMacedoniaBankAccount.name => { class: NorthMacedoniaBankAccount, permitted_params: [:bank_code] },
    PanamaBankAccount.name => { class: PanamaBankAccount, permitted_params: [:bank_code] },
    ElSalvadorBankAccount.name => { class: ElSalvadorBankAccount, permitted_params: [:bank_code] },
    MadagascarBankAccount.name => { class: MadagascarBankAccount, permitted_params: [:bank_code] },
    ParaguayBankAccount.name => { class: ParaguayBankAccount, permitted_params: [:bank_code] },
    GhanaBankAccount.name => { class: GhanaBankAccount, permitted_params: [:bank_code] },
    ArmeniaBankAccount.name => { class: ArmeniaBankAccount, permitted_params: [:bank_code] },
    SriLankaBankAccount.name => { class: SriLankaBankAccount, permitted_params: [:bank_code, :branch_code] },
    KuwaitBankAccount.name => { class: KuwaitBankAccount, permitted_params: [:bank_code] },
    IcelandBankAccount.name => { class: IcelandBankAccount, permitted_params: [] },
    QatarBankAccount.name => { class: QatarBankAccount, permitted_params: [:bank_code] },
    BahamasBankAccount.name => { class: BahamasBankAccount, permitted_params: [:bank_code] },
    SaintLuciaBankAccount.name => { class: SaintLuciaBankAccount, permitted_params: [:bank_code] },
    SenegalBankAccount.name => { class: SenegalBankAccount, permitted_params: [] },
    CambodiaBankAccount.name => { class: CambodiaBankAccount, permitted_params: [:bank_code] },
    MongoliaBankAccount.name => { class: MongoliaBankAccount, permitted_params: [:bank_code] },
    GabonBankAccount.name => { class: GabonBankAccount, permitted_params: [:bank_code] },
    MonacoBankAccount.name => { class: MonacoBankAccount, permitted_params: [] },
    AlgeriaBankAccount.name => { class: AlgeriaBankAccount, permitted_params: [:bank_code] },
    MacaoBankAccount.name => { class: MacaoBankAccount, permitted_params: [:bank_code] },
    BeninBankAccount.name => { class: BeninBankAccount, permitted_params: [] },
    CoteDIvoireBankAccount.name => { class: CoteDIvoireBankAccount, permitted_params: [] },
  }.freeze
  private_constant :BANK_ACCOUNT_TYPES

  def self.bank_account_types
    BANK_ACCOUNT_TYPES
  end

  def initialize(user_params:, seller:)
    @params = user_params
    @user = seller
  end

  def process
    old_bank_account = user.active_bank_account

    if params[:card]
      chargeable = ChargeProcessor.get_chargeable_for_params(params[:card], nil)
      return { error: :check_card_information_prompt } if chargeable.nil?

      credit_card = CreditCard.create(chargeable)
      return { error: :credit_card_error, data: credit_card.errors.full_messages.to_sentence } if credit_card.errors.present?

      old_bank_account.try(:mark_deleted!)

      bank_account = CardBankAccount.new
      bank_account.user = user
      bank_account.credit_card = credit_card
      bank_account.save

      return { error: :bank_account_error, data: bank_account.errors.full_messages.to_sentence } if bank_account.errors.present?

      user.update!(payment_address: "") if user.payment_address.present?
    elsif params[:bank_account].present? &&
      params[:bank_account][:type].present? &&
      (params[:bank_account][:account_holder_full_name].present? || params[:bank_account][:account_number].present?)

      raise unless params[:bank_account][:type].in?(BANK_ACCOUNT_TYPES)

      if params[:bank_account][:account_number].present?
        bank_account_account_number = params[:bank_account][:account_number].delete("-").strip
        bank_account_account_number_confirmation = params[:bank_account][:account_number_confirmation].delete("-").strip

        return { error: :account_number_does_not_match } if bank_account_account_number != bank_account_account_number_confirmation

        old_bank_account.try(:mark_deleted!)

        bank_account = BANK_ACCOUNT_TYPES[params[:bank_account][:type]][:class].new(bank_account_params_for_bank_account_type)
        bank_account.user = user
        bank_account.account_holder_full_name = params[:bank_account][:account_holder_full_name]
        bank_account.account_number = bank_account_account_number
        bank_account.account_number_last_four = bank_account_account_number.last(4)
        bank_account.account_type = params[:bank_account][:account_type] if params[:bank_account][:account_type].present?
        bank_account.save

        return { error: :bank_account_error, data: bank_account.errors.full_messages.to_sentence } if bank_account.errors.present?

        user.update!(payment_address: "") if user.payment_address.present?
      elsif params[:bank_account][:account_holder_full_name].present?
        old_bank_account.update(account_holder_full_name: params[:bank_account][:account_holder_full_name])
      end
    elsif params[:payment_address].present?
      payment_address = params[:payment_address].strip

      return { error: :provide_valid_email_prompt } unless EmailFormatValidator.valid?(payment_address)
      return { error: :provide_ascii_only_email_prompt } unless payment_address.ascii_only?
      return { error: :paypal_payouts_not_supported } if user.alive_user_compliance_info.blank? || user.native_payouts_supported?

      user.payment_address = payment_address
      user.save!

      if user.stripe_account.present? && user.unpaid_balances.where(merchant_account_id: user.stripe_account.id).present?
        user.transfer_stripe_balance_to_gumroad_account!
      end
      user.stripe_account&.delete_charge_processor_account!
      user.active_bank_account&.mark_deleted!
      user.user_compliance_info_requests.requested.find_each(&:mark_provided!)
      user.update!(payouts_paused_internally: false) if user.payouts_paused_internally? && !user.flagged? && !user.suspended?

      CheckPaymentAddressWorker.perform_async(user.id)
    end

    { success: true }
  end

  private
    def bank_account_params_for_bank_account_type
      bank_account_type = params[:bank_account][:type]
      permitted_params = BANK_ACCOUNT_TYPES[bank_account_type][:permitted_params]
      params[:bank_account].permit(*permitted_params)
    end
end
