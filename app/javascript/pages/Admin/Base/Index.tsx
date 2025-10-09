import React from "react";

const AdminDashboard = () => {
  const [userIdentifier, setUserIdentifier] = React.useState("");

  return (
    <section>
      <div className="flex max-w-2xl flex-col gap-4">
        <div className="flex flex-col gap-4">
          <input
            type="text"
            name="user_identifier"
            value={userIdentifier}
            onChange={(e) => setUserIdentifier(e.target.value)}
            placeholder="Enter user email, username, or Stripe account ID"
            className="w-full rounded-md"
            autoFocus
            autoComplete="off"
          />
          <div className="flex gap-4">
            <a
              className="button w-auto flex-1"
              href={Routes.admin_impersonate_path({ user_identifier: userIdentifier })}
            >
              Impersonate user
            </a>
            <a
              className="button w-auto flex-1"
              href={Routes.admin_redirect_to_stripe_dashboard_path({ user_identifier: userIdentifier })}
            >
              View Stripe account
            </a>
          </div>
        </div>
      </div>
    </section>
  );
};

export default AdminDashboard;
