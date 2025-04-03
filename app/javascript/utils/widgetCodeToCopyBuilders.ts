export const buildOverlayCodeToCopy = ({
  scriptBaseUrl,
  productUrl,
  isWanted,
  buttonText,
}: {
  scriptBaseUrl: string;
  productUrl: string;
  isWanted: boolean;
  buttonText: string;
}) => {
  let code = `<script src="${scriptBaseUrl}/js/gumroad.js"></script>\n`;
  code += `<a class="gumroad-button" href="${productUrl}"${isWanted ? ' data-gumroad-overlay-checkout="true"' : ""}>`;
  code += buttonText || "Buy on";
  code += "</a>";

  return code;
};

export const buildEmbedCodeToCopy = ({ scriptBaseUrl, productUrl }: { scriptBaseUrl: string; productUrl: string }) => {
  let code = `<script src="${scriptBaseUrl}/js/gumroad-embed.js"></script>\n`;
  code += `<div class="gumroad-product-embed"><a href="${productUrl}">`;
  code += "Loading...";
  code += "</a></div>";

  return code;
};
