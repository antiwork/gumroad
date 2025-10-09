import cx from "classnames";
import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";

import { Button } from "$app/components/Button";
import { FormFieldName, User } from "$app/components/server-components/Settings/PaymentsPage";

export type BankAccount =
  | {
      type: "AchAccount";
      account_holder_full_name: string;
      routing_number: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "UaeBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "AlgeriaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "AngolaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "AntiguaAndBarbudaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "ArgentinaBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "ArmeniaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "AustralianBankAccount";
      account_holder_full_name: string;
      bsb_number: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BoliviaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BahamasBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BangladeshBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BhutanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BruneiBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BeninBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BulgariaBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "CambodiaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "CanadianBankAccount";
      account_holder_full_name: string;
      institution_number: string;
      transit_number: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "ChileBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
      account_type: string;
    }
  | {
      type: "ColombiaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_type: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "CostaRicaBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "CoteDIvoireBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "DominicanRepublicBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SwissBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "CzechRepublicBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "DenmarkBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "EcuadorBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "EgyptBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "ElSalvadorBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "EthiopiaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "EuropeanBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "GuatemalaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "GuyanaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "HongKongBankAccount";
      account_holder_full_name: string;
      clearing_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "HungaryBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "IcelandBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "IndianBankAccount";
      account_holder_full_name: string;
      ifsc: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "IndonesiaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "IsraelBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BotswanaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "JamaicaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "JapanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "KazakhstanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "KenyaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "KoreaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "KuwaitBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "LaosBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MalaysiaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MauritiusBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MozambiqueBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "LiechtensteinBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BosniaAndHerzegovinaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MacaoBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MexicoBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MoldovaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MongoliaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MoroccoBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "NewZealandBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "NigerBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "NorthMacedoniaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "NorwayBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "PanamaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "PakistanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "AzerbaijanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "BahrainBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "AlbaniaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "NigeriaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "JordanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "NamibiaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "PeruBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "PhilippinesBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "PolandBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "QatarBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "RomaniaBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SerbiaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SouthAfricaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SanMarinoBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SaudiArabiaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SriLankaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SwedenBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "RwandaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SingaporeanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "TaiwanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "TanzaniaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "ThailandBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "TrinidadAndTobagoBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "TurkeyBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "UkBankAccount";
      account_holder_full_name: string;
      sort_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "UruguayBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "GhanaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "UzbekistanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      branch_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "VietnamBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "GibraltarBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "OmanBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "TunisiaBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MadagascarBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "ParaguayBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SaintLuciaBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "SenegalBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "GabonBankAccount";
      account_holder_full_name: string;
      bank_code: string;
      account_number: string;
      account_number_confirmation: string;
    }
  | {
      type: "MonacoBankAccount";
      account_holder_full_name: string;
      account_number: string;
      account_number_confirmation: string;
    };

export type BankAccountDetails = {
  show_bank_account: boolean;
  show_paypal: boolean;
  is_a_card: boolean;
  routing_number: string | null;
  account_number_visual: string | null;
  card: SavedCreditCard | null;
  card_data_handling_mode: string | null;
  bank_account: Partial<BankAccount> | null;
};

