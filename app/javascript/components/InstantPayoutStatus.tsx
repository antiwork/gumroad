import * as React from "react";

export const InstantPayoutStatus = () => {
  return (
    <div className="flex items-center rounded-md border border-blue-200 bg-blue-50 p-4">
      <div className="mr-2 flex h-6 w-6 items-center justify-center rounded-full bg-blue-400 text-white">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          width="24"
          height="24"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path stroke="none" d="M0 0h24v24H0z" fill="none" />
          <path d="M12 9h.01" />
          <path d="M11 12h1v4h1" />
        </svg>
      </div>
      <p className="text-gray-700 text-sm text-black">
        Every day, your balance from the previous day will be sent to you via instant payouts, subject to a{" "}
        <span className="font-semibold">3% fee</span>.
      </p>
    </div>
  );
};
