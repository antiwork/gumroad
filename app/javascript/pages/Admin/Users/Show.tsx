import React, { useState } from 'react';
import { router, Link } from '@inertiajs/react';

// Type Definitions
interface User {
  id: number;
  external_id: string;
  name: string | null;
  username: string;
  email: string;
  form_email: string | null;
  support_email: string | null;
  avatar_url: string;
  bio: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  verified: boolean;
  user_risk_state: 'not_reviewed' | 'compliant' | 'flagged_for_fraud' | 'suspended_for_fraud' | 'flagged_for_tos_violation' | 'suspended_for_tos_violation' | 'on_probation';
  all_adult_products: boolean;
  custom_fee_per_thousand: number | null;
  unpaid_balance_cents: number;
  disable_paypal_sales: boolean;
  subdomain_with_protocol: string | null;
  tos_violation_reason: string | null;
  can_impersonate: boolean;
  has_payments: boolean;
  payment_address: string | null;
  payouts_paused_by_source: string | null;
  payouts_paused_for_reason: string | null;
}

interface Product {
  id: number;
  unique_permalink: string;
  name: string;
  price_formatted: string;
  preview_url: string | null;
  long_url: string;
  created_at: string;
  alive: boolean;
  deleted_at: string | null;
  user_id: number;
}

interface UserMembership {
  id: number;
  seller_id: number;
  seller_name: string;
  seller_avatar_url: string;
  role: string;
  last_accessed_at: string | null;
  created_at: string;
}

interface BankAccount {
  type: string;
  account_holder_full_name: string;
  formatted_account: string;
}

interface MerchantAccount {
  id: number;
  charge_processor_id: string;
  charge_processor_merchant_id: string | null;
  alive: boolean;
  charge_processor_alive: boolean;
}

interface ComplianceInfo {
  is_business: boolean;
  first_name: string | null;
  last_name: string | null;
  street_address: string | null;
  city: string | null;
  state: string | null;
  state_code: string | null;
  zip_code: string | null;
  country: string | null;
  country_code: string | null;
  individual_tax_id_provided: boolean;
  business_name: string | null;
  business_street_address: string | null;
  business_city: string | null;
  business_state: string | null;
  business_zip_code: string | null;
  business_country: string | null;
  business_type: string | null;
  business_tax_id_provided: boolean;
}

interface Post {
  id: number;
  name: string;
  url: string | null;
  created_at: string;
}

interface Comment {
  id: number;
  content: string;
  author_name: string;
  comment_type: string;
  created_at: string;
}

interface EmailVersion {
  field: string;
  old_value: string | null;
  new_value: string | null;
  created_at: string;
}

interface PagyInfo {
  page: number;
  pages: number;
  count: number;
  prev: number | null;
  next: number | null;
}

interface Props {
  user: User;
  products: Product[];
  pagy: PagyInfo;
  is_affiliate_user: boolean;
  user_memberships: UserMembership[];
  active_bank_account: BankAccount | null;
  merchant_accounts: MerchantAccount[];
  compliance_info: ComplianceInfo | null;
  last_posts: Post[];
  comments: Comment[];
  email_versions: EmailVersion[];
  stripe_account_exists: boolean;
  manual_payout_eligible: boolean;
  stripe_payable_data: {
    unpaid_balance_held_by_gumroad: string;
    unpaid_balance_held_by_stripe: string;
  } | null;
  paypal_payable_data: {
    should_payout_be_split: boolean;
    split_payment_by_cents: number;
  } | null;
  manual_payout_period_end_date: string | null;
  currency: string | null;
}

