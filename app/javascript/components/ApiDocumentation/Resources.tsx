import React from "react";

const RESOURCES = [
  {
    title: "Create an OAuth application",
    description: "A getting started guide for creating an application with our API.",
    isHelper: true,
  },
  {
    title: "omniauth-gumroad",
    url: "http://rubygems.org/gems/omniauth-gumroad",
    description: "(Ruby) an OmniAuth strategy for Gumroad OAuth.",
  },
];

const OAUTH_READING_LINKS = [
  {
    title: "OAuth 2 spec",
    url: "http://tools.ietf.org/html/draft-ietf-oauth-v2-07",
  },
  {
    title: "Ruby OAuth2 library",
    url: "https://github.com/intridea/oauth2",
  },
  {
    title: "Python OAuth2 library",
    url: "https://github.com/dgouldin/python-oauth2",
  },
  {
    title: "PHP OAuth2 library",
    url: "https://github.com/adoy/PHP-OAuth2",
  },
];

export const Resources = () => (
  <>
    <div className="stack" id="api-resources">
      <div>
        <h2>Resources</h2>
      </div>
      <div>
        <div className="flex flex-col gap-4">
          {RESOURCES.map((resource, index) => (
            <p key={index}>
              {resource.url ? (
                <a href={resource.url} target="_blank" rel="noopener noreferrer">
                  {resource.title}
                </a>
              ) : (
                <a href="#" data-helper-prompt={`How do I ${resource.title.toLowerCase()}?`}>
                  {resource.title}
                </a>
              )}{" "}
              - {resource.description}
            </p>
          ))}
        </div>
      </div>
    </div>

    <div className="stack" id="api-more">
      <div>
        <h2>More reading</h2>
      </div>
      <div>
        <div className="flex flex-col gap-4">
          <p>If you're interested in learning more about OAuth, here are some links that might be useful:</p>
          <ul>
            {OAUTH_READING_LINKS.map((link, index) => (
              <li key={index}>
                <a href={link.url} target="_blank" rel="noopener noreferrer">
                  {link.title}
                </a>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  </>
);
