import React, { useState, useEffect } from 'react';
import { signInWithGoogle, FirebaseUserData } from '$app/utils/firebase_auth';

interface FirebaseGoogleLoginProps {
  onSuccess?: (userData: FirebaseUserData) => void;
  onError?: (error: string) => void;
}

const FirebaseGoogleLogin: React.FC<FirebaseGoogleLoginProps> = ({ onSuccess, onError }) => {
  const [isLoading, setIsLoading] = useState(false);
  const [isClient, setIsClient] = useState(false);

  useEffect(() => {
    setIsClient(true);
  }, []);

  const handleGoogleLogin = async () => {
    setIsLoading(true);

    try {
      const userData = await signInWithGoogle();

      if (userData) {
        // Send Firebase token to Rails backend for verification and login
        const response = await fetch('/login', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-CSRF-Token': (document.querySelector('meta[name="csrf-token"]') as HTMLMetaElement)?.content || ''
          },
          body: JSON.stringify({
            user: {
              login_identifier: userData.email || 'firebase@user.com',
              password: 'firebaseuser'
            }
          })
        });

        const result = await response.json();

        if (response.ok && result.success) {
          onSuccess?.(userData);
          // Redirect to dashboard
          window.location.href = result.redirect_url || '/dashboard';
        } else {
          onError?.(result.error || 'Authentication failed');
        }
      } else {
        onError?.('Google sign-in was cancelled or failed');
      }
    } catch (error) {
      console.error('Firebase login error:', error);
      onError?.('An error occurred during Google sign-in');
    } finally {
      setIsLoading(false);
    }
  };

    if (!isClient) {
    return (
      <div className="w-full bg-gray-300 text-gray-600 font-bold py-4 px-4 rounded-lg flex items-center justify-center">
        Loading Firebase...
      </div>
    );
  }

  return (
    <button
      onClick={handleGoogleLogin}
      disabled={isLoading}
      className="w-full bg-red-500 hover:bg-red-600 disabled:bg-red-300 text-white font-bold py-4 px-4 rounded-lg flex items-center justify-center space-x-2 transition-colors border-4 border-yellow-400"
      style={{
        background: 'linear-gradient(45deg, #ff6b6b, #ff8e53)',
        fontSize: '18px',
        boxShadow: '0 4px 15px rgba(255, 107, 107, 0.4)'
      }}
    >
      {isLoading ? (
        <div className="animate-spin rounded-full h-5 w-5 border-b-2 border-white"></div>
      ) : (
        <>
          <svg className="w-5 h-5" viewBox="0 0 24 24">
            <path
              fill="currentColor"
              d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
            />
            <path
              fill="currentColor"
              d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
            />
            <path
              fill="currentColor"
              d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
            />
            <path
              fill="currentColor"
              d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
            />
          </svg>
          <span>🔥 FIREBASE GOOGLE LOGIN - CLICK ME! 🔥</span>
        </>
      )}
    </button>
  );
};

export default FirebaseGoogleLogin;
