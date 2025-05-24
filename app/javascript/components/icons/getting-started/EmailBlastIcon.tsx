import * as React from "react";

import { GettingStartedIconProps } from "./GettingStartedIconProps";

export const EmailBlastIcon = ({ isChecked, ...props }: GettingStartedIconProps) => {
  const mainFillColor = isChecked ? "#90A8ED" : "rgb(var(--filled))";
  const detailFillColor = isChecked ? "black" : "rgb(var(--black))";
  const strokeColor = isChecked ? "black" : "rgb(var(--primary))";
  const strokeWidthValue = "6";

  const { width = "80", height = "80", ...restProps } = props;

  return (
    <svg
      width={width}
      height={height}
      viewBox="0 0 370 370"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      {...restProps}
    >
      <g clipPath="url(#clip0_29_267_email_blast)">
        <path
          d="M351.284 60.8734C351.284 53.6707 348.422 46.7631 343.327 41.6701C338.233 36.5771 331.323 33.7158 324.119 33.7158H97.5279C90.3234 33.7158 83.4139 36.5771 78.3195 41.6701C73.2251 46.7631 70.3631 53.6707 70.3631 60.8734V236.791H42.8814C35.6768 236.791 28.7673 239.653 23.673 244.746C18.5786 249.839 15.7166 256.746 15.7166 263.949V284.77C15.7351 298.968 21.2919 312.599 31.2057 322.766C41.1196 332.932 54.6087 338.832 68.8057 339.212C69.2675 339.212 69.7112 339.212 70.2092 339.212H296.347C309.587 339.19 322.368 334.358 332.309 325.614C342.249 316.871 348.671 304.812 350.378 291.686C350.979 289.417 351.284 287.08 351.284 284.734V60.8734Z"
          fill={mainFillColor}
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
        />
        <path
          d="M134.228 143.786C134.584 149.294 137.023 154.459 141.051 158.234C145.079 162.009 150.393 164.11 155.914 164.11C161.435 164.11 166.749 162.009 170.777 158.234C174.805 154.459 177.245 149.294 177.601 143.786C177.606 138.894 175.92 134.152 172.829 130.361H204.277V197.603L200.365 191.058L187.516 169.54L175.111 191.32L162.705 213.047L187.96 212.793L204.258 212.621V229.142H120.953V130.361H138.954C135.882 134.16 134.213 138.901 134.228 143.786V143.786Z"
          fill={detailFillColor}
        />
        <path
          d="M100.136 264.003V284.824C100.202 288.453 99.5439 292.059 98.2004 295.431C96.857 298.803 94.8549 301.874 92.3112 304.463C89.7674 307.053 86.733 309.11 83.3851 310.515C80.0372 311.919 76.443 312.642 72.8124 312.642C69.1818 312.642 65.5876 311.919 62.2397 310.515C58.8919 309.11 55.8574 307.053 53.3137 304.463C50.7699 301.874 48.7678 298.803 47.4244 295.431C46.0809 292.059 45.4231 288.453 45.4891 284.824V264.003H100.136Z"
          fill={detailFillColor}
        />
        <path
          d="M100.145 284.806V263.958V60.8734H326.736V284.806"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M204.286 212.666V229.187H120.998V130.361H139H172.838H204.286V197.603V212.666Z"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M172.829 130.361C175.92 134.152 177.606 138.894 177.601 143.786C177.244 149.294 174.805 154.459 170.777 158.234C166.749 162.009 161.435 164.11 155.914 164.11C150.393 164.11 145.079 162.009 141.051 158.234C137.023 154.459 134.584 149.294 134.228 143.786C134.223 138.896 135.906 134.155 138.99 130.361"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M204.286 212.666L187.969 212.838L162.714 213.092L175.12 191.32L187.525 169.54L200.374 191.058L204.286 197.603"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M122.031 251.067H203.38"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M122.031 273.871H203.38"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M227.403 251.067H308.752"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M227.403 273.871H308.752"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M227.403 198.87H298.964"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M227.403 153.282H308.752"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M227.403 176.076H308.752"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M227.403 131.266H308.752"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M308.752 79.413H120.446V109.802H308.752V79.413Z"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M72.8169 312.127C65.5723 312.127 58.6241 309.251 53.4996 304.131C48.3752 299.011 45.4939 292.067 45.4891 284.824V264.003H100.136"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M326.283 284.824C326.283 292.07 323.404 299.019 318.279 304.143C313.154 309.266 306.203 312.145 298.955 312.145H72.8169C80.0631 312.142 87.0117 309.263 92.1347 304.14C97.2577 299.016 100.136 292.068 100.136 284.824"
          stroke={strokeColor}
          strokeWidth={strokeWidthValue}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </g>
      <defs>
        <clipPath id="clip0_29_267_email_blast">
          <rect width="341" height="311" fill="white" transform="translate(13 31)" />
        </clipPath>
      </defs>
    </svg>
  );
};