export default function Show({
  user,
  products,
  pagy,
  is_affiliate_user,
  user_memberships,
  active_bank_account,
  merchant_accounts,
  compliance_info,
  last_posts,
  comments,
  email_versions,
  stripe_account_exists,
  manual_payout_eligible,
}: Props) {
  const [activeTab, setActiveTab] = useState<'profile' | 'products'>(
    pagy.page >= 2 ? 'products' : 'profile'
  );
  const [processingAction, setProcessingAction] = useState<string | null>(null);

  const userDisplayName = user.name || `User ${user.id}`;

  const handleAction = async (
    url: string,
    method: 'post' | 'put' | 'delete' = 'post',
    confirmMessage?: string,
    data?: Record<string, any>
  ) => {
    if (confirmMessage && !confirm(confirmMessage)) {
      return;
    }

    setProcessingAction(url);

    const visitOptions: any = {
      method,
      preserveScroll: true,
      onFinish: () => setProcessingAction(null),
      onError: (errors: any) => {
        alert(Object.values(errors).join('\n'));
      },
    };

    if (data) {
      visitOptions.data = data;
    }

    router.visit(url, visitOptions);
  };

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900">
      {/* Header */}
      <div className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center space-x-4">
              <Link
                href="/admin"
                className="text-gray-600 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"
              >
                <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 19l-7-7m0 0l7-7m-7 7h18" />
                </svg>
              </Link>
              <h1 className="text-2xl font-bold text-gray-900 dark:text-gray-100">
                {userDisplayName}
              </h1>
              {user.deleted_at && (
                <span className="px-3 py-1 text-sm font-medium text-red-800 bg-red-100 rounded-full">
                  Deleted
                </span>
              )}
              <RiskBadge riskState={user.user_risk_state} />
            </div>
          </div>
        </div>
      </div>

      {/* Deleted Alert */}
      {user.deleted_at && (
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 mt-4">
          <div className="bg-red-50 border border-red-200 rounded-lg p-4">
            <div className="flex">
              <div className="flex-shrink-0">
                <svg className="h-5 w-5 text-red-400" viewBox="0 0 20 20" fill="currentColor">
                  <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clipRule="evenodd" />
                </svg>
              </div>
              <div className="ml-3">
                <h3 className="text-sm font-medium text-red-800">
                  Account Deleted
                </h3>
                <div className="mt-2 text-sm text-red-700">
                  This user account was deleted on <DateDisplay date={user.deleted_at} />.
                </div>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Tabs */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 mt-6">
        <div className="border-b border-gray-200">
          <nav className="-mb-px flex space-x-8" aria-label="Tabs">
            <button
              onClick={() => setActiveTab('profile')}
              className={`${
                activeTab === 'profile'
                  ? 'border-blue-500 text-blue-600'
                  : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'
              } whitespace-nowrap py-4 px-1 border-b-2 font-medium text-sm transition-colors`}
            >
              Profile
            </button>
            <button
              onClick={() => setActiveTab('products')}
              className={`${
                activeTab === 'products'
                  ? 'border-blue-500 text-blue-600'
                  : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'
              } whitespace-nowrap py-4 px-1 border-b-2 font-medium text-sm transition-colors`}
            >
              Products
            </button>
          </nav>
        </div>
      </div>

      {/* Content */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        {activeTab === 'profile' ? (
          <ProfileTab
            user={user}
            userDisplayName={userDisplayName}
            isAffiliateUser={is_affiliate_user}
            userMemberships={user_memberships}
            activeBankAccount={active_bank_account}
            merchantAccounts={merchant_accounts}
            complianceInfo={compliance_info}
            lastPosts={last_posts}
            comments={comments}
            emailVersions={email_versions}
            stripeAccountExists={stripe_account_exists}
            manualPayoutEligible={manual_payout_eligible}
            processingAction={processingAction}
            onAction={handleAction}
          />
        ) : (
          <ProductsTab
            products={products}
            pagy={pagy}
            userId={user.id}
          />
        )}
      </div>
    </div>
  );
}

// Profile Tab Component
function ProfileTab({
  user,
  userDisplayName,
  isAffiliateUser,
  userMemberships,
  activeBankAccount,
  merchantAccounts,
  complianceInfo,
  lastPosts,
  comments,
  emailVersions,
  stripeAccountExists,
  manualPayoutEligible,
  processingAction,
  onAction,
}: {
  user: User;
  userDisplayName: string;
  isAffiliateUser: boolean;
  userMemberships: UserMembership[];
  activeBankAccount: BankAccount | null;
  merchantAccounts: MerchantAccount[];
  complianceInfo: ComplianceInfo | null;
  lastPosts: Post[];
  comments: Comment[];
  emailVersions: EmailVersion[];
  stripeAccountExists: boolean;
  manualPayoutEligible: boolean;
  processingAction: string | null;
  onAction: (url: string, method?: 'post' | 'put' | 'delete', confirmMessage?: string, data?: any) => void;
}) {
  return (
    <div className="space-y-6">
      {/* User Card */}
      <UserCard
        user={user}
        userDisplayName={userDisplayName}
        isAffiliateUser={isAffiliateUser}
        processingAction={processingAction}
        onAction={onAction}
      />

      {/* User Memberships */}
      {userMemberships.length > 0 && (
        <CollapsibleSection title="User memberships">
          <div className="space-y-4">
            {userMemberships.map((membership) => (
              <div key={membership.id} className="flex items-center justify-between">
                <div className="flex items-center space-x-4">
                  <img
                    src={membership.seller_avatar_url}
                    alt={membership.seller_name}
                    className="w-12 h-12 rounded-full"
                  />
                  <div>
                    <h5 className="font-medium text-gray-900">
                      <Link
                        href={`/admin/users/${membership.seller_id}`}
                        className="text-blue-600 hover:text-blue-800"
                      >
                        {membership.seller_name}
                      </Link>
                    </h5>
                    <div className="text-sm text-gray-500">{membership.role}</div>
                  </div>
                </div>
                <div className="text-right text-sm text-gray-500">
                  {membership.last_accessed_at && (
                    <div>last accessed <DateDisplay date={membership.last_accessed_at} /></div>
                  )}
                  <div>invited <DateDisplay date={membership.created_at} /></div>
                </div>
              </div>
            ))}
          </div>
        </CollapsibleSection>
      )}

      {/* Risk Management */}
      <RiskManagementSection
        user={user}
        processingAction={processingAction}
        onAction={onAction}
      />

      {/* Payout Info */}
      <PayoutSection
        user={user}
        activeBankAccount={activeBankAccount}
        merchantAccounts={merchantAccounts}
        stripeAccountExists={stripeAccountExists}
        manualPayoutEligible={manualPayoutEligible}
        processingAction={processingAction}
        onAction={onAction}
      />

      {/* Compliance Info */}
      {complianceInfo && (
        <ComplianceInfoSection complianceInfo={complianceInfo} userCreatedAt={user.created_at} />
      )}

      {/* Forms */}
      <FormsSection user={user} />

      {/* Bio */}
      <CollapsibleSection title="Bio">
        {user.bio ? (
          <div className="prose max-w-none text-gray-700">{user.bio}</div>
        ) : (
          <div className="text-gray-500 italic">No bio provided.</div>
        )}
      </CollapsibleSection>

      {/* Last Posts */}
      <CollapsibleSection title="Last posts">
        {lastPosts.length > 0 ? (
          <div className="space-y-3">
            {lastPosts.map((post) => (
              <div key={post.id}>
                <h5 className="font-medium text-gray-900">
                  {post.url && !user.deleted_at ? (
                    <a href={post.url} className="text-blue-600 hover:text-blue-800" target="_blank" rel="noopener noreferrer">
                      {post.name}
                    </a>
                  ) : (
                    post.name
                  )}
                </h5>
                <div className="text-sm text-gray-500">
                  <DateDisplay date={post.created_at} />
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div className="text-gray-500 italic">No posts created.</div>
        )}
      </CollapsibleSection>

      {/* Email Changes */}
      <CollapsibleSection title="Email changes">
        {emailVersions.length > 0 ? (
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-gray-200">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Field</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Old</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">New</th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Changed</th>
                </tr>
              </thead>
              <tbody className="bg-white divide-y divide-gray-200">
                {emailVersions.map((version, idx) => (
                  <tr key={idx}>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">{version.field}</td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">{version.old_value || '-'}</td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">{version.new_value || '-'}</td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                      <DateDisplay date={version.created_at} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="text-gray-500 italic">No email changes recorded.</div>
        )}
      </CollapsibleSection>

      {/* Comments */}
      <CommentsSection comments={comments} />

      {/* Timestamps */}
      <div className="bg-white rounded-lg shadow p-6">
        <dl className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <div>
            <dt className="text-sm font-medium text-gray-500">Created</dt>
            <dd className="mt-1 text-sm text-gray-900">
              <DateDisplay date={user.created_at} />
            </dd>
          </div>
          <div>
            <dt className="text-sm font-medium text-gray-500">Updated</dt>
            <dd className="mt-1 text-sm text-gray-900">
              <DateDisplay date={user.updated_at} />
            </dd>
          </div>
          <div>
            <dt className="text-sm font-medium text-gray-500">Deleted</dt>
            <dd className="mt-1 text-sm text-gray-900">
              {user.deleted_at ? <DateDisplay date={user.deleted_at} /> : '✗'}
            </dd>
          </div>
        </dl>
      </div>
    </div>
  );
}

// User Card Component
function UserCard({
  user,
  userDisplayName,
  isAffiliateUser,
  processingAction,
  onAction,
}: {
  user: User;
  userDisplayName: string;
  isAffiliateUser: boolean;
  processingAction: string | null;
  onAction: (url: string, method?: 'post' | 'put' | 'delete', confirmMessage?: string) => void;
}) {
  const displayEmail = user.form_email || user.email;
  const customFeePercent = user.custom_fee_per_thousand ? (user.custom_fee_per_thousand / 10.0).toFixed(1) : null;

  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="space-y-6">
        {/* Header */}
        <div className="flex items-start space-x-4">
          <img
            src={user.avatar_url}
            alt={userDisplayName}
            className="w-16 h-16 rounded-full"
          />
          <div className="flex-1 min-w-0">
            <h2 className="text-xl font-bold text-gray-900">
              {isAffiliateUser ? (
                <Link
                  href={`/admin/affiliates/${user.id}`}
                  className="text-blue-600 hover:text-blue-800"
                >
                  {userDisplayName}
                </Link>
              ) : (
                <Link
                  href={`/admin/users/${user.id}`}
                  className="text-blue-600 hover:text-blue-800"
                >
                  {userDisplayName}
                </Link>
              )}
            </h2>
            <ul className="mt-2 space-y-1 text-sm text-gray-600">
              <li><DateDisplay date={user.created_at} /></li>
              {user.username && user.subdomain_with_protocol && (
                <li>
                  <a
                    href={user.subdomain_with_protocol}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-blue-600 hover:text-blue-800"
                  >
                    {user.username}
                  </a>
                </li>
              )}
              {displayEmail && (
                <li className="flex items-center space-x-2">
                  <span>Email:</span>
                  <CopyToClipboard text={displayEmail} />
                </li>
              )}
              {user.support_email && (
                <li className="flex items-center space-x-2">
                  <span>Support email:</span>
                  <CopyToClipboard text={user.support_email} />
                </li>
              )}
              {customFeePercent && (
                <li title="Custom fee that will be charged on all their new direct (non-discover) sales">
                  Custom fee: {customFeePercent}%
                </li>
              )}
              {user.has_payments && (
                <li>
                  <Link
                    href={`/admin/users/${user.id}/payouts`}
                    className="text-blue-600 hover:text-blue-800"
                  >
                    Payouts
                  </Link>
                </li>
              )}
            </ul>
            {/* User Stats Component Placeholder */}
            <div className="mt-4">
              <div className="text-sm text-gray-500">Loading stats...</div>
            </div>
          </div>
        </div>

        <hr className="border-gray-200" />

        {/* Action Buttons */}
        <div className="flex flex-wrap gap-2">
          {user.can_impersonate ? (
            <Link
              href={`/admin/impersonate?user_identifier=${user.external_id}`}
              className="px-3 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-lg hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Become
            </Link>
          ) : (
            <button
              disabled
              title="User is either deleted, or a team member."
              className="px-3 py-2 text-sm font-medium text-gray-400 bg-gray-100 border border-gray-300 rounded-lg cursor-not-allowed"
            >
              Become
            </button>
          )}

          <ActionButton
            label={user.verified ? 'Unverify' : 'Verify'}
            onClick={() => onAction(
              `/admin/users/${user.id}/verify`,
              'post',
              `Are you sure you want to ${user.verified ? 'unverify' : 'verify'} user ${user.id}?`
            )}
            processing={processingAction === `/admin/users/${user.id}/verify`}
          />

          {user.deleted_at && (
            <ActionButton
              label="Undelete"
              onClick={() => onAction(
                `/admin/users/${user.id}/enable`,
                'post',
                `Are you sure you want to undelete the account of user ${user.id}?`
              )}
              processing={processingAction === `/admin/users/${user.id}/enable`}
            />
          )}

          <ActionButton
            label="Reset password"
            onClick={() => onAction(
              `/admin/users/${user.id}/reset_password`,
              'post',
              `Are you sure you want to reset the password of user ${user.id}?`
            )}
            processing={processingAction === `/admin/users/${user.id}/reset_password`}
          />

          <ActionButton
            label="Confirm email"
            onClick={() => onAction(
              `/admin/users/${user.id}/confirm_email`,
              'post',
              `Are you sure you want to confirm the email address for ${user.id}?`
            )}
            processing={processingAction === `/admin/users/${user.id}/confirm_email`}
          />

          <ActionButton
            label="Sign out from all active sessions"
            onClick={() => onAction(
              `/admin/users/${user.id}/invalidate_active_sessions`,
              'post',
              `Are you sure you want to sign out user ${user.id} from all active sessions?`
            )}
            processing={processingAction === `/admin/users/${user.id}/invalidate_active_sessions`}
          />

          <ActionButton
            label={user.all_adult_products ? 'Unmark as adult' : 'Mark as adult'}
            onClick={() => onAction(
              `/admin/users/${user.id}/toggle_adult_products`,
              'post',
              `Are you sure you want to ${user.all_adult_products ? 'unmark' : 'mark'} user ${user.id} as adult?`
            )}
            processing={processingAction === `/admin/users/${user.id}/toggle_adult_products`}
          />
        </div>
      </div>
    </div>
  );
}

// Risk Management Section
function RiskManagementSection({
  user,
  processingAction,
  onAction,
}: {
  user: User;
  processingAction: string | null;
  onAction: (url: string, method?: 'post' | 'put' | 'delete', confirmMessage?: string) => void;
}) {
  const isCompliant = user.user_risk_state === 'compliant';
  const isFlaggedForFraud = user.user_risk_state === 'flagged_for_fraud';
  const isSuspended = user.user_risk_state === 'suspended_for_fraud' || user.user_risk_state === 'suspended_for_tos_violation';
  const isOnProbation = user.user_risk_state === 'on_probation';

  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="flex items-center justify-between mb-4">
        <div className="flex flex-wrap gap-2">
          {!isCompliant && (
            <ActionButton
              label="Mark compliant"
              onClick={() => onAction(`/admin/users/${user.id}/mark_compliant`, 'post')}
              processing={processingAction === `/admin/users/${user.id}/mark_compliant`}
              variant="success"
            />
          )}

          {isSuspended && user.unpaid_balance_cents > 0 && (
            <ActionButton
              label="Refund balance"
              onClick={() => onAction(
                `/admin/users/${user.id}/refund_balance`,
                'post',
                `Are you sure you want to refund user ${user.id}'s not paid out purchases!?`
              )}
              processing={processingAction === `/admin/users/${user.id}/refund_balance`}
              variant="danger"
            />
          )}

          {!user.disable_paypal_sales && (
            <ActionButton
              label="Disable PayPal sales"
              onClick={() => onAction(`/admin/users/${user.id}/disable_paypal_sales`, 'post')}
              processing={processingAction === `/admin/users/${user.id}/disable_paypal_sales`}
              variant="warning"
            />
          )}
        </div>
        <RiskBadge riskState={user.user_risk_state} />
      </div>

      {/* Flag for Fraud */}
      {!isFlaggedForFraud && !isSuspended && !isOnProbation && (
        <CollapsibleSection title="Flag for fraud">
          <div className="text-sm text-gray-600">
            Flag for fraud form component would go here
          </div>
        </CollapsibleSection>
      )}

      {/* Suspend for Fraud */}
      {(isFlaggedForFraud || isOnProbation) && (
        <CollapsibleSection title="Suspend for fraud">
          <div className="text-sm text-gray-600">
            Suspend for fraud form component would go here
          </div>
        </CollapsibleSection>
      )}

      {/* User GUIDs */}
      <div className="mt-4">
        <h3 className="text-lg font-medium text-gray-900 mb-2">User GUIDs</h3>
        <div className="text-sm text-gray-600">
          User GUIDs component would go here
        </div>
      </div>
    </div>
  );
}

// Payout Section
function PayoutSection({
  user,
  activeBankAccount,
  merchantAccounts,
  stripeAccountExists,
  manualPayoutEligible,
  processingAction,
  onAction,
}: {
  user: User;
  activeBankAccount: BankAccount | null;
  merchantAccounts: MerchantAccount[];
  stripeAccountExists: boolean;
  manualPayoutEligible: boolean;
  processingAction: string | null;
  onAction: (url: string, method?: 'post' | 'put' | 'delete', confirmMessage?: string) => void;
}) {
  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Payout Info */}
        <div className="space-y-4">
          <h3 className="text-lg font-medium text-gray-900">Payout info</h3>
          <div>
            {activeBankAccount ? (
              <span className="text-sm text-gray-700">
                {activeBankAccount.type} / {activeBankAccount.account_holder_full_name} / {activeBankAccount.formatted_account}
              </span>
            ) : user.payment_address ? (
              <span className="text-sm text-gray-700">
                PayPal / {user.payment_address}
              </span>
            ) : (
              <div className="text-sm text-gray-500">
                ✗ This user has no payout method.
              </div>
            )}
          </div>

          <hr className="border-gray-200" />

          {/* Pause Payouts Form */}
          <div className="text-sm text-gray-600">
            Pause payouts form component would go here
          </div>

          {/* Manual Payout */}
          {manualPayoutEligible && (
            <>
              <h3 className="text-lg font-medium text-gray-900 mt-4">Manual Payout</h3>
              <div className="text-sm text-gray-600">
                Manual payout form component would go here
              </div>
            </>
          )}
        </div>

        {/* Merchant Accounts */}
        <div className="space-y-4">
          <h3 className="text-lg font-medium text-gray-900">Merchant Accounts</h3>
          {merchantAccounts.length > 0 ? (
            <ul className="space-y-2">
              {merchantAccounts.map((account) => (
                <li key={account.id} className="flex items-center space-x-2">
                  <Link
                    href={`/admin/merchant_accounts/${account.id}`}
                    className="text-sm text-blue-600 hover:text-blue-800"
                  >
                    {account.id} – {account.charge_processor_id}
                  </Link>
                  <span className="text-sm">
                    {account.alive && account.charge_processor_alive ? '✓' : '✗'}
                  </span>
                </li>
              ))}
            </ul>
          ) : (
            <div className="text-sm text-gray-500">No merchant accounts.</div>
          )}

          {!stripeAccountExists && (
            <ActionButton
              label="Create Managed Account"
              onClick={() => onAction(
                `/admin/users/${user.id}/create_stripe_managed_account`,
                'post',
                `Are you sure you want to create a Stripe Managed Account for user ${user.id}?`
              )}
              processing={processingAction === `/admin/users/${user.id}/create_stripe_managed_account`}
              variant="primary"
            />
          )}
        </div>
      </div>
    </div>
  );
}

// Compliance Info Section
function ComplianceInfoSection({
  complianceInfo,
  userCreatedAt,
}: {
  complianceInfo: ComplianceInfo;
  userCreatedAt: string;
}) {
  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Personal Info */}
        <div>
          <h3 className="text-lg font-medium text-gray-900 mb-4">Personal Info</h3>
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between">
              <dt className="text-gray-500">Is Business</dt>
              <dd className="text-gray-900">{complianceInfo.is_business ? '✓' : '✗'}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">First Name</dt>
              <dd className="text-gray-900">{complianceInfo.first_name || '-'}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Last Name</dt>
              <dd className="text-gray-900">{complianceInfo.last_name || '-'}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Join Date</dt>
              <dd className="text-gray-900">
                <DateDisplay date={userCreatedAt} format="full" />
              </dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Address Street</dt>
              <dd className="text-gray-900">{complianceInfo.street_address || '-'}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Address City</dt>
              <dd className="text-gray-900">{complianceInfo.city || '-'}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Address State</dt>
              <dd className="text-gray-900">
                {complianceInfo.state || '-'}
                {complianceInfo.state_code && ` (${complianceInfo.state_code})`}
              </dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Address Zip</dt>
              <dd className="text-gray-900">{complianceInfo.zip_code || '-'}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Address Country</dt>
              <dd className="text-gray-900">
                {complianceInfo.country && `${complianceInfo.country} (${complianceInfo.country_code})`}
              </dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-gray-500">Individual Tax ID Provided</dt>
              <dd className="text-gray-900">{complianceInfo.individual_tax_id_provided ? '✓' : '✗'}</dd>
            </div>
          </dl>
        </div>

        {/* Business Info */}
        {complianceInfo.is_business && (
          <div>
            <h3 className="text-lg font-medium text-gray-900 mb-4">Business Info</h3>
            <dl className="space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-gray-500">Name</dt>
                <dd className="text-gray-900">{complianceInfo.business_name || '-'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-gray-500">Street Address</dt>
                <dd className="text-gray-900">{complianceInfo.business_street_address || '-'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-gray-500">City</dt>
                <dd className="text-gray-900">{complianceInfo.business_city || '-'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-gray-500">State</dt>
                <dd className="text-gray-900">{complianceInfo.business_state || '-'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-gray-500">Zip</dt>
                <dd className="text-gray-900">{complianceInfo.business_zip_code || '-'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-gray-500">Country</dt>
                <dd className="text-gray-900">{complianceInfo.business_country || '-'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-gray-500">Type</dt>
                <dd className="text-gray-900">{complianceInfo.business_type || '-'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-gray-500">Tax ID Provided</dt>
                <dd className="text-gray-900">{complianceInfo.business_tax_id_provided ? '✓' : '✗'}</dd>
              </div>
            </dl>
          </div>
        )}
      </div>
    </div>
  );
}

// Forms Section
function FormsSection({ user }: { user: User }) {
  const customFeePercent = user.custom_fee_per_thousand ? (user.custom_fee_per_thousand / 10.0) : null;

  return (
    <div className="space-y-4">
      <CollapsibleSection title="Change email">
        <div className="text-sm text-gray-600">
          Change email form component would go here
        </div>
      </CollapsibleSection>

      <CollapsibleSection title="Custom fee">
        <div className="text-sm text-gray-600">
          Custom fee form component would go here (current: {customFeePercent}%)
        </div>
      </CollapsibleSection>

      <CollapsibleSection title="Add credits">
        <div className="text-sm text-gray-600">
          Add credits form component would go here
        </div>
      </CollapsibleSection>

      <CollapsibleSection title="Mass-transfer purchases">
        <div className="text-sm text-gray-600">
          Mass-transfer purchases form component would go here
        </div>
      </CollapsibleSection>
    </div>
  );
}

// Comments Section
function CommentsSection({ comments }: { comments: Comment[] }) {
  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="space-y-4">
        {/* Add Comment Form */}
        <div>
          <h3 className="text-lg font-medium text-gray-900 mb-2">Add Comment</h3>
          <div className="text-sm text-gray-600">
            Add comment form component would go here
          </div>
        </div>

        <hr className="border-gray-200" />

        {/* Comments List */}
        {comments.length > 0 ? (
          <CollapsibleSection title={`${comments.length} comment${comments.length !== 1 ? 's' : ''}`}>
            <div className="space-y-4">
              {comments.map((comment) => (
                <div key={comment.id} className="border-l-4 border-blue-500 pl-4 py-2">
                  <div className="flex items-center justify-between mb-2">
                    <span className="text-sm font-medium text-gray-900">{comment.author_name}</span>
                    <span className="text-xs text-gray-500">
                      <DateDisplay date={comment.created_at} />
                    </span>
                  </div>
                  <p className="text-sm text-gray-700">{comment.content}</p>
                  <span className="inline-block mt-1 px-2 py-1 text-xs text-gray-600 bg-gray-100 rounded">
                    {comment.comment_type}
                  </span>
                </div>
              ))}
            </div>
          </CollapsibleSection>
        ) : (
          <div className="text-gray-500 italic">No comments created.</div>
        )}
      </div>
    </div>
  );
}

// Products Tab Component
function ProductsTab({
  products,
  pagy,
  userId,
}: {
  products: Product[];
  pagy: PagyInfo;
  userId: number;
}) {
  if (products.length === 0) {
    return (
      <div className="bg-white rounded-lg shadow p-6 text-center">
        <div className="text-gray-500 italic">
          No products created.
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {products.map((product) => (
        <ProductCard
          key={product.id}
          product={product}
        />
      ))}

      {/* Pagination */}
      {pagy.pages > 1 && (
        <div className="flex items-center justify-center space-x-2">
          <Link
            href={`/admin/users/${userId}?page=${pagy.prev}`}
            className={`px-4 py-2 text-sm font-medium rounded-lg ${
              pagy.prev
                ? 'text-gray-700 bg-white border border-gray-300 hover:bg-gray-50'
                : 'text-gray-400 bg-gray-100 border border-gray-300 cursor-not-allowed'
            }`}
            preserveScroll
          >
            ‹ Previous
          </Link>

          <div className="flex space-x-1">
            {Array.from({ length: pagy.pages }, (_, i) => i + 1).map((page) => (
              <Link
                key={page}
                href={`/admin/users/${userId}?page=${page}`}
                className={`px-3 py-2 text-sm font-medium rounded-lg ${
                  page === pagy.page
                    ? 'text-white bg-blue-600'
                    : 'text-gray-700 bg-white border border-gray-300 hover:bg-gray-50'
                }`}
                preserveScroll
              >
                {page}
              </Link>
            ))}
          </div>

          <Link
            href={`/admin/users/${userId}?page=${pagy.next}`}
            className={`px-4 py-2 text-sm font-medium rounded-lg ${
              pagy.next
                ? 'text-gray-700 bg-white border border-gray-300 hover:bg-gray-50'
                : 'text-gray-400 bg-gray-100 border border-gray-300 cursor-not-allowed'
            }`}
            preserveScroll
          >
            Next ›
          </Link>
        </div>
      )}
    </div>
  );
}

// Product Card Component
function ProductCard({
  product,
}: {
  product: Product;
}) {
  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="flex items-start space-x-4">
        {product.preview_url && (
          <img
            src={product.preview_url}
            alt={product.name}
            className="w-16 h-16 rounded object-cover"
          />
        )}
        <div className="flex-1">
          <h3 className="text-lg font-medium text-gray-900">
            {product.price_formatted},{' '}
            <Link
              href={`/admin/links/${product.unique_permalink}`}
              className="text-blue-600 hover:text-blue-800"
            >
              {product.name}
            </Link>
            {' '}
            <a
              href={product.long_url}
              target="_blank"
              rel="noopener noreferrer"
              className="text-blue-600 hover:text-blue-800"
            >
              ↗
            </a>
          </h3>
          <div className="mt-2 text-sm text-gray-600">
            <DateDisplay date={product.created_at} />
          </div>
          {!product.alive && (
            <span className="mt-2 inline-block px-2 py-1 text-xs text-red-800 bg-red-100 rounded">
              Unpublished
            </span>
          )}
          {product.deleted_at && (
            <span className="mt-2 inline-block px-2 py-1 text-xs text-red-800 bg-red-100 rounded">
              Deleted
            </span>
          )}
        </div>
      </div>
    </div>
  );
}

// Utility Components

function RiskBadge({ riskState }: { riskState: string }) {
  const colors = {
    compliant: 'bg-green-100 text-green-800',
    not_reviewed: 'bg-gray-100 text-gray-800',
    flagged_for_fraud: 'bg-yellow-100 text-yellow-800',
    flagged_for_tos_violation: 'bg-yellow-100 text-yellow-800',
    suspended_for_fraud: 'bg-red-100 text-red-800',
    suspended_for_tos_violation: 'bg-red-100 text-red-800',
    on_probation: 'bg-orange-100 text-orange-800',
  };

  const color = colors[riskState as keyof typeof colors] || 'bg-gray-100 text-gray-800';
  const label = riskState.replace(/_/g, ' ').replace(/\b\w/g, (l) => l.toUpperCase());

  return (
    <span className={`px-3 py-1 text-sm font-medium rounded-full ${color}`}>
      {label}
    </span>
  );
}

function ActionButton({
  label,
  onClick,
  processing,
  variant = 'default',
}: {
  label: string;
  onClick: () => void;
  processing: boolean;
  variant?: 'default' | 'primary' | 'success' | 'warning' | 'danger';
}) {
  const variants = {
    default: 'text-gray-700 bg-white border-gray-300 hover:bg-gray-50',
    primary: 'text-white bg-blue-600 border-blue-600 hover:bg-blue-700',
    success: 'text-green-700 bg-green-50 border-green-300 hover:bg-green-100',
    warning: 'text-yellow-700 bg-yellow-50 border-yellow-300 hover:bg-yellow-100',
    danger: 'text-red-700 bg-red-50 border-red-300 hover:bg-red-100',
  };

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={processing}
      className={`px-3 py-2 text-sm font-medium border rounded-lg disabled:opacity-50 disabled:cursor-not-allowed transition-colors ${variants[variant]}`}
    >
      {processing ? 'Processing...' : label}
    </button>
  );
}

function CollapsibleSection({
  title,
  children,
  defaultOpen = false,
}: {
  title: string;
  children: React.ReactNode;
  defaultOpen?: boolean;
}) {
  const [isOpen, setIsOpen] = useState(defaultOpen);

  return (
    <div className="bg-white rounded-lg shadow">
      <button
        type="button"
        onClick={() => setIsOpen(!isOpen)}
        className="w-full px-6 py-4 flex items-center justify-between text-left hover:bg-gray-50 transition-colors"
      >
        <h3 className="text-lg font-medium text-gray-900">{title}</h3>
        <svg
          className={`w-5 h-5 text-gray-500 transition-transform ${isOpen ? 'rotate-180' : ''}`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      {isOpen && <div className="px-6 pb-6">{children}</div>}
    </div>
  );
}

function DateDisplay({ date, format = 'relative' }: { date: string; format?: 'relative' | 'full' }) {
  const d = new Date(date);

  if (format === 'full') {
    return <>{d.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })}</>;
  }

  const now = new Date();
  const diffMs = now.getTime() - d.getTime();
  const diffSeconds = Math.floor(diffMs / 1000);
  const diffMinutes = Math.floor(diffSeconds / 60);
  const diffHours = Math.floor(diffMinutes / 60);
  const diffDays = Math.floor(diffHours / 24);
  const diffMonths = Math.floor(diffDays / 30);
  const diffYears = Math.floor(diffDays / 365);

  let relative = '';
  if (diffYears > 0) {
    relative = `${diffYears} year${diffYears > 1 ? 's' : ''} ago`;
  } else if (diffMonths > 0) {
    relative = `${diffMonths} month${diffMonths > 1 ? 's' : ''} ago`;
  } else if (diffDays > 0) {
    relative = `${diffDays} day${diffDays > 1 ? 's' : ''} ago`;
  } else if (diffHours > 0) {
    relative = `${diffHours} hour${diffHours > 1 ? 's' : ''} ago`;
  } else if (diffMinutes > 0) {
    relative = `${diffMinutes} minute${diffMinutes > 1 ? 's' : ''} ago`;
  } else {
    relative = 'just now';
  }

  const formatted = d.toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
    timeZone: 'UTC',
  }) + ' UTC';

  return <span title={relative}>{formatted}</span>;
}

function CopyToClipboard({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);

  const handleCopy = () => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="inline-flex items-center space-x-2">
      <span>{text}</span>
      <button
        type="button"
        onClick={handleCopy}
        title="Copy to clipboard"
        className="text-gray-400 hover:text-gray-600 transition-colors"
      >
        {copied ? (
          <svg className="w-4 h-4 text-green-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
          </svg>
        ) : (
          <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" />
          </svg>
        )}
      </button>
    </div>
  );
}

