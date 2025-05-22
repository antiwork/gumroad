import * as React from "react";

import { GettingStartedIconProps } from "./GettingStartedIconProps";

export const SmallBetsIcon = ({ isChecked, ...props }: GettingStartedIconProps) => {
  const mainFillColor = isChecked ? "#FF90E8" : "rgb(var(--filled))"; // Original fill is #FF90E8
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
      <path
        d="M348.62 156.161C347.027 148.897 343.574 142.174 338.6 136.651C337.78 133.923 336.686 131.285 335.334 128.779C331.725 122.192 326.484 116.647 320.114 112.676C313.744 108.705 306.461 106.442 298.965 106.106C295.733 105.952 292.494 106.162 289.309 106.732L288.378 106.496C285.927 105.948 283.435 105.604 280.927 105.469C279.278 100.992 276.794 96.8708 273.606 93.324L252.739 70.0612C251.038 68.1645 249.15 66.4444 247.104 64.9271C246.413 55.5736 242.27 46.8123 235.482 40.3482C228.694 33.8841 219.746 30.1798 210.381 29.9562L172.903 29.0121C167.212 28.8682 161.562 30.0127 156.375 32.3603C151.188 34.7078 146.597 38.1977 142.945 42.5696C139.293 46.9415 136.675 52.0826 135.285 57.6092C133.895 63.1358 133.77 68.9053 134.918 74.4872L135.425 76.9657C133.843 77.9349 132.338 79.0239 130.922 80.2232L106.247 101.125C104.297 102.778 102.519 104.625 100.942 106.637C94.5808 105.168 87.9687 105.168 81.6076 106.637L80.6762 106.873C70.2201 104.904 59.406 106.869 50.3076 112.39C41.2091 117.911 34.4671 126.601 31.3741 136.793C26.409 142.322 22.9569 149.043 21.3533 156.302C10.1654 171.646 10.1298 193.952 21.7657 218.147C25.7387 226.409 38.4592 248.834 48.5979 262.431C52.8066 268.049 62.0022 282.648 69.2643 294.498V303.149C69.2643 313.188 73.2476 322.815 80.338 329.914C87.4283 337.012 97.045 341 107.072 341L262.901 340.835C272.928 340.832 282.543 336.843 289.632 329.745C296.722 322.647 300.706 313.022 300.709 302.984V294.356C307.971 282.554 317.214 267.907 321.376 262.289C331.514 248.763 344.223 226.268 348.208 218.006C359.915 193.811 359.808 171.504 348.62 156.161Z"
        fill={mainFillColor}
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeMiterlimit="10"
      />
      <path
        d="M239.346 198.402C239.346 198.402 257.584 185.419 267.464 165.685C277.343 145.951 280.432 139.188 286.468 140.569C297.62 143.107 287.788 162.51 284.452 169.993C280.137 179.636 268.737 196.631 268.737 196.631"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M285.454 168.47C285.454 168.47 295.392 149.362 298.422 144.865C302.478 138.775 308.514 141.207 310.07 144.11C311.85 147.403 309.822 154.248 306.781 161.613C303.739 168.978 291.066 195.604 285.242 203.725"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M306.745 161.625C306.745 161.625 312.062 155.027 317.638 159.088C322.13 162.357 320.939 166.688 317.391 176.591C313.842 186.493 303.456 209.567 296.359 216.165"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M258.858 192.205C258.858 192.205 284.57 202.402 299.648 221.109"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M316.625 178.361C316.625 178.361 320.68 172.53 326.256 177.098C331.113 181.075 326.256 195.864 322.967 202.721C319.678 209.578 307.5 231.13 298.387 243.31C289.274 255.49 268.23 290.52 268.23 290.52V311.068H194.465C194.465 311.068 193.734 278.375 193.734 254.015C193.734 229.654 207.422 209.873 217.313 197.705C227.204 185.537 231.071 176.85 234.537 170.559C238.592 163.206 249.238 168.022 247.717 176.39C246.196 184.758 233.275 211.396 233.275 211.396C241.141 219.638 245.749 230.458 246.243 241.846"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M257.349 217.935C257.349 217.935 269.503 227.577 273.052 237.22"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M130.639 198.578C130.639 198.578 112.401 185.596 102.509 165.85C92.6183 146.104 89.5415 139.365 83.5054 140.734C72.3647 143.272 82.1968 162.687 85.5332 170.17C89.848 179.801 101.248 196.796 101.248 196.796"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M84.5193 168.6C84.5193 168.6 74.5928 149.492 71.5512 144.995C67.4957 138.905 61.4598 141.325 59.8918 144.228C58.1235 147.533 60.1513 154.378 63.1929 161.731C66.2345 169.084 78.8961 195.734 84.7317 203.842"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M63.24 161.79C63.24 161.79 57.9113 155.204 52.3468 159.252C47.8433 162.533 49.0458 166.865 52.5943 176.767C56.1429 186.67 66.5289 209.743 73.626 216.329"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M111.163 192.37C111.163 192.37 85.4508 202.556 70.3724 221.275"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M53.3961 178.538C53.3961 178.538 49.3407 172.708 43.7645 177.263C38.9073 181.241 43.7645 196.041 47.0537 202.887C50.3429 209.732 62.5091 231.307 71.6339 243.475C80.7587 255.644 101.791 290.686 101.791 290.686V311.234H176.286V254.133C176.286 229.784 162.599 209.992 152.708 197.811C142.817 185.631 138.938 176.956 135.472 170.666C131.429 163.301 120.783 168.128 122.304 176.496C123.825 184.864 136.745 211.502 136.745 211.502C128.878 219.738 124.269 230.556 123.777 241.941"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M112.648 218.171C112.648 218.171 100.482 227.813 96.9333 237.444"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M206.031 153.67L227.31 89.2282L249.604 114.084L206.031 153.67Z"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M184.739 125.25L211.1 59.8046L171.052 58.7896L184.739 125.25Z"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M170.545 173.451L153.321 103.946L126.972 126.264L170.545 173.451Z"
        stroke={strokeColor}
        strokeWidth={strokeWidthValue}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
};
