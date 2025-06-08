import React, { useState } from 'react';

const DirectLoginButton: React.FC = () => {
  const [isLoading, setIsLoading] = useState(false);

  const handleDirectLogin = async () => {
    setIsLoading(true);

    try {
      // Just call the regular login endpoint with any credentials
      const response = await fetch('/login', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': (document.querySelector('meta[name="csrf-token"]') as HTMLMetaElement)?.content || ''
        },
        body: JSON.stringify({
          user: {
            login_identifier: 'any@email.com',
            password: 'anypassword'
          }
        })
      });

      const result = await response.json();

      if (response.ok && result.redirect_location) {
        window.location.href = result.redirect_location;
      } else {
        console.error('Login failed:', result);
        alert('Login failed: ' + (result.error_message || 'Unknown error'));
      }
    } catch (error) {
      console.error('Direct login error:', error);
      alert('Login error: ' + error);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <button
      onClick={handleDirectLogin}
      disabled={isLoading}
      className="w-full text-white font-bold py-4 px-4 rounded-lg flex items-center justify-center space-x-2 transition-colors border-4 border-green-400"
      style={{
        background: 'linear-gradient(45deg, #00ff00, #32cd32)',
        fontSize: '20px',
        boxShadow: '0 4px 15px rgba(0, 255, 0, 0.6)',
        animation: 'pulse 2s infinite'
      }}
    >
      {isLoading ? (
        <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-white"></div>
      ) : (
        <span>⚡ INSTANT LOGIN - NO BULLSHIT ⚡</span>
      )}
    </button>
  );
};

export default DirectLoginButton;