const BankAccountSection = ({
  bankAccountDetails,
  bankAccount,
  updateBankAccount,
  hasConnectedStripe,
  user,
  isFormDisabled,
  feeInfoText,
  showNewBankAccount,
  setShowNewBankAccount,
  errorFieldNames,
}: {
  bankAccountDetails: BankAccountDetails;
  bankAccount: Partial<BankAccount> | null;
  updateBankAccount: (newBankAccount: Partial<BankAccount>) => void;
  hasConnectedStripe: boolean;
  user: User;
  isFormDisabled: boolean;
  feeInfoText: string;
  showNewBankAccount: boolean;
  setShowNewBankAccount: (showNewBankAccount: boolean) => void;
  errorFieldNames: Set<FormFieldName>;
}) => {
  const uid = React.useId();

  const BANK_AND_BRANCH_CODE_COUNTRIES = ["AZ", "SG", "JP", "DO", "UZ", "LK", "TT", "JM"];
  const BANK_CODE_COUNTRIES = ["BD", "BO", "CL", "CO", "GH", "ID", "KR", "PY", "TH", "UY", "VN"];
  const SWIFT_BIC_CODE_COUNTRIES = [
    "AG",
    "AL",
    "AM",
    "AO",
    "BA",
    "BH",
    "BN",
    "BS",
    "BT",
    "BW",
    "DZ",
    "EC",
    "EG",
    "ET",
    "GA",
    "GT",
    "GY",
    "JO",
    "KE",
    "KH",
    "KW",
    "KZ",
    "LA",
    "LC",
    "MA",
    "MD",
    "MG",
    "MK",
    "MN",
    "MO",
    "MU",
    "MY",
    "MZ",
    "NA",
    "NG",
    "OM",
    "PA",
    "PK",
    "QA",
    "RS",
    "RW",
    "SA",
    "SM",
    "SV",
    "TR",
    "TW",
    "TZ",
    "ZA",
  ];

  const getRoutingNumberLabel = (countryCode: string) => {
    switch (true) {
      case countryCode === "CA":
        return "Transit and institution #";
      case countryCode === "AU":
        return "BSB";
      case countryCode === "GB":
        return "Sort code";
      case countryCode === "IN":
        return "IFSC";
      case countryCode === "HK":
        return "Clearing and branch code";
      case countryCode === "PH":
        return "Bank Identifier Code (BIC)";
      case BANK_AND_BRANCH_CODE_COUNTRIES.includes(countryCode):
        return "Bank and branch code";
      case BANK_CODE_COUNTRIES.includes(countryCode):
        return "Bank code";
      case SWIFT_BIC_CODE_COUNTRIES.includes(countryCode):
        return "SWIFT / BIC code";
      default:
        return "Routing number";
    }
  };

  React.useEffect(() => {
    const countryToBankAccountTypeMapping: Record<string, BankAccount["type"]> = {
      US: "AchAccount",
      AU: "AustralianBankAccount",
      CA: "CanadianBankAccount",
      GB: "UkBankAccount",
      MX: "MexicoBankAccount",
      AE: "UaeBankAccount",
      HK: "HongKongBankAccount",
      SG: "SingaporeanBankAccount",
      TH: "ThailandBankAccount",
      KR: "KoreaBankAccount",
      BA: "BosniaAndHerzegovinaBankAccount",
      TT: "TrinidadAndTobagoBankAccount",
      PH: "PhilippinesBankAccount",
      NZ: "NewZealandBankAccount",
      CH: "SwissBankAccount",
      PL: "PolandBankAccount",
      CZ: "CzechRepublicBankAccount",
      BG: "BulgariaBankAccount",
      DK: "DenmarkBankAccount",
      HU: "HungaryBankAccount",
      IN: "IndianBankAccount",
      NA: "NamibiaBankAccount",
      TZ: "TanzaniaBankAccount",
      AG: "AntiguaAndBarbudaBankAccount",
      AL: "AlbaniaBankAccount",
      AZ: "AzerbaijanBankAccount",
      BH: "BahrainBankAccount",
      NG: "NigeriaBankAccount",
      JO: "JordanBankAccount",
      IL: "IsraelBankAccount",
      BD: "BangladeshBankAccount",
      BT: "BhutanBankAccount",
      LA: "LaosBankAccount",
      MZ: "MozambiqueBankAccount",
      RO: "RomaniaBankAccount",
      SE: "SwedenBankAccount",
      AR: "ArgentinaBankAccount",
      BW: "BotswanaBankAccount",
      PE: "PeruBankAccount",
      VN: "VietnamBankAccount",
      TW: "TaiwanBankAccount",
      ID: "IndonesiaBankAccount",
      CR: "CostaRicaBankAccount",
      CL: "ChileBankAccount",
      PK: "PakistanBankAccount",
      TR: "TurkeyBankAccount",
      RW: "RwandaBankAccount",
      MO: "MacaoBankAccount",
      BJ: "BeninBankAccount",
      CI: "CoteDIvoireBankAccount",
      MA: "MoroccoBankAccount",
      NO: "NorwayBankAccount",
      AO: "AngolaBankAccount",
      NE: "NigerBankAccount",
      SM: "SanMarinoBankAccount",
      RS: "SerbiaBankAccount",
      ZA: "SouthAfricaBankAccount",
      KE: "KenyaBankAccount",
      EG: "EgyptBankAccount",
      CO: "ColombiaBankAccount",
      ET: "EthiopiaBankAccount",
      BN: "BruneiBankAccount",
      GY: "GuyanaBankAccount",
      GT: "GuatemalaBankAccount",
      SA: "SaudiArabiaBankAccount",
      JP: "JapanBankAccount",
      KZ: "KazakhstanBankAccount",
      EC: "EcuadorBankAccount",
      LI: "LiechtensteinBankAccount",
      MY: "MalaysiaBankAccount",
      GI: "GibraltarBankAccount",
      UY: "UruguayBankAccount",
      MU: "MauritiusBankAccount",
      JM: "JamaicaBankAccount",
      OM: "OmanBankAccount",
      DO: "DominicanRepublicBankAccount",
      MK: "NorthMacedoniaBankAccount",
      UZ: "UzbekistanBankAccount",
      BO: "BoliviaBankAccount",
      TN: "TunisiaBankAccount",
      MD: "MoldovaBankAccount",
      PA: "PanamaBankAccount",
      SV: "ElSalvadorBankAccount",
      MG: "MadagascarBankAccount",
      PY: "ParaguayBankAccount",
      GH: "GhanaBankAccount",
      AM: "ArmeniaBankAccount",
      LK: "SriLankaBankAccount",
      KW: "KuwaitBankAccount",
      IS: "IcelandBankAccount",
      QA: "QatarBankAccount",
      BS: "BahamasBankAccount",
      LC: "SaintLuciaBankAccount",
      SN: "SenegalBankAccount",
      KH: "CambodiaBankAccount",
      MN: "MongoliaBankAccount",
      GA: "GabonBankAccount",
      MC: "MonacoBankAccount",
      DZ: "AlgeriaBankAccount",
    };
    const bankAccountType = user.country_code && countryToBankAccountTypeMapping[user.country_code];
    if (bankAccountType) {
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
      updateBankAccount({ type: bankAccountType } as Partial<BankAccount>);
    } else if (user.is_from_europe) {
      updateBankAccount({ type: "EuropeanBankAccount" });
    }
  }, []);

  return (
    <>
      <div className="whitespace-pre-line">{feeInfoText}</div>
      <section className="override grid gap-8">
        <fieldset className={cx({ danger: errorFieldNames.has("account_holder_full_name") })}>
          <legend>
            <label htmlFor={`${uid}-account-holder-full-name`}>Pay to the order of</label>
          </legend>
          <input
            id={`${uid}-account-holder-full-name`}
            placeholder="Full name of account holder"
            value={bankAccount?.account_holder_full_name || ""}
            disabled={isFormDisabled}
            aria-invalid={errorFieldNames.has("account_holder_full_name")}
            onChange={(evt) => updateBankAccount({ account_holder_full_name: evt.target.value })}
          />
          <small>Must exactly match the name on your bank account</small>
        </fieldset>
        <div className="override grid gap-2">
          {showNewBankAccount ? (
            <div className="override grid gap-5 md:auto-cols-fr md:grid-flow-col">
              {user.country_code === "CA" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("transit_number") })}>
                    <legend>
                      <label htmlFor={`${uid}-transit-number`}>Transit #</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-transit-number`}
                      placeholder="12345"
                      maxLength={5}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("transit_number")}
                      onChange={(evt) => updateBankAccount({ transit_number: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("institution_number") })}>
                    <legend>
                      <label htmlFor={`${uid}-institution-number`}>Institution #</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-institution-number`}
                      placeholder="000"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("institution_number")}
                      onChange={(evt) => updateBankAccount({ institution_number: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "AU" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bsb_number") })}>
                  <legend>
                    <label htmlFor={`${uid}-bsb-number`}>BSB</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bsb-number`}
                    placeholder="123456"
                    maxLength={6}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bsb_number")}
                    onChange={(evt) => updateBankAccount({ bsb_number: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "GB" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("sort_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-sort-code`}>Sort code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-sort-code`}
                    placeholder="12-34-56"
                    maxLength={8}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("sort_code")}
                    onChange={(evt) => updateBankAccount({ sort_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "IN" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("ifsc") })}>
                  <legend>
                    <label htmlFor={`${uid}-ifsc`}>IFSC</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-ifsc`}
                    placeholder="ICIC0123456"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("ifsc")}
                    onChange={(evt) => updateBankAccount({ ifsc: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "HK" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("clearing_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-clearing-code`}>Clearing Code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-clearing-code`}
                      placeholder="123"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("clearing_code")}
                      onChange={(evt) => updateBankAccount({ clearing_code: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-branch-code`}>Branch code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-branch-code`}
                      placeholder="456"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("branch_code")}
                      onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "SG" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="1234"
                      maxLength={4}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-branch-code`}>Branch code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-branch-code`}
                      placeholder="567"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("branch_code")}
                      onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "JP" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="1234"
                      maxLength={4}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-branch-code`}>Branch code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-branch-code`}
                      placeholder="567"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("branch_code")}
                      onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "TH" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="123"
                    maxLength={3}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "KR" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="ABCDKR00123"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "VN" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="01101100"
                    maxLength={8}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "TW" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAATWTXXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "ID" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="000"
                    maxLength={4}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "MA" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAMAMAXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "RS" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="BKCHRSBG"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "TT" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="123"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-branch-code`}>Branch code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-branch-code`}
                      placeholder="45678"
                      maxLength={5}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("branch_code")}
                      onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "JM" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="111"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-branch-code`}>Branch code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-branch-code`}
                      placeholder="00000"
                      maxLength={5}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("branch_code")}
                      onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "UY" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="091"
                    maxLength={3}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "AG" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAAGAGXYZ"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "LC" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAALCLCXYZ"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "TZ" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAATZTXXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "NA" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAANANXXYZ"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "PH" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank Identifier Code (BIC)</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="12345678901"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "ZA" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="FIRNZAJJ"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "KE" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="BARCKENXMDR"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "MY" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="HBMBMYKL"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "CL" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("account_type") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-account-type`}>Bank account type</label>
                    </legend>
                    <select
                      id={`${uid}-bank-account-type`}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("account_type")}
                      onChange={(evt) => updateBankAccount({ account_type: evt.target.value })}
                      value={(bankAccount?.type === "ChileBankAccount" && bankAccount.account_type) || "Select"}
                    >
                      <option disabled>Select</option>
                      <option key="checking" value="checking">
                        Checking
                      </option>
                      <option key="savings" value="savings">
                        Savings
                      </option>
                    </select>
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="123"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "CO" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("account_type") })}>
                    <legend>
                      <label htmlFor={`${uid}-account-type`}>Account Type</label>
                    </legend>
                    <select
                      id={`${uid}-account-type`}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("account_type")}
                      onChange={(evt) => updateBankAccount({ account_type: evt.target.value })}
                      value={(bankAccount?.type === "ColombiaBankAccount" && bankAccount.account_type) || "Select"}
                    >
                      <option disabled>Select</option>
                      <option key="savings" value="savings">
                        Savings
                      </option>
                      <option key="checking" value="checking">
                        Checking
                      </option>
                    </select>
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank Code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="060"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "RW" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAARWRWXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "EC" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAECE1XXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "BW" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAABWBWXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "OM" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAOMOMXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "PY" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="27"
                    maxLength={2}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "MG" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAMGMGXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "GH" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="022112"
                    maxLength={6}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "US" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("routing_number") })}>
                  <legend>
                    <label htmlFor={`${uid}-routing-number`}>Routing number</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-routing-number`}
                    placeholder="121000497"
                    maxLength={9}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("routing_number")}
                    onChange={(evt) => updateBankAccount({ routing_number: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "MD" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAMDMDXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "PA" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAPAPAXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "DO" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="021"
                      maxLength={3}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-branch-code`}>Branch code (optional)</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-branch-code`}
                      placeholder="4232"
                      maxLength={5}
                      disabled={isFormDisabled}
                      onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "UZ" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="AAAAUZUZXXX"
                      maxLength={11}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-branch-code`}>Branch code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-branch-code`}
                      placeholder="00000"
                      maxLength={5}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("branch_code")}
                      onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "BO" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="060"
                    maxLength={3}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "NG" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAANGLAXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "AM" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAAMNNXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "LK" ? (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-bank-code`}
                      placeholder="AAAALKLXXXX"
                      maxLength={11}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("bank_code")}
                      onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                    <legend>
                      <label htmlFor={`${uid}-branch-code`}>Branch code</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-branch-code`}
                      placeholder="7010999"
                      maxLength={7}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("branch_code")}
                      onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : user.country_code === "ET" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAETETXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "BN" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAABNBBXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "GY" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAGYGGXYZ"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "MK" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAMK2XXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "BD" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>Bank Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="110000000"
                    maxLength={9}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "BT" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAABTBTXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "LA" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAALALAXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "MZ" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAMZMXXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "QA" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="QNBAQAQAXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "GA" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAGAGAXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "BS" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAABSNSXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "KH" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAKHPPXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "MN" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAMNUBXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "DZ" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAADZDZXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : user.country_code === "MO" ? (
                <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                  <legend>
                    <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                  </legend>
                  <input
                    type="text"
                    id={`${uid}-bank-code`}
                    placeholder="AAAAMOMXXXX"
                    maxLength={11}
                    required
                    disabled={isFormDisabled}
                    aria-invalid={errorFieldNames.has("bank_code")}
                    onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                  />
                </fieldset>
              ) : null}
              {user.country_supports_iban ? (
                <>
                  {user.country_code === "PK" || user.country_code === "TR" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAAPKKAXXX"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "GT" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAAGTGCXYZ"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "BA" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="BIHBAHBOS"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "EG" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="NBEGEGCX331"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "SA" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="NCBKSAJE101"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "MU" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAAMUMUXYZ"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "KZ" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAAKZKZXXX"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "SV" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAASVS1XXX"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "AL" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAAALTXXXX"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "BH" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAABHBMXYZ"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "JO" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAAJOJOXXX"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "AZ" ? (
                    <>
                      <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                        <legend>
                          <label htmlFor={`${uid}-bank-code`}>Bank code</label>
                        </legend>
                        <input
                          type="text"
                          id={`${uid}-bank-code`}
                          placeholder="123456"
                          maxLength={6}
                          required
                          disabled={isFormDisabled}
                          aria-invalid={errorFieldNames.has("bank_code")}
                          onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                        />
                      </fieldset>
                      <fieldset className={cx({ danger: errorFieldNames.has("branch_code") })}>
                        <legend>
                          <label htmlFor={`${uid}-branch-code`}>Branch code</label>
                        </legend>
                        <input
                          type="text"
                          id={`${uid}-branch-code`}
                          placeholder="123456"
                          maxLength={6}
                          required
                          disabled={isFormDisabled}
                          aria-invalid={errorFieldNames.has("branch_code")}
                          onChange={(evt) => updateBankAccount({ branch_code: evt.target.value })}
                        />
                      </fieldset>
                    </>
                  ) : user.country_code === "AO" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAAAOAOXXX"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "SM" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAASMSMXXX"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : user.country_code === "KW" ? (
                    <fieldset className={cx({ danger: errorFieldNames.has("bank_code") })}>
                      <legend>
                        <label htmlFor={`${uid}-bank-code`}>SWIFT / BIC Code</label>
                      </legend>
                      <input
                        type="text"
                        id={`${uid}-bank-code`}
                        placeholder="AAAAKWKWXYZ"
                        maxLength={11}
                        required
                        disabled={isFormDisabled}
                        aria-invalid={errorFieldNames.has("bank_code")}
                        onChange={(evt) => updateBankAccount({ bank_code: evt.target.value })}
                      />
                    </fieldset>
                  ) : null}
                  <fieldset className={cx({ danger: errorFieldNames.has("account_number") })}>
                    <legend>
                      <label htmlFor={`${uid}-account-number`}>IBAN</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-account-number`}
                      placeholder={`${user.country_code || ""}1234567890`}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("account_number")}
                      onChange={(evt) => updateBankAccount({ account_number: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("account_number_confirmation") })}>
                    <legend>
                      <label htmlFor={`${uid}-confirm-account-number`}>Confirm IBAN</label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-confirm-account-number`}
                      placeholder={`${user.country_code || ""}1234567890`}
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("account_number_confirmation")}
                      onChange={(evt) => updateBankAccount({ account_number_confirmation: evt.target.value })}
                    />
                  </fieldset>
                </>
              ) : (
                <>
                  <fieldset className={cx({ danger: errorFieldNames.has("account_number") })}>
                    <legend>
                      <label htmlFor={`${uid}-account-number`}>
                        {user.country_code && ["US", "MX", "AR", "PE"].includes(user.country_code)
                          ? "Account number"
                          : "Account #"}
                      </label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-account-number`}
                      placeholder="1234567890"
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("account_number")}
                      onChange={(evt) => updateBankAccount({ account_number: evt.target.value })}
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: errorFieldNames.has("account_number_confirmation") })}>
                    <legend>
                      <label htmlFor={`${uid}-confirm-account-number`}>
                        {user.country_code && ["US", "MX", "AR", "PE"].includes(user.country_code)
                          ? "Confirm account number"
                          : "Confirm account #"}
                      </label>
                    </legend>
                    <input
                      type="text"
                      id={`${uid}-confirm-account-number`}
                      placeholder="1234567890"
                      required
                      disabled={isFormDisabled}
                      aria-invalid={errorFieldNames.has("account_number_confirmation")}
                      onChange={(evt) => updateBankAccount({ account_number_confirmation: evt.target.value })}
                    />
                  </fieldset>
                </>
              )}
            </div>
          ) : (
            <>
              <section
                style={{ display: "grid", gap: "var(--spacer-5)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}
              >
                {bankAccountDetails.routing_number !== null && (
                  <fieldset>
                    <legend>
                      <label htmlFor={`${uid}-saved-routing-number`}>
                        {getRoutingNumberLabel(user.country_code || "")}
                      </label>
                    </legend>
                    <input
                      id={`${uid}-saved-routing-number`}
                      disabled
                      value={bankAccountDetails.routing_number || ""}
                    />
                  </fieldset>
                )}
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-saved-account-number`}>Account number</label>
                  </legend>
                  <input
                    id={`${uid}-saved-account-number`}
                    disabled
                    value={bankAccountDetails.account_number_visual || ""}
                  />
                </fieldset>
              </section>
              <div>
                <Button disabled={isFormDisabled} onClick={() => setShowNewBankAccount(true)}>
                  Change account
                </Button>
              </div>
            </>
          )}
          <div className="text-muted text-sm">
            Payouts will be made in {user.payout_currency?.toUpperCase() || "your local currency"}.
          </div>
        </div>
      </section>

      {hasConnectedStripe ? (
        <section>
          <div role="alert" className="warning">
            You cannot change your payout method to bank account because you have a stripe account connected.
          </div>
        </section>
      ) : null}
    </>
  );
};
export default BankAccountSection;
