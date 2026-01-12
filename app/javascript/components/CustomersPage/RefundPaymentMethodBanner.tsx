import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

type Props = {
  show: boolean;
};

export const RefundPaymentMethodBanner = ({ show }: Props) => {
  const [isVisible, setIsVisible] = React.useState(show);
  const [isDismissing, setIsDismissing] = React.useState(false);

  const handleDismiss = asyncVoid(async () => {
    setIsDismissing(true);

    try {
      const response = await request({
        method: "POST",
        url: Routes.dismiss_banner_settings_refund_funding_path(),
        accept: "json",
      });

      const result = cast<{ success: boolean }>(await response.json());

      if (result.success) {
        setIsVisible(false);
      }
    } catch (e) {
      assertResponseError(e);
    }

    setIsDismissing(false);
  });

  if (!isVisible) return null;

  return (
    <div
      role="status"
      style={{
        display: "flex",
        alignItems: "center",
        gap: "12px",
        padding: "12px",
        backgroundColor: "#FBEAF9",
        border: "1px solid #FF90E8",
        borderRadius: "4px",
        marginBottom: "24px",
      }}
    >
      <svg
        width="41"
        height="48"
        viewBox="0 0 41 48"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        style={{ flexShrink: 0 }}
        aria-hidden="true"
      >
        <path
          d="M38.7979 10.591C37.3479 9.39252 35.6204 8.57661 33.7736 8.21788C33.4521 7.07923 32.7958 6.06343 31.8899 5.30225C30.984 4.54106 29.8701 4.06963 28.6929 3.94908C28.4614 3.92621 28.2288 3.91733 27.9962 3.92247C27.0171 2.73257 25.6133 1.9702 24.082 1.79669C23.1245 1.02403 21.9476 0.57318 20.7189 0.50838C19.2052 0.427691 17.7185 0.932126 16.5667 1.91722L16.3913 1.89687C15.3213 1.7924 14.243 1.98249 13.2733 2.44657C12.3035 2.91066 11.4792 3.63107 10.8895 4.52984C9.08089 4.71732 7.31561 5.20178 5.66475 5.96373C4.92754 6.30061 4.29006 6.82249 3.81432 7.47863C3.33859 8.13477 3.04076 8.90283 2.94983 9.70812C2.77604 9.82396 2.60227 9.94449 2.42848 10.0713C1.93016 10.4348 1.50832 10.8929 1.18709 11.4194C0.865862 11.946 0.651537 12.5306 0.556307 13.14C0.461076 13.7493 0.486836 14.3715 0.632107 14.9709C0.777377 15.5703 1.0393 16.1352 1.40295 16.6334C1.99017 17.4407 2.82106 18.0382 3.77339 18.3381C3.75147 18.5071 3.73584 18.6777 3.72801 18.8515C3.68104 20.1335 4.04113 21.1824 4.36679 22.1091C4.52336 22.538 4.65644 22.9418 4.76135 23.3708C4.87077 23.8582 4.92331 24.3567 4.91791 24.8563C4.95706 25.999 5.00873 27.5644 5.90587 29.7465C6.64958 31.5499 8.36399 34.546 9.5273 36.5074L8.13855 40.7246C7.90896 41.425 7.8475 42.1696 7.95916 42.8982C8.07082 43.6268 8.35244 44.3189 8.78126 44.9185C9.21008 45.5181 9.77405 46.0083 10.4275 46.3496C11.081 46.6908 11.8056 46.8735 12.5428 46.8828L27.9915 47.0957H28.0572C29.1026 47.0955 30.118 46.7466 30.9426 46.1044C31.7673 45.4622 32.3542 44.5633 32.6103 43.5501C33.0565 41.7812 34.5204 35.8077 34.6018 33.2186C34.6566 31.4559 34.2887 27.4908 33.3493 19.534L33.2866 19.0127C33.2703 18.7312 33.2703 18.449 33.2866 18.1674C34.038 18.6492 34.9117 18.9056 35.8043 18.9063C36.4996 18.9066 37.1862 18.7522 37.8145 18.4544C38.4427 18.1566 38.9968 17.7228 39.4367 17.1844C40.2234 16.2241 40.5978 14.9914 40.4781 13.7559C40.3584 12.5204 39.7543 11.3825 38.7979 10.591Z"
          fill="#FF90E8"
          stroke="black"
          strokeMiterlimit="10"
        />
        <path
          d="M14.7505 24.9674C14.7505 24.9674 14.1101 18.205 14.0381 14.8598C13.988 12.4945 14.4014 9.27606 14.6472 7.59171C14.692 7.28631 14.8525 7.00983 15.0956 6.81954C15.3387 6.62925 15.6456 6.53973 15.9529 6.56952C16.247 6.59789 16.5203 6.73334 16.721 6.95011C16.9216 7.16688 17.0355 7.44983 17.0411 7.74512C17.0849 10.1464 17.4325 16.4111 18.3813 18.4194C18.3109 12.6526 18.5379 9.31833 19.0906 6.39576C19.1908 5.87293 19.6824 5.15598 20.4653 5.20138C21.162 5.24051 21.5941 5.84319 21.6051 6.46464L22.2314 18.4899"
          stroke="black"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M21.9338 12.5821L22.258 7.36004C22.3281 7.10156 22.4814 6.87336 22.6942 6.71067C22.907 6.54799 23.1675 6.45988 23.4354 6.45995C23.7556 6.45991 24.063 6.5858 24.2912 6.81044C24.5194 7.03508 24.6501 7.34045 24.655 7.66059C24.6895 9.99614 25.1372 14.6469 25.0652 18.5619C25.4441 15.8616 26.4744 11.4848 26.9535 9.52652C27.0218 9.24858 27.1882 9.00464 27.4221 8.83956C27.6559 8.67448 27.9415 8.59936 28.2264 8.628V8.628C28.5265 8.65729 28.8042 8.79988 29.0029 9.02674C29.2016 9.25359 29.3063 9.54764 29.2957 9.84899C29.2112 12.2847 28.4033 17.6759 28.6256 19.5543C28.9106 21.9744 29.9784 30.8016 29.9064 33.0792C29.8343 35.3569 28.0588 42.4058 28.0588 42.4058L12.6071 42.1866L14.6722 35.9251C14.6722 35.9251 11.2543 30.3743 10.257 27.9542C9.25961 25.5341 9.90152 24.609 9.33161 22.2593C8.7617 19.9097 7.69548 18.6997 9.18915 18.1314C10.7251 17.546 12.3941 20.9788 13.3195 25.1756C13.3195 25.1756 17.7331 24.2505 21.0085 30.3007"
          stroke="black"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M16.7357 18.7059C16.7357 18.7059 24.1399 18.1376 26.703 19.0628"
          stroke="black"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M20.5091 23.3301C20.5091 23.3301 21.364 24.9675 24.8523 26.6049"
          stroke="black"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M9.18916 21.6223C9.18916 21.6223 9.97202 20.7676 9.83111 19.9849C9.6902 19.2022 9.18916 18.9877 8.47833 19.1302"
          stroke="black"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M12.1091 9.16496C12.1091 9.16496 10.116 9.09452 7.62344 10.2326"
          stroke="black"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M10.2569 11.8699C10.2569 11.8699 7.83639 11.9419 5.2029 13.8626"
          stroke="black"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M31.6865 12.7247C33.1964 12.7209 34.6592 13.2504 35.8168 14.2196"
          stroke="black"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: "2px" }}>
        <span style={{ fontSize: "14px", lineHeight: "130%", color: "#000" }}>
          <strong>New:</strong> Refund customers instantly, even when your balance is low. Add a backup payment method
          to cover refunds automatically if your balance can't.
        </span>
        <a
          href={`${Routes.settings_payments_path()}#refund-payment-method`}
          style={{ fontSize: "14px", lineHeight: "20px", color: "#000", textDecoration: "underline" }}
        >
          Set up backup method
        </a>
      </div>
      <button
        type="button"
        onClick={handleDismiss}
        disabled={isDismissing}
        style={{
          background: "none",
          border: "none",
          padding: 0,
          color: "#000",
          textDecoration: "underline",
          cursor: "pointer",
          fontSize: "14px",
          lineHeight: "130%",
          alignSelf: "flex-start",
        }}
      >
        close
      </button>
    </div>
  );
};

export default RefundPaymentMethodBanner;
