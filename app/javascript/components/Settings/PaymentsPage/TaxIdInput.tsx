import * as React from "react";

interface TaxIdInputProps {
  country: string | null;
  uid: string;
  value: string | null;
  isEntered: boolean;
  isFormDisabled: boolean;
  hasError: boolean;
  onChange: (value: string) => void;
  required?: boolean;
  needFullSsn?: boolean;
}

const TaxIdInput: React.FC<TaxIdInputProps> = ({
  country,
  uid,
  value,
  isEntered,
  isFormDisabled,
  hasError,
  onChange,
  required = false,
  needFullSsn = false,
}) => {
  const getTaxIdConfig = (country: string) => {
    switch (country) {
      case "US":
        return {
          id: "social-security-number",
          label: "Social Security Number",
          placeholder: isEntered ? "Hidden for security" : "•••-••-••••",
          minLength: 9,
          maxLength: 11,
        };
      case "CA":
        return {
          id: "social-insurance-number",
          label: "Social Insurance Number",
          placeholder: isEntered ? "Hidden for security" : "•••••••••",
          minLength: 9,
          maxLength: 9,
        };
      case "CO":
        return {
          id: "colombia-id-number",
          label: "Cédula de Ciudadanía (CC)",
          placeholder: isEntered ? "Hidden for security" : "1.123.123.123",
          minLength: 13,
          maxLength: 13,
        };
      case "UY":
        return {
          id: "uruguay-id-number",
          label: "Cédula de Identidad (CI)",
          placeholder: isEntered ? "Hidden for security" : "1.123.123-1",
          minLength: 11,
          maxLength: 11,
        };
      case "HK":
        return {
          id: "hong-kong-id-number",
          label: "Hong Kong ID Number",
          placeholder: isEntered ? "Hidden for security" : "123456789",
          minLength: 8,
          maxLength: 9,
        };
      case "SG":
        return {
          id: "singapore-id-number",
          label: "NRIC number / FIN",
          placeholder: isEntered ? "Hidden for security" : "123456789",
          minLength: 9,
          maxLength: 9,
        };
      case "AE":
        return {
          id: "uae-id-number",
          label: "Emirates ID",
          placeholder: isEntered ? "Hidden for security" : "123456789123456",
          minLength: 15,
          maxLength: 15,
        };
      case "MX":
        return {
          id: "mexico-id-number",
          label: "Personal RFC",
          placeholder: isEntered ? "Hidden for security" : "1234567891234",
          minLength: 13,
          maxLength: 13,
        };
      case "KZ":
        return {
          id: "kazakhstan-id-number",
          label: "Individual identification number (IIN)",
          placeholder: isEntered ? "Hidden for security" : "123456789",
          minLength: 9,
          maxLength: 12,
        };
      case "AR":
        return {
          id: "argentina-id-number",
          label: "CUIL",
          placeholder: isEntered ? "Hidden for security" : "12-12345678-1",
          minLength: 13,
          maxLength: 13,
        };
      case "PE":
        return {
          id: "peru-id-number",
          label: "DNI number",
          placeholder: isEntered ? "Hidden for security" : "12345678-9",
          minLength: 10,
          maxLength: 10,
        };
      case "PK":
        return {
          id: "snic",
          label: "National Identity Card Number (SNIC or CNIC)",
          placeholder: isEntered ? "Hidden for security" : "•••••••••",
          minLength: 13,
          maxLength: 13,
        };
      case "CR":
        return {
          id: "costa-rica-id-number",
          label: "Tax Identification Number",
          placeholder: isEntered ? "Hidden for security" : "1234567890",
          minLength: 9,
          maxLength: 12,
        };
      case "CL":
        return {
          id: "chile-id-number",
          label: "Rol Único Tributario (RUT)",
          placeholder: isEntered ? "Hidden for security" : "123456789",
          minLength: 8,
          maxLength: 9,
        };
      case "DO":
        return {
          id: "dominican-republic-id-number",
          label: "Cédula de identidad y electoral (CIE)",
          placeholder: isEntered ? "Hidden for security" : "123-1234567-1",
          minLength: 13,
          maxLength: 13,
        };
      case "BO":
        return {
          id: "bolivia-id-number",
          label: "Cédula de Identidad (CI)",
          placeholder: isEntered ? "Hidden for security" : "12345678",
          minLength: 8,
          maxLength: 8,
        };
      case "PY":
        return {
          id: "paraguay-id-number",
          label: "Cédula de Identidad (CI)",
          placeholder: isEntered ? "Hidden for security" : "1234567",
          minLength: 7,
          maxLength: 7,
        };
      case "BD":
        return {
          id: "bangladesh-id-number",
          label: "Personal ID number",
          placeholder: isEntered ? "Hidden for security" : "123456789",
          minLength: 1,
          maxLength: 20,
        };
      case "MZ":
        return {
          id: "mozambique-id-number",
          label: "Mozambique Taxpayer Single ID Number (NUIT)",
          placeholder: isEntered ? "Hidden for security" : "123456789",
          minLength: 9,
          maxLength: 9,
        };
      case "GT":
        return {
          id: "guatemala-id-number",
          label: "Número de Identificación Tributaria (NIT)",
          placeholder: isEntered ? "Hidden for security" : "1234567-8",
          minLength: 8,
          maxLength: 12,
        };
      case "BR":
        return {
          id: "brazil-id-number",
          label: "Cadastro de Pessoas Físicas (CPF)",
          placeholder: isEntered ? "Hidden for security" : "123.456.789-00",
          minLength: 11,
          maxLength: 14,
        };
      default:
        return {
          id: "tax-id",
          label: "Tax ID",
          placeholder: isEntered ? "Hidden for security" : "•••••••••",
          minLength: undefined,
          maxLength: undefined,
        };
    }
  };

  const getUsTaxIdConfig = (needFullSsn: boolean) => {
    if (needFullSsn) {
      return {
        id: "social-security-number-full",
        label: "Social Security Number",
        placeholder: isEntered ? "Hidden for security" : "•••-••-••••",
        minLength: 9,
        maxLength: 11,
      };
    }
    return {
      id: "social-security-number",
      label: "Last 4 digits of SSN",
      placeholder: isEntered ? "Hidden for security" : "••••",
      minLength: 4,
      maxLength: 4,
    };
  };

  if (!country) {
    return null;
  }

  const config = country === "US" ? getUsTaxIdConfig(needFullSsn) : getTaxIdConfig(country);

  return (
    <div>
      <legend>
        <label htmlFor={`${uid}-${config.id}`}>{config.label}</label>
      </legend>
      <input
        id={`${uid}-${config.id}`}
        type="text"
        minLength={config.minLength}
        maxLength={config.maxLength}
        placeholder={config.placeholder}
        required={required}
        disabled={isFormDisabled}
        aria-invalid={hasError}
        value={value || ""}
        onChange={(e) => onChange(e.target.value)}
      />
    </div>
  );
};

export default TaxIdInput;
