import React from "react";

import { formatDate } from "$app/utils/date";

import { NoIcon, YesIcon } from "$app/components/Admin/Icons";
import type { User } from "$app/components/Admin/Users/User";

export type ComplianceInfoProps = {
  is_business: boolean | null;
  first_name: string | null;
  last_name: string | null;
  street_address: string | null;
  city: string | null;
  state: string | null;
  state_code: string | null;
  zip_code: string | null;
  country: string | null;
  country_code: string | null;
  has_individual_tax_id: boolean;
  business_name: string | null;
  business_type: string | null;
  business_street_address: string | null;
  business_city: string | null;
  business_state: string | null;
  business_zip_code: string | null;
  business_country: string | null;
  has_business_tax_id: boolean;
  created_at: string;
};

type AdminUserComplianceInfoProps = {
  user: User;
};

type ComplianceInfoComponentProps = {
  complianceInfo: ComplianceInfoProps | null;
};

const ComplianceInfo = ({ complianceInfo }: ComplianceInfoComponentProps) => {
  if (!complianceInfo) return <div>No compliance info found.</div>;

  const {
    is_business,
    first_name,
    last_name,
    street_address,
    city,
    state,
    state_code,
    zip_code,
    country,
    country_code,
    has_individual_tax_id,
    business_name,
    business_type,
    business_street_address,
    business_city,
    business_state,
    business_zip_code,
    business_country,
    has_business_tax_id,
    created_at,
  } = complianceInfo;

  return (
    <div className="grid gap-4 md:grid-cols-2">
      <div className="paragraphs">
        <h3>Personal Info</h3>
        <dl>
          <dt>Is Business</dt>
          <dd>{is_business ? <YesIcon /> : <NoIcon />}</dd>

          <dt>First Name</dt>
          <dd>{first_name}</dd>

          <dt>Last Name</dt>
          <dd>{last_name}</dd>

          <dt>Join Date</dt>
          <dd>{formatDate(new Date(created_at))}</dd>

          <dt>Address Street</dt>
          <dd>{street_address}</dd>

          <dt>Address City</dt>
          <dd>{city}</dd>

          <dt>Address State</dt>
          <dd>
            {state}
            {state_code ? ` (${state_code})` : null}
          </dd>

          <dt>Address Zip</dt>
          <dd>{zip_code}</dd>

          <dt>Address Country</dt>
          <dd>
            {country}
            {country_code ? ` (${country_code})` : null}
          </dd>

          <dt>Individual Tax ID Provided</dt>
          <dd>{has_individual_tax_id ? <YesIcon /> : <NoIcon />}</dd>
        </dl>
      </div>

      {is_business ? (
        <div className="paragraphs">
          <h4 className="font-bold">Business Info</h4>
          <dl>
            <dt>Name</dt>
            <dd>{business_name}</dd>

            <dt>Street Address</dt>
            <dd>{business_street_address}</dd>

            <dt>City</dt>
            <dd>{business_city}</dd>

            <dt>State</dt>
            <dd>{business_state}</dd>

            <dt>Zip</dt>
            <dd>{business_zip_code}</dd>

            <dt>Country</dt>
            <dd>{business_country}</dd>

            <dt>Type</dt>
            <dd>{business_type}</dd>

            <dt>Tax ID Provided</dt>
            <dd>{has_business_tax_id ? <YesIcon /> : <NoIcon />}</dd>
          </dl>
        </div>
      ) : null}
    </div>
  );
};

const AdminUserComplianceInfo = ({ user }: AdminUserComplianceInfoProps) => (
  <>
    <hr />
    <ComplianceInfo complianceInfo={user.alive_user_compliance_info} />
  </>
);

export default AdminUserComplianceInfo;
