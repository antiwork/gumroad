import React from "react";

export const Navigation = () => (
  <div
    role="navigation"
    aria-label="API Reference"
    className="lg:sticky lg:top-8 lg:h-full lg:max-h-[calc(100vh-4rem)] lg:overflow-auto"
  >
    <menu>
      <li>
        <a href="#api-intro">Introduction</a>
      </li>
      <li>
        <a href="#api-authentication">Authentication</a>
      </li>
      <li>
        <a href="#api-scopes">Scopes</a>
      </li>
      <li>
        <a href="#api-errors">Errors</a>
      </li>
      <li>
        <a href="#api-methods">Methods</a>
        <menu>
          <li>
            <a href="#products">Products</a>
          </li>
          <li>
            <a href="#variant-categories">Variant categories</a>
          </li>
          <li>
            <a href="#offer-codes">Offer codes</a>
          </li>
          <li>
            <a href="#custom-fields">Custom fields</a>
          </li>
          <li>
            <a href="#user">User</a>
          </li>
          <li>
            <a href="#resource-subscriptions">Resource subscriptions</a>
          </li>
          <li>
            <a href="#sales">Sales</a>
          </li>
          <li>
            <a href="#subscribers">Subscribers</a>
          </li>
          <li>
            <a href="#licenses">Licenses</a>
          </li>
          <li>
            <a href="#payouts">Payouts</a>
          </li>
        </menu>
      </li>
    </menu>
  </div>
);
